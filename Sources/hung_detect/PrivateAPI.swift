import Foundation
import CGSInternalShim

// MARK: - LaunchServices Private API (dlsym required)

/// Resolves LaunchServices private C functions via dlsym.
/// CGS functions are declared in CGSInternalShim headers and called directly — no dlsym needed.
private struct LSSymbols {
    // Function pointer types matching the private C function signatures.
    // Resolved at runtime via dlsym because no public headers exist.
    typealias ASNCreateWithPidFunc = @convention(c) (CFAllocator?, pid_t) -> CFTypeRef?
    typealias ASNExtractHighAndLowPartsFunc = @convention(c) (CFTypeRef?, UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>) -> Void
    typealias CopyApplicationInformationFunc = @convention(c) (Int32, CFTypeRef, CFTypeRef?) -> CFDictionary?

    let asnCreateWithPid: ASNCreateWithPidFunc                   // PID → ASN (Application Serial Number)
    let asnExtractHighAndLowParts: ASNExtractHighAndLowPartsFunc // ASN → PSN (ProcessSerialNumber) for CGS
    let copyApplicationInformation: CopyApplicationInformationFunc?  // ASN → app metadata dict (optional)

    /// Resolve LS symbols via dlsym. Returns nil if required symbols are missing.
    static func resolve() -> LSSymbols? {
        let rtld = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT

        // Try multiple name variants: plain, single underscore, double underscore
        func find(_ names: [String]) -> UnsafeMutableRawPointer? {
            guard let h = rtld else { return nil }
            for name in names {
                if let p = dlsym(h, name) { return p }
            }
            return nil
        }

        guard let p1 = find(["LSASNCreateWithPid", "_LSASNCreateWithPid", "__LSASNCreateWithPid"]),
              let p2 = find(["LSASNExtractHighAndLowParts", "_LSASNExtractHighAndLowParts", "__LSASNExtractHighAndLowParts"])
        else { return nil }

        let p3 = find(["LSCopyApplicationInformation", "_LSCopyApplicationInformation", "__LSCopyApplicationInformation"])

        return LSSymbols(
            asnCreateWithPid: unsafeBitCast(p1, to: ASNCreateWithPidFunc.self),
            asnExtractHighAndLowParts: unsafeBitCast(p2, to: ASNExtractHighAndLowPartsFunc.self),
            copyApplicationInformation: p3.map { unsafeBitCast($0, to: CopyApplicationInformationFunc.self) })
    }
}

// MARK: - LSAppInfo

/// Process metadata from LaunchServices _LSCopyApplicationInformation.
/// Only available for LS-registered processes (~265 out of ~1450 total).
struct LSAppInfo {
    let appType: AppType       // "Foreground", "UIElement", or "BackgroundOnly"
    let displayName: String?   // LS display name (may differ from executable name)
    let bundleID: String?      // CFBundleIdentifier
    let bundlePath: String?    // .app bundle path
    let executablePath: String? // Full path to executable binary

    func resolvedName(pid: pid_t) -> String { displayName ?? bundleID ?? "PID \(pid)" }
    var resolvedBundleID: String { bundleID ?? "-" }
}

// MARK: - RuntimeAPI (public facade)

/// Unified API for hung detection, LaunchServices queries, and process enumeration.
/// CGS functions are called directly via CGSInternalShim headers.
/// LS functions are resolved via dlsym (private C symbols with no headers).
final class RuntimeAPI {
    private static let ls: LSSymbols? = LSSymbols.resolve()

    /// Verify that all required APIs are available.
    static func loadAPIs() -> Bool {
        // CGS functions are linked at build time — always available if the binary runs.
        // LS symbols are resolved at runtime — check them here.
        ls != nil
    }

    // MARK: Hung detection

