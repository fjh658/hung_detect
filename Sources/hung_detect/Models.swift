// Models.swift — Data types shared across hung_detect modules.
// Defines process classification (AppType), filtering (ProcessType),
// scan results (ProcEntry, ScanResult), and monitor state (ProcessSnapshot).

import Foundation

// MARK: - Data Types

/// LaunchServices application type — maps directly to the "ApplicationType" key
/// returned by _LSCopyApplicationInformation. Confirmed via IDA reverse engineering
/// of LaunchServices `normalizeApplicationType` (0x180c9cd80).
enum AppType: String {
    case foreground = "Foreground"
    case uiElement = "UIElement"
    case backgroundOnly = "BackgroundOnly"
    case unregistered = "-"   // Not registered with LaunchServices

    var shortLabel: String {
        switch self {
        case .foreground:     return "FG"
        case .uiElement:      return "UIElem"
        case .backgroundOnly: return "BG"
        case .unregistered:   return "-"
        }
    }

    /// Whether this process type supports hung detection via CGSEventIsAppUnresponsive.
    var canDetectHung: Bool { self != .unregistered }
}

/// CLI filter for --type parameter. Maps to LaunchServices ApplicationType values.
/// `lsapp` (default) includes all LS-registered processes (can detect hung).
/// `all` includes non-LS processes too (used internally for --pid/--name targeted queries).
/// `gui` is a convenience combining foreground + uiElement.
enum ProcessType: String {
    case foreground   // Dock apps (LS ApplicationType == "Foreground")
    case uielement    // Menu bar / helper apps (LS ApplicationType == "UIElement")
    case gui          // foreground + uielement combined
    case background   // Background-only LS services (LS ApplicationType == "BackgroundOnly")
    case lsapp        // All LS-registered processes (default, ~265 processes)
    case all          // Everything including non-LS (internal use for --pid/--name)

    func matches(_ appType: AppType) -> Bool {
        switch self {
        case .foreground:  return appType == .foreground
        case .uielement:   return appType == .uiElement
        case .gui:         return appType == .foreground || appType == .uiElement
        case .background:  return appType == .backgroundOnly
        case .lsapp:       return appType != .unregistered
        case .all:         return true
        }
    }
}

/// Full process entry for scan output (table and JSON).
/// Built from LaunchServices info + sysctl kernel info.
/// `sha256` and `codesign` are lazily populated by ProcessInspector after initial scan.
struct ProcEntry {
    let pid: pid_t
    let ppid: pid_t
    let user: String
    let name: String         // LS displayName, or executable basename for non-LS
    let bundleID: String     // LS CFBundleIdentifier, or "-" for non-LS
    let path: String         // Executable path from LS or proc_pidpath
    var sha256: String       // Lazily computed by ProcessInspector.addSHA256
    let arch: String         // "arm64" or "x86_64" (from sysctl P_TRANSLATED flag)
    let sandboxed: Bool
    let preventingSleep: Bool
    let uptime: Double       // Seconds since process start
    let responding: Bool?    // true=OK, false=HUNG, nil=cannot determine (non-LS)
    var codesign: String     // Lazily computed by ProcessInspector.addCodeSign
    let appType: AppType     // LS ApplicationType or .unregistered

    /// Build a ProcEntry from LS info + a single sysctl call per PID.
    static func from(pid: pid_t, lsInfo: LSAppInfo, sleepPIDs: Set<pid_t>) -> ProcEntry {
        let ki = ProcessInspector.kernelInfo(pid: pid)
        let ppid = ki?.ppid ?? 0
        let uid  = ki?.uid ?? 0
        let startTime = ki?.startTime ?? Date().timeIntervalSince1970
        let uptime = Date().timeIntervalSince1970 - startTime

        return ProcEntry(
            pid: pid,
            ppid: ppid,
            user: ProcessInspector.userName(uid: uid),
            name: lsInfo.resolvedName(pid: pid),
            bundleID: lsInfo.resolvedBundleID,
            path: lsInfo.executablePath ?? ProcessInspector.executablePath(pid: pid) ?? "-",
            sha256: "-",
            arch: ki?.arch ?? "-",
            sandboxed: ProcessInspector.isSandboxed(pid: pid),
            preventingSleep: sleepPIDs.contains(pid),
            uptime: uptime,
            responding: !(RuntimeAPI.isAppUnresponsive(pid: pid) ?? false),
            codesign: "-",
            appType: lsInfo.appType)
    }

    /// Build a ProcEntry for a non-LS process (daemon, agent, kernel task).
    /// Hung detection is not available — responding is nil.
    static func fromPID(_ pid: pid_t, sleepPIDs: Set<pid_t>) -> ProcEntry? {
        guard let ki = ProcessInspector.kernelInfo(pid: pid) else { return nil }
        let uptime = Date().timeIntervalSince1970 - ki.startTime
        // Get process name from proc_pidpath basename or kinfo p_comm
        let path = ProcessInspector.executablePath(pid: pid)
        let name = path.map { ($0 as NSString).lastPathComponent } ?? "PID \(pid)"

        return ProcEntry(
            pid: pid,
            ppid: ki.ppid,
            user: ProcessInspector.userName(uid: ki.uid),
            name: name,
            bundleID: "-",
            path: path ?? "-",
            sha256: "-",
            arch: ki.arch,
            sandboxed: ProcessInspector.isSandboxed(pid: pid),
            preventingSleep: sleepPIDs.contains(pid),
            uptime: uptime,
            responding: nil,
            codesign: "-",
            appType: .unregistered)
    }
}

/// ISO 8601 timestamp with milliseconds and timezone offset.
/// Used for scan_time, build_time, and monitor event timestamps.
let isoFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSxxx"
    return f
}()

/// Compact timestamp for diagnosis output filenames (no separators).
let fileTimestampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyyMMdd_HHmmssSSS"
    return f
}()

// MARK: - Monitor Types

/// State transition events emitted during continuous monitoring.
enum MonitorEventType: String {
    case becameHung = "became_hung"
    case becameResponsive = "became_responsive"
    case processExited = "process_exited"
}

/// A single state transition event (hung, responsive, or exited).
struct MonitorEvent {
    let timestamp: Date              // When the transition was detected
    let eventType: MonitorEventType  // What happened
    let pid: pid_t                   // Affected process
    let name: String                 // Process display name
    let bundleID: String             // Bundle ID or "-"
}

/// Lightweight per-process state used by monitor mode for diffing between poll ticks.
/// Unlike ProcEntry (full detail for output), ProcessSnapshot only holds fields needed
/// for state comparison and event generation.
struct ProcessSnapshot {
    let name: String
    let bundleID: String
    var foregroundApp: Bool   // LS ApplicationType == "Foreground"
    var responding: Bool      // Always determinable (monitor only tracks LS processes)
    let appType: AppType
}