    /// Check if a process is not responding. Returns nil if unable to determine.
    static func isAppUnresponsive(pid: pid_t) -> Bool? {
        guard let ls = ls else { return nil }
        guard let asn = ls.asnCreateWithPid(kCFAllocatorDefault, pid) else { return nil }
        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 0)
        ls.asnExtractHighAndLowParts(asn, &psn.highLongOfPSN, &psn.lowLongOfPSN)
        if psn.highLongOfPSN == 0 && psn.lowLongOfPSN == 0 { return nil }
        let connID = CGSMainConnectionID()
        return CGSEventIsAppUnresponsive(connID, &psn)
    }

    // MARK: CGS notification (monitor mode)

    /// Register a Window Server notification callback.
    /// Used for push-based hung/responsive detection (event types 750/751).
    /// Called directly via CGSInternalShim header — no dlsym needed.
    @discardableResult
    static func registerNotify(callback: @escaping CGSNotifyProcPtr,
                               eventType: CGSNotificationType,
                               userData: UnsafeMutableRawPointer? = nil) -> CGError {
        CGSRegisterNotifyProc(callback, eventType, userData)
    }

    /// Unregister a previously registered Window Server notification callback.
    @discardableResult
    static func removeNotify(callback: @escaping CGSNotifyProcPtr,
                             eventType: CGSNotificationType,
                             userData: UnsafeMutableRawPointer? = nil) -> CGError {
        CGSRemoveNotifyProc(callback, eventType, userData)
    }

    // MARK: LaunchServices queries

    /// Query LaunchServices for application info about a PID.
    /// Returns nil if the PID is not known to LaunchServices.
    static func lsAppInfo(pid: pid_t) -> LSAppInfo? {
        guard let ls = ls, let lsCopy = ls.copyApplicationInformation else { return nil }
        guard let asn = ls.asnCreateWithPid(kCFAllocatorDefault, pid) else { return nil }
        guard let cfDict = lsCopy(-1, asn, nil) else { return nil }
        let dict = cfDict as NSDictionary
        guard let appTypeStr = dict["ApplicationType"] as? String,
              let appType = AppType(rawValue: appTypeStr) else { return nil }
        return LSAppInfo(
            appType: appType,
            displayName: dict["LSDisplayName"] as? String,
            bundleID: dict["CFBundleIdentifier"] as? String,
            bundlePath: dict["LSBundlePath"] as? String,
            executablePath: dict["CFBundleExecutablePath"] as? String)
    }

    // MARK: Process enumeration

    /// List all PIDs via proc_listpids with retry for TOCTOU race (same pattern as sysmond).
    private static func listAllPIDs() -> [pid_t] {
        // pid_t is Int32 (4 bytes) on macOS/iOS LP64, but let the compiler decide
        // via MemoryLayout to stay correct if the platform typedef changes.
        let pidSize = Int32(MemoryLayout<pid_t>.stride)
        var bufSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufSize > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bufSize / pidSize))
        var actualSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bufSize)
        while actualSize > 0 && actualSize + pidSize >= bufSize {
            bufSize += 64 * pidSize
            pids = [pid_t](repeating: 0, count: Int(bufSize / pidSize))
            actualSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bufSize)
        }
        guard actualSize > 0 else { return [] }
        return Array(pids.prefix(Int(actualSize / pidSize)))
    }

    // LS info cache — keyed by PID, survives across poll ticks in monitor mode.
    // A process's LS registration (appType, bundleID, displayName) doesn't change
    // during its lifetime, so caching is safe. Same pattern as Activity Monitor's
    // SMProcess dictionary in _processSysmonTable:updateTable:.
    private static var lsCache: [pid_t: LSAppInfo] = [:]

    /// Clear the LS info cache. Call when stopping monitor mode.
    static func clearLSCache() {
        lsCache.removeAll()
    }

    /// Enumerate ALL system processes. LS-known processes include LSAppInfo;
    /// non-LS processes (daemons, agents, kernel tasks) have lsInfo = nil.
    /// This matches Activity Monitor's behavior: show everything, hung-detect only LS subset.
    static func allProcesses(useCache: Bool = false) -> [(pid: pid_t, info: LSAppInfo?)] {
        let pids = listAllPIDs()

        if !useCache {
            return pids.compactMap { pid -> (pid: pid_t, info: LSAppInfo?)? in
                guard pid > 0 else { return nil }
                return (pid: pid, info: lsAppInfo(pid: pid))
            }
        }

        let currentPIDs = Set(pids.filter { $0 > 0 })
        for cachedPID in lsCache.keys where !currentPIDs.contains(cachedPID) {
            lsCache.removeValue(forKey: cachedPID)
        }

        // Cached mode: reuse cached LS info, only probe new PIDs.
        // Non-LS PIDs are re-probed each tick (they return nil quickly).
        return pids.compactMap { pid -> (pid: pid_t, info: LSAppInfo?)? in
            guard pid > 0 else { return nil }
            if let cached = lsCache[pid] {
                return (pid: pid, info: cached)
            }
            if let info = lsAppInfo(pid: pid) {
                lsCache[pid] = info
                return (pid: pid, info: info)
            }
            return (pid: pid, info: nil)
        }
    }

    /// Enumerate only LS-known processes. Independent path from allProcesses() —
    /// does not probe non-LS PIDs, so ~1200 fewer LS IPC calls per invocation.
    /// Used by Monitor and MCPServer where only LS processes matter.
    static func allLSProcesses(useCache: Bool = false) -> [(pid: pid_t, info: LSAppInfo)] {
        let pids = listAllPIDs()

        if !useCache {
            var result: [(pid: pid_t, info: LSAppInfo)] = []
            result.reserveCapacity(256)
            for pid in pids where pid > 0 {
                if let info = lsAppInfo(pid: pid) {
                    result.append((pid: pid, info: info))
                }
            }
            return result
        }

        // Cached mode: reuse cached LS info, only probe new PIDs
        let currentPIDs = Set(pids.filter { $0 > 0 })
        for cachedPID in lsCache.keys where !currentPIDs.contains(cachedPID) {
            lsCache.removeValue(forKey: cachedPID)
        }

        var result: [(pid: pid_t, info: LSAppInfo)] = []
        result.reserveCapacity(lsCache.count + 16)
        for pid in pids where pid > 0 {
            if let cached = lsCache[pid] {
                result.append((pid: pid, info: cached))
            } else if let info = lsAppInfo(pid: pid) {
                lsCache[pid] = info
                result.append((pid: pid, info: info))
            }
            // Non-LS PIDs: skip silently (no nil entry, no wasted re-probe next tick)
        }
        return result
    }

    // MARK: Filtering (LSAppInfo? — full process list, used by performScan with --pid/--name)

    /// Filter processes by ApplicationType. Non-LS processes (info=nil) are excluded
    /// unless processType is .all.
    static func filterByType(_ processes: [(pid: pid_t, info: LSAppInfo?)], processType: ProcessType) -> [(pid: pid_t, info: LSAppInfo?)] {
        if processType == .all { return processes }
        return processes.filter { entry in
            guard let info = entry.info else { return false }
            return processType.matches(info.appType)
        }
    }

    /// Filter processes by PID set and/or name substring match.
    /// For LS processes: matches against displayName and bundleID.
    /// For non-LS processes: matches against executable path basename.
    static func filterByPIDsAndNames(_ processes: [(pid: pid_t, info: LSAppInfo?)],
                                     pids: [pid_t], names: [String]) -> [(pid: pid_t, info: LSAppInfo?)] {
        guard !pids.isEmpty || !names.isEmpty else { return processes }
        let pidSet = Set(pids)
        let lowerNames = names.map { $0.lowercased() }
        return processes.filter { entry in
            if pidSet.contains(entry.pid) { return true }
            if let info = entry.info {
                let n = (info.displayName ?? "").lowercased()
                let b = (info.bundleID ?? "").lowercased()
                return lowerNames.contains { n.contains($0) || b.contains($0) }
            }
            // For non-LS processes, match by executable path basename
            if let path = ProcessInspector.executablePath(pid: entry.pid) {
                let name = ((path as NSString).lastPathComponent).lowercased()
                return lowerNames.contains { name.contains($0) }
            }
            return false
        }
    }

    // MARK: Filtering (LSAppInfo non-optional — LS-only, used by Monitor/MCPServer)

    /// Filter LS processes by ApplicationType. Overload for non-optional LSAppInfo
    /// (Monitor and MCPServer only work with LS-registered processes).
    static func filterByType(_ processes: [(pid: pid_t, info: LSAppInfo)], processType: ProcessType) -> [(pid: pid_t, info: LSAppInfo)] {
        if processType == .all || processType == .lsapp { return processes }
        return processes.filter { processType.matches($0.info.appType) }
    }

    /// Filter LS processes by PID set and/or name substring match (non-optional overload).
    static func filterByPIDsAndNames(_ processes: [(pid: pid_t, info: LSAppInfo)],
                                     pids: [pid_t], names: [String]) -> [(pid: pid_t, info: LSAppInfo)] {
        guard !pids.isEmpty || !names.isEmpty else { return processes }
        let pidSet = Set(pids)
        let lowerNames = names.map { $0.lowercased() }
        return processes.filter { entry in
            if pidSet.contains(entry.pid) { return true }
            let n = (entry.info.displayName ?? "").lowercased()
            let b = (entry.info.bundleID ?? "").lowercased()
            return lowerNames.contains { n.contains($0) || b.contains($0) }
        }
    }
}
