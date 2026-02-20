#!/usr/bin/swift
// main.swift — macOS Hung App Detector
// Uses the same private API as Activity Monitor (CGSEventIsAppUnresponsive)
//
// Build (universal, macOS 12+): ./build_hung_detect.sh
// Run:                          ./hung_detect  or  swift run hung_detect

import AppKit
import Darwin
import CryptoKit
import IOKit.pwr_mgt
import CGSInternalShim

// MARK: - Private API Loading

struct SymbolResolutionChain {
    // Prefer framework bundle lookup first, then fallback to dlsym.
    // This keeps modern systems fast while still handling underscore-export variants.
    let frameworkLookup: (_ frameworkPaths: [String], _ names: [String]) -> UnsafeMutableRawPointer?
    let dynamicLookup: (_ handles: [UnsafeMutableRawPointer], _ names: [String]) -> UnsafeMutableRawPointer?

    func resolve(frameworkPaths: [String],
                 handles: [UnsafeMutableRawPointer],
                 names: [String]) -> UnsafeMutableRawPointer? {
        frameworkLookup(frameworkPaths, names) ?? dynamicLookup(handles, names)
    }
}

struct RuntimeSymbolCatalog {
    // Ordered by preference: modern/primary paths first, compatibility paths later.
    static let cgsFrameworkPaths = [
        "/System/Library/PrivateFrameworks/SkyLight.framework",
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A",
    ]
    static let cgsLibraryPaths = [
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
    ]
    static let cgsMainConnectionSymbols = ["CGSMainConnectionID", "_CGSMainConnectionID"]
    static let cgsEventIsUnresponsiveSymbols = ["CGSEventIsAppUnresponsive", "_CGSEventIsAppUnresponsive"]
    static let cgsRegisterNotifySymbols = ["CGSRegisterNotifyProc", "_CGSRegisterNotifyProc"]
    static let cgsRemoveNotifySymbols = ["CGSRemoveNotifyProc", "_CGSRemoveNotifyProc"]

    // LaunchServices is currently shipped under CoreServices on modern macOS;
    // keep private-framework paths as fallback for older layouts.
    static let launchServicesFrameworkPaths = [
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework",
        "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework",
        "/System/Library/PrivateFrameworks/LaunchServices.framework",
        "/System/Library/PrivateFrameworks/LaunchServices.framework/Versions/A",
    ]
    static let launchServicesLibraryPaths = [
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Versions/A/LaunchServices",
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/LaunchServices",
        "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/LaunchServices",
        "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/LaunchServices",
        "/System/Library/PrivateFrameworks/LaunchServices.framework/Versions/A/LaunchServices",
        "/System/Library/PrivateFrameworks/LaunchServices.framework/LaunchServices",
    ]
    static let lsasnCreateSymbols = ["LSASNCreateWithPid", "_LSASNCreateWithPid", "__LSASNCreateWithPid"]
    static let lsasnExtractSymbols = ["LSASNExtractHighAndLowParts", "_LSASNExtractHighAndLowParts", "__LSASNExtractHighAndLowParts"]
}

private final class CGSBridge {
    private typealias MainConnectionIDFunc = @convention(c) () -> CGSConnectionID
    private typealias EventIsAppUnresponsiveFunc = @convention(c) (CGSConnectionID, UnsafePointer<ProcessSerialNumber>) -> Bool
    private typealias LSASNCreateWithPidFunc = @convention(c) (CFAllocator?, pid_t) -> CFTypeRef?
    private typealias LSASNExtractHighAndLowPartsFunc = @convention(c) (CFTypeRef?, UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>) -> Void
    private typealias CGSRegisterNotifyProcFunc = @convention(c) (
        CGSNotifyProcPtr,
        CGSNotificationType,
        UnsafeMutableRawPointer?
    ) -> CGError
    private typealias CGSRemoveNotifyProcFunc = @convention(c) (
        CGSNotifyProcPtr,
        CGSNotificationType,
        UnsafeMutableRawPointer?
    ) -> CGError
    private struct Symbols {
        let mainConnectionID: MainConnectionIDFunc
        let eventIsAppUnresponsive: EventIsAppUnresponsiveFunc
        let asnCreateWithPid: LSASNCreateWithPidFunc
        let asnExtractHighAndLowParts: LSASNExtractHighAndLowPartsFunc
        let registerNotifyProc: CGSRegisterNotifyProcFunc?
        let removeNotifyProc: CGSRemoveNotifyProcFunc?
    }

    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
    private static let loadedSymbols: Symbols? = resolveSymbols()

    // Resolve private symbols from a framework bundle path via CFBundleGetFunctionPointerForName.
    private static func functionByName(frameworkPath: String, symbolName: String) -> UnsafeMutableRawPointer? {
        let frameworkURL = URL(fileURLWithPath: frameworkPath, isDirectory: true) as CFURL
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, frameworkURL) else { return nil }
        return CFBundleGetFunctionPointerForName(bundle, symbolName as CFString)
    }

    private static func resolveByFramework(_ frameworkPaths: [String], _ names: [String]) -> UnsafeMutableRawPointer? {
        for frameworkPath in frameworkPaths {
            for name in names {
                if let p = functionByName(frameworkPath: frameworkPath, symbolName: name) {
                    return p
                }
            }
        }
        return nil
    }

    private static func openAll(_ paths: [String]) -> [UnsafeMutableRawPointer] {
        var handles: [UnsafeMutableRawPointer] = []
        for path in paths {
            if let h = dlopen(path, RTLD_NOW) {
                handles.append(h)
            }
        }
        return handles
    }

    private static func resolveAny(_ handles: [UnsafeMutableRawPointer], _ names: [String]) -> UnsafeMutableRawPointer? {
        // Probe RTLD_DEFAULT first to catch already-loaded images without opening extra handles.
        if let h = rtldDefault {
            for name in names {
                if let p = dlsym(h, name) {
                    return p
                }
            }
        }
        for h in handles {
            for name in names {
                if let p = dlsym(h, name) {
                    return p
                }
            }
        }
        return nil
    }

    private static func resolveSymbols() -> Symbols? {
        // Only private symbols are resolved dynamically.
        // Prefer CFBundleGetFunctionPointerForName,
        // then fallback to dlsym for underscore-export variants.
        let lookup = SymbolResolutionChain(frameworkLookup: Self.resolveByFramework,
                                           dynamicLookup: Self.resolveAny)
        let cgsFrameworks = RuntimeSymbolCatalog.cgsFrameworkPaths
        let cgsHandles = Self.openAll(RuntimeSymbolCatalog.cgsLibraryPaths)
        // Some exports appear with a leading underscore in symbol tables (e.g. _CGSEventIsAppUnresponsive).
        guard let p1 = lookup.resolve(frameworkPaths: cgsFrameworks,
                                      handles: cgsHandles,
                                      names: RuntimeSymbolCatalog.cgsMainConnectionSymbols),
              let p2 = lookup.resolve(frameworkPaths: cgsFrameworks,
                                      handles: cgsHandles,
                                      names: RuntimeSymbolCatalog.cgsEventIsUnresponsiveSymbols) else { return nil }
        let mainConnectionID = unsafeBitCast(p1, to: MainConnectionIDFunc.self)
        let eventIsAppUnresponsive = unsafeBitCast(p2, to: EventIsAppUnresponsiveFunc.self)

        // CGSRegisterNotifyProc is optional — monitor mode falls back to polling-only if unavailable.
        var registerNotifyProc: CGSRegisterNotifyProcFunc?
        if let p = lookup.resolve(frameworkPaths: cgsFrameworks,
                                  handles: cgsHandles,
                                  names: RuntimeSymbolCatalog.cgsRegisterNotifySymbols) {
            registerNotifyProc = unsafeBitCast(p, to: CGSRegisterNotifyProcFunc.self)
        }
        var removeNotifyProc: CGSRemoveNotifyProcFunc?
        if let p = lookup.resolve(frameworkPaths: cgsFrameworks,
                                  handles: cgsHandles,
                                  names: RuntimeSymbolCatalog.cgsRemoveNotifySymbols) {
            removeNotifyProc = unsafeBitCast(p, to: CGSRemoveNotifyProcFunc.self)
        }

        // LSASN helpers are private. Prefer LaunchServices framework lookup first
        // (CoreServices subframework path on modern systems; PrivateFrameworks path as compatibility fallback).
        let lsFrameworks = RuntimeSymbolCatalog.launchServicesFrameworkPaths
        let lsHandles = Self.openAll(RuntimeSymbolCatalog.launchServicesLibraryPaths)
        // On current SDKs these often appear as __LSASN*; older systems may expose _LSASN* or LSASN*.
        guard let p3 = lookup.resolve(frameworkPaths: lsFrameworks,
                                      handles: lsHandles,
                                      names: RuntimeSymbolCatalog.lsasnCreateSymbols),
              let p4 = lookup.resolve(frameworkPaths: lsFrameworks,
                                      handles: lsHandles,
                                      names: RuntimeSymbolCatalog.lsasnExtractSymbols) else { return nil }
        let asnCreateWithPid = unsafeBitCast(p3, to: LSASNCreateWithPidFunc.self)
        let asnExtractHighAndLowParts = unsafeBitCast(p4, to: LSASNExtractHighAndLowPartsFunc.self)

        return Symbols(mainConnectionID: mainConnectionID,
                       eventIsAppUnresponsive: eventIsAppUnresponsive,
                       asnCreateWithPid: asnCreateWithPid,
                       asnExtractHighAndLowParts: asnExtractHighAndLowParts,
                       registerNotifyProc: registerNotifyProc,
                       removeNotifyProc: removeNotifyProc)
    }

    func load() -> Bool {
        Self.loadedSymbols != nil
    }

    func isAppUnresponsive(pid: pid_t) -> Bool? {
        guard let symbols = Self.loadedSymbols else { return nil }
        let connID = symbols.mainConnectionID()
        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 0)
        guard let asn = symbols.asnCreateWithPid(kCFAllocatorDefault, pid) else { return nil }
        symbols.asnExtractHighAndLowParts(asn, &psn.highLongOfPSN, &psn.lowLongOfPSN)
        if psn.highLongOfPSN == 0 && psn.lowLongOfPSN == 0 { return nil }
        return symbols.eventIsAppUnresponsive(connID, &psn)
    }

    var canRegisterNotify: Bool {
        Self.loadedSymbols?.registerNotifyProc != nil
    }

    var canRemoveNotify: Bool {
        Self.loadedSymbols?.removeNotifyProc != nil
    }

    @discardableResult
    func registerNotify(callback: @escaping CGSNotifyProcPtr,
                        eventType: CGSNotificationType,
                        userData: UnsafeMutableRawPointer? = nil) -> CGError? {
        guard let registerNotifyProc = Self.loadedSymbols?.registerNotifyProc else { return nil }
        return registerNotifyProc(callback, eventType, userData)
    }

    @discardableResult
    func removeNotify(callback: @escaping CGSNotifyProcPtr,
                      eventType: CGSNotificationType,
                      userData: UnsafeMutableRawPointer? = nil) -> CGError? {
        guard let removeNotifyProc = Self.loadedSymbols?.removeNotifyProc else { return nil }
        return removeNotifyProc(callback, eventType, userData)
    }
}

private final class RuntimeAPI {
    private static let sharedBridge = CGSBridge()

    static func loadAPIs() -> Bool {
        sharedBridge.load()
    }

    static func isAppUnresponsive(pid: pid_t) -> Bool? {
        sharedBridge.isAppUnresponsive(pid: pid)
    }

    static var bridge: CGSBridge {
        sharedBridge
    }
}

private final class ProcessInspector {
    private typealias SandboxCheckFunc = @convention(c) (pid_t, UnsafePointer<CChar>?, Int32) -> Int32

    private static let sandboxCheck: SandboxCheckFunc? = {
        // RTLD_DEFAULT is a C macro ((void *)-2) and is unavailable directly in Swift.
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_check") else { return nil }
        return unsafeBitCast(sym, to: SandboxCheckFunc.self)
    }()

    private static let sha256Cache = NSCache<NSString, NSString>()

    static func isSandboxed(pid: pid_t) -> Bool {
        (sandboxCheck?(pid, nil, 0) ?? 0) != 0
    }

    static func sleepPreventingPIDs() -> Set<pid_t> {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let dict = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        var result = Set<pid_t>()
        for (pidNum, assertions) in dict {
            for a in assertions {
                if let type = a["AssertionTrueType"] as? String ?? a["AssertType"] as? String {
                    if type.contains("Sleep") {
                        result.insert(pid_t(pidNum.int32Value))
                        break
                    }
                }
            }
        }
        return result
    }

    static func procInfo(pid: pid_t) -> (ppid: pid_t, uid: uid_t, startTime: Double)? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let st = info.kp_proc.p_starttime
        let startSec = Double(st.tv_sec) + Double(st.tv_usec) / 1_000_000.0
        return (info.kp_eproc.e_ppid, info.kp_eproc.e_ucred.cr_uid, startSec)
    }

    static func executablePath(pid: pid_t) -> String? {
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: Int(MAXPATHLEN))
        defer { buf.deallocate() }
        let len = proc_pidpath(pid, buf, UInt32(MAXPATHLEN))
        guard len > 0 else { return nil }
        return String(cString: buf)
    }

    static func userName(uid: uid_t) -> String {
        if let pw = getpwuid(uid) { return String(cString: pw.pointee.pw_name) }
        return "\(uid)"
    }

    static func archString(_ app: NSRunningApplication) -> String {
        switch app.executableArchitecture {
        case NSBundleExecutableArchitectureARM64:  return "arm64"
        case NSBundleExecutableArchitectureX86_64: return "x86_64"
        case NSBundleExecutableArchitectureI386:   return "i386"
        default: return "-"
        }
    }

    static func addSHA256(_ entries: [ProcEntry], onlyHung: Bool = false) -> [ProcEntry] {
        entries.map { entry in
            if onlyHung && entry.responding { return entry }
            if entry.path == "-" { return entry }
            var out = entry
            out.sha256 = sha256OfFile(entry.path)
            return out
        }
    }

    private static func sha256OfFile(_ path: String) -> String {
        if let cached = sha256Cache.object(forKey: path as NSString) {
            return cached as String
        }

        guard let handle = FileHandle(forReadingAtPath: path) else {
            sha256Cache.setObject("-" as NSString, forKey: path as NSString)
            return "-"
        }
        defer { handle.closeFile() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        sha256Cache.setObject(hex as NSString, forKey: path as NSString)
        return hex
    }
}

// MARK: - Data Types

struct ProcEntry {
    let pid: pid_t
    let ppid: pid_t
    let user: String
    let name: String
    let bundleID: String
    let path: String
    var sha256: String
    let arch: String
    let sandboxed: Bool
    let preventingSleep: Bool
    let uptime: Double
    let responding: Bool
}

// MARK: - Monitor Types

enum MonitorEventType: String {
    case becameHung = "became_hung"
    case becameResponsive = "became_responsive"
    case processExited = "process_exited"
}

struct MonitorEvent {
    let timestamp: Date
    let eventType: MonitorEventType
    let pid: pid_t
    let name: String
    let bundleID: String
}

struct ProcessSnapshot {
    let name: String
    let bundleID: String
    var foregroundApp: Bool
    var responding: Bool
}

// MARK: - CLI

struct Options {
    var json = false
    var noColor = false
    var showAll = false       // show all processes (default: only hung)
    var showSHA = false       // show SHA-256 column (hidden by default)
    var foregroundOnly = false // only scan foreground-type apps (activationPolicy == .regular)
    var pids: [pid_t] = []
    var names: [String] = []
    var help = false
    var version = false
    var monitor = false
    var interval: Double = 3.0
    var sample = false        // --sample
    var spindump = false      // --spindump (implies --sample)
    var full = false          // --full (implies --spindump)
    var sampleDuration: Int = 10          // --sample-duration <SECS>, min 1
    var sampleIntervalMs: Int = 1         // --sample-interval-ms <MS>, min 1
    var spindumpDuration: Int = 10        // --spindump-duration <SECS>, min 1
    var spindumpIntervalMs: Int = 10      // --spindump-interval-ms <MS>, min 1
    var spindumpSystemDuration: Int = 10  // --spindump-system-duration <SECS>, min 1
    var spindumpSystemIntervalMs: Int = 10 // --spindump-system-interval-ms <MS>, min 1
    var outdir: String? = nil // --outdir <DIR>

    var diagnosisEnabled: Bool { sample || spindump || full }
    var diagLevel: Int {      // 0=none, 1=sample, 2=+spindump/pid, 3=+system-wide
        if full { return 3 }
        if spindump { return 2 }
        if sample { return 1 }
        return 0
    }
}

final class CLI {
    static func parseArgs(_ args: [String]) -> Options {
        var o = Options()
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--json":        o.json = true
            case "--no-color":    o.noColor = true
            case "--all", "-a":   o.showAll = true
            case "--sha":         o.showSHA = true
            case "--foreground-only": o.foregroundOnly = true
            case "--pid":
                i += 1
                guard i < args.count, let p = Int32(args[i]) else { fputs("--pid needs a number\n", stderr); exit(2) }
                o.pids.append(p)
            case "--name":
                i += 1
                guard i < args.count else { fputs("--name needs an argument\n", stderr); exit(2) }
                o.names.append(args[i])
            case "--monitor", "-m": o.monitor = true
            case "--interval":
                i += 1
                guard i < args.count, let v = Double(args[i]), v >= 0.5 else {
                    fputs("--interval needs a number >= 0.5\n", stderr); exit(2)
                }
                o.interval = v
            case "--sample":      o.sample = true
            case "--spindump":    o.spindump = true; o.sample = true
            case "--full":        o.full = true; o.spindump = true; o.sample = true
            case "--duration":
                i += 1
                guard i < args.count, let d = Int(args[i]), d >= 1 else {
                    fputs("--duration needs an integer >= 1\n", stderr); exit(2)
                }
                o.sampleDuration = d
                o.spindumpDuration = d
                o.spindumpSystemDuration = d
            case "--sample-duration":
                i += 1
                guard i < args.count, let d = Int(args[i]), d >= 1 else {
                    fputs("--sample-duration needs an integer >= 1\n", stderr); exit(2)
                }
                o.sampleDuration = d
            case "--sample-interval-ms":
                i += 1
                guard i < args.count, let ms = Int(args[i]), ms >= 1 else {
                    fputs("--sample-interval-ms needs an integer >= 1\n", stderr); exit(2)
                }
                o.sampleIntervalMs = ms
            case "--spindump-duration":
                i += 1
                guard i < args.count, let d = Int(args[i]), d >= 1 else {
                    fputs("--spindump-duration needs an integer >= 1\n", stderr); exit(2)
                }
                o.spindumpDuration = d
            case "--spindump-interval-ms":
                i += 1
                guard i < args.count, let ms = Int(args[i]), ms >= 1 else {
                    fputs("--spindump-interval-ms needs an integer >= 1\n", stderr); exit(2)
                }
                o.spindumpIntervalMs = ms
            case "--spindump-system-duration":
                i += 1
                guard i < args.count, let d = Int(args[i]), d >= 1 else {
                    fputs("--spindump-system-duration needs an integer >= 1\n", stderr); exit(2)
                }
                o.spindumpSystemDuration = d
            case "--spindump-system-interval-ms":
                i += 1
                guard i < args.count, let ms = Int(args[i]), ms >= 1 else {
                    fputs("--spindump-system-interval-ms needs an integer >= 1\n", stderr); exit(2)
                }
                o.spindumpSystemIntervalMs = ms
            case "--outdir":
                i += 1
                guard i < args.count else { fputs("--outdir needs a path\n", stderr); exit(2) }
                o.outdir = args[i]
            case "-h", "--help":  o.help = true
            case "-v", "--version": o.version = true
            default: fputs("Unknown option: \(args[i])\n", stderr); exit(2)
            }
            i += 1
        }
        return o
    }

    static func parseArgs() -> Options {
        parseArgs(Array(CommandLine.arguments.dropFirst()))
    }

    static func printHelp() {
        let optionRows: [(String, String)] = [
            ("--all, -a", "Show all processes (default: only Not Responding)"),
            ("--sha", "Show SHA-256 column"),
            ("--foreground-only", "Only include foreground-type apps"),
            ("--pid <PID>", "Check specific PID (repeatable, shows all statuses)"),
            ("--name <NAME>", "Match name/bundle id (repeatable, shows all statuses)"),
            ("--monitor, -m", "Continuous monitoring mode (Ctrl+C to stop)"),
            ("--interval <SECS>", "Polling interval for monitor mode (default: 3, min: 0.5)"),
            ("--json", "JSON output (NDJSON in monitor mode)"),
            ("--no-color", "Disable ANSI colors"),
            ("-v, --version", "Show version"),
            ("-h, --help", "Show help"),
        ]
        let diagnosisIntroRows: [(String, String)] = [
            ("--sample", "Run `sample` on each hung process"),
            ("--spindump", "Also run per-process spindump (implies --sample, needs root)"),
            ("--full", "Also run system-wide spindump (implies --spindump, needs root)"),
            ("scope:", "diagnosis options apply in both single-shot and monitor (-m) modes"),
            ("note:", "--spindump/--full are strict (fail-fast if spindump privilege is unavailable)"),
        ]
        let diagnosisParamRows: [(String, String)] = [
            ("--duration <SECS>", "Legacy shortcut: set all diagnosis durations"),
            ("--sample-duration <SECS>", "sample duration (default: 10, min: 1)"),
            ("--sample-interval-ms <MS>", "sample interval in ms (default: 1, min: 1)"),
            ("--spindump-duration <SECS>", "per-process spindump duration (default: 10, min: 1)"),
            ("--spindump-interval-ms <MS>", "per-process spindump interval in ms (default: 10, min: 1)"),
            ("--spindump-system-duration <SECS>", "system spindump duration for --full (default: 10, min: 1)"),
            ("--spindump-system-interval-ms <MS>", "system spindump interval in ms for --full (default: 10, min: 1)"),
            ("--outdir <DIR>", "Output directory (default: ./hung_diag_<timestamp>)"),
        ]
        let exampleRows: [(String, String)] = [
            ("hung_detect", "Detect hung apps (exit 1 if any found)"),
            ("hung_detect --all", "List all GUI apps with full details"),
            ("hung_detect --pid 913", "Show details for a specific PID"),
            ("hung_detect --name Chrome", "Show details for Chrome processes"),
            ("hung_detect --json", "Machine-readable output"),
            ("hung_detect --monitor", "Watch for hung state changes"),
            ("hung_detect --monitor --json | jq .", "Stream events as NDJSON"),
            ("hung_detect -m --name Safari --interval 2", "Monitor Safari every 2s"),
            ("hung_detect --sample", "Detect + sample hung processes"),
            ("sudo hung_detect -m --full", "Monitor + full auto-diagnose on hung"),
            ("sudo hung_detect -m --full --spindump-duration 5 --spindump-system-duration 5", "Monitor + full auto-diagnose with 5s spindumps"),
            ("sudo hung_detect --full --spindump-duration 5 --spindump-system-duration 5", "Full diagnosis with 5s capture"),
            ("hung_detect -m --sample", "Monitor + auto-diagnose on hung"),
        ]

        let optionsText = renderHelpRows(optionRows)
        let diagnosisText = renderHelpRows(diagnosisIntroRows) + "\n\n" + renderHelpRows(diagnosisParamRows)
        let examplesText = exampleRows.map { cmd, desc in
            "  # \(desc)\n  \(cmd)"
        }.joined(separator: "\n\n")

        print("""
        hung_detect — macOS Hung App Detector
        Uses the same Window Server API as Activity Monitor.

        By default scans ALL GUI processes and only shows Not Responding ones.

        USAGE: hung_detect [OPTIONS]
        Note: options shown as --foo <BAR> require a value.

        OPTIONS:
        \(optionsText)

        EXIT CODES: 0 = all ok, 1 = hung detected, 2 = error

        DIAGNOSIS:
        \(diagnosisText)

        EXAMPLES:
        \(examplesText)
        """)
    }

    static func requireSpindumpPrivilegesIfNeeded(opts: Options) -> Bool {
        guard opts.spindump || opts.full else { return true }
        if getuid() == 0 { return true }

        let probe = DiagnosisRunner.runDiagCommand(
            executablePath: "/usr/bin/sudo",
            arguments: ["-n", "/usr/sbin/spindump", "-h"],
            timeout: 5)
        if probe.success { return true }

        fputs("""
        Error: --spindump/--full runs in strict mode and requires spindump privileges. Re-run with sudo, or configure passwordless sudo for /usr/sbin/spindump.
        """.trimmingCharacters(in: .whitespaces) + "\n", stderr)
        return false
    }

    private static func renderHelpRows(_ rows: [(String, String)], indent: String = "  ", align: Bool = true) -> String {
        if !align {
            return rows.map { left, right in "\(indent)\(left)  \(right)" }.joined(separator: "\n")
        }
        let leftWidth = rows.reduce(0) { max($0, $1.0.count) }
        return rows.map { left, right in
            let gap = String(repeating: " ", count: max(2, leftWidth - left.count + 2))
            return "\(indent)\(left)\(gap)\(right)"
        }.joined(separator: "\n")
    }
}

// MARK: - ANSI Colors

final class C {
    private static let stateLock = NSLock()
    private static var _enabled = true
    static var enabled: Bool {
        get {
            stateLock.lock()
            let value = _enabled
            stateLock.unlock()
            return value
        }
        set {
            stateLock.lock()
            _enabled = newValue
            stateLock.unlock()
        }
    }
    static var reset:   String { enabled ? "\u{1b}[0m"  : "" }
    static var bold:    String { enabled ? "\u{1b}[1m"  : "" }
    static var red:     String { enabled ? "\u{1b}[31m" : "" }
    static var green:   String { enabled ? "\u{1b}[32m" : "" }
    static var yellow:  String { enabled ? "\u{1b}[33m" : "" }
    static var dim:     String { enabled ? "\u{1b}[2m"  : "" }
    static var boldRed: String { enabled ? "\u{1b}[1;31m" : "" }
}

// MARK: - Table Output

final class TextLayout {
    static func formatUptime(_ s: Double) -> String {
        let t = Int(s)
        if t >= 86400 { return "\(t/86400)d\((t%86400)/3600)h" }
        if t >= 3600  { return "\(t/3600)h\((t%3600)/60)m" }
        if t >= 60    { return "\(t/60)m\(t%60)s" }
        return "\(t)s"
    }

    static func charWidth(_ ch: Character) -> Int {
        ch.unicodeScalars.reduce(0) { $0 + scalarWidth($1.value) }
    }

    static func displayWidth(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { $0 + scalarWidth($1.value) }
    }

    static func pad(_ s: String, _ w: Int, right: Bool = false) -> String {
        let dw = displayWidth(s)
        if dw >= w { return s }
        let p = String(repeating: " ", count: w - dw)
        return right ? p + s : s + p
    }

    static func truncR(_ s: String, _ maxW: Int) -> String {
        guard displayWidth(s) > maxW, maxW > 1 else { return s }
        var w = 0
        var result = ""
        for ch in s {
            let cw = charWidth(ch)
            if w + cw + 1 > maxW { break }  // +1 for trailing …
            result.append(ch)
            w += cw
        }
        return result + "\u{2026}"
    }

    static func truncL(_ s: String, _ maxW: Int) -> String {
        guard displayWidth(s) > maxW, maxW > 1 else { return s }
        var w = 0
        var chars: [Character] = []
        for ch in s.reversed() {
            let cw = charWidth(ch)
            if w + cw + 1 > maxW { break }  // +1 for leading …
            chars.append(ch)
            w += cw
        }
        return "\u{2026}" + String(chars.reversed())
    }

    static func termWidth() -> Int {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 { return Int(ws.ws_col) }
        if let c = ProcessInfo.processInfo.environment["COLUMNS"], let n = Int(c) { return n }
        return 120
    }

    // Terminal display width (handles zero-width, full-width, and normal characters)
    private static func scalarWidth(_ v: UInt32) -> Int {
        // Zero-width: control chars, format chars, combining marks, variation selectors
        if v < 0x20 || (v >= 0x7F && v < 0xA0) ||
           (v >= 0x0300 && v <= 0x036F) ||   // combining diacriticals
           (v >= 0x200B && v <= 0x200F) ||   // ZWSP, ZWNJ, ZWJ, LRM, RLM
           (v >= 0x2028 && v <= 0x202F) ||   // line/para sep, bidi controls
           (v >= 0x2060 && v <= 0x2069) ||   // word joiner, invisible operators
           (v >= 0xFE00 && v <= 0xFE0F) ||   // variation selectors
           (v >= 0xE0100 && v <= 0xE01EF) || // variation selectors supplement
           v == 0x00AD || v == 0xFEFF { return 0 }
        // Full-width: CJK, Hangul, fullwidth forms
        if (v >= 0x1100 && v <= 0x115F) || v == 0x2329 || v == 0x232A ||
           (v >= 0x2E80 && v <= 0x303E) || (v >= 0x3040 && v <= 0x33BF) ||
           (v >= 0x3400 && v <= 0x4DBF) || (v >= 0x4E00 && v <= 0xA4CF) ||
           (v >= 0xAC00 && v <= 0xD7AF) || (v >= 0xF900 && v <= 0xFAFF) ||
           (v >= 0xFE30 && v <= 0xFE6F) || (v >= 0xFF01 && v <= 0xFF60) ||
           (v >= 0xFFE0 && v <= 0xFFE6) || (v >= 0x20000 && v <= 0x3FFFF) { return 2 }
        return 1
    }
}

final class TableRenderer {
    static func renderProcessTable(_ entries: [ProcEntry], showAll: Bool, showSHA: Bool) {
    let rows = showAll ? entries : entries.filter { !$0.responding }

    // Summary counts
    let hungN = entries.filter { !$0.responding }.count
    let okN = entries.count - hungN

    if rows.isEmpty {
        print("\(C.green)All \(okN) processes responding.\(C.reset)")
        return
    }

    // Column defs: header, rightAlign, flexible (shares remaining width), truncateLeft, getter
    var colDefs: [(hdr: String, rAlign: Bool, flex: Bool, tLeft: Bool, get: (ProcEntry) -> String)] = [
        ("ST",     false, false, false, { $0.responding ? "OK" : "HUNG" }),
        ("PID",    true,  false, false, { "\($0.pid)" }),
        ("PPID",   true,  false, false, { "\($0.ppid)" }),
        ("USER",   false, false, false, { $0.user }),
        ("NAME",   false, true,  false, { $0.name }),
        ("BUNDLE ID", false, true, false, { $0.bundleID }),
        ("ARCH",   false, false, false, { $0.arch }),
        ("SAND",   false, false, false, { $0.sandboxed ? "Yes" : "No" }),
        ("SLEEP",  false, false, false, { $0.preventingSleep ? "Yes" : "No" }),
        ("UPTIME", true,  false, false, { TextLayout.formatUptime($0.uptime) }),
        ("PATH",   false, true,  true,  { $0.path }),
    ]
    if showSHA {
        // Insert SHA before PATH
        colDefs.insert(("SHA", false, false, false, { $0.sha256 == "-" ? "-" : String($0.sha256.prefix(8)) }), at: colDefs.count - 1)
    }
    let n = colDefs.count

    // Compute raw cell values
    var rawCells: [[String]] = rows.map { row in colDefs.map { $0.get(row) } }

    // Natural widths (unconstrained, by display width)
    var natural = colDefs.map { TextLayout.displayWidth($0.hdr) }
    for cells in rawCells {
        for (i, s) in cells.enumerated() { natural[i] = max(natural[i], TextLayout.displayWidth(s)) }
    }

    // Fit to terminal
    let tw = TextLayout.termWidth()
    let overhead = 3 * n + 1  // │ + 2 padding per cell + outer borders
    var widths = natural

    let totalNatural = natural.reduce(0, +) + overhead
    if totalNatural > tw {
        let flexIdx = colDefs.enumerated().compactMap { $0.element.flex ? $0.offset : nil }
        let fixedSum = colDefs.enumerated().filter { !$0.element.flex }.map { natural[$0.offset] }.reduce(0, +)
        let avail = max(tw - overhead - fixedSum, flexIdx.count * 4) // min 4 chars each
        let flexNatSum = flexIdx.map { natural[$0] }.reduce(0, +)

        for i in flexIdx {
            let share = flexNatSum > 0 ? Double(natural[i]) / Double(flexNatSum) : 1.0 / Double(flexIdx.count)
            widths[i] = max(colDefs[i].hdr.count, min(natural[i], Int(Double(avail) * share)))
        }
        // Trim excess
        var flexUsed = flexIdx.map { widths[$0] }.reduce(0, +)
        while flexUsed > avail, let w = flexIdx.max(by: { widths[$0] < widths[$1] }), widths[w] > 3 {
            widths[w] -= 1; flexUsed -= 1
        }
    }

    // Apply truncation to raw cells
    for r in 0..<rawCells.count {
        for (i, col) in colDefs.enumerated() where TextLayout.displayWidth(rawCells[r][i]) > widths[i] {
            rawCells[r][i] = col.tLeft ? TextLayout.truncL(rawCells[r][i], widths[i]) : TextLayout.truncR(rawCells[r][i], widths[i])
        }
    }

    // Box-drawing
    func hLine(_ l: String, _ m: String, _ r: String) -> String {
        l + widths.map { String(repeating: "\u{2500}", count: $0 + 2) }.joined(separator: m) + r
    }

    print(hLine("\u{250c}", "\u{252c}", "\u{2510}"))

    let hdr = colDefs.enumerated().map { (i, c) in " \(TextLayout.pad(c.hdr, widths[i], right: c.rAlign)) " }
    print("\(C.bold)\u{2502}" + hdr.joined(separator: "\u{2502}") + "\u{2502}\(C.reset)")

    print(hLine("\u{251c}", "\u{253c}", "\u{2524}"))

    for (r, row) in rows.enumerated() {
        let cells = rawCells[r].enumerated().map { (i, s) in " \(TextLayout.pad(s, widths[i], right: colDefs[i].rAlign)) " }
        let color = row.responding ? "" : C.red
        print("\(color)\u{2502}" + cells.joined(separator: "\u{2502}") + "\u{2502}\(C.reset)")
    }

    print(hLine("\u{2514}", "\u{2534}", "\u{2518}"))

    if hungN > 0 {
        print("\(C.boldRed)\(hungN) not responding\(C.reset), \(okN) ok  (total \(entries.count))")
    } else {
        print("\(C.green)\(okN) ok\(C.reset)  (total \(entries.count))")
    }
    var legend = "ST=Status  SAND=Sandboxed  SLEEP=Preventing Sleep"
    if showSHA { legend += "  SHA=SHA-256 first 8 chars" }
    print("\(C.dim)\(legend)\(C.reset)")
    }

    static func renderDiagnosis(_ results: [DiagToolResult]) {
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm:ss"
        let ts = tf.string(from: Date())

        var grouped: [(pid: pid_t, name: String, items: [DiagToolResult])] = []
        var seen: [pid_t: Int] = [:]
        for r in results {
            if let idx = seen[r.pid] {
                grouped[idx].items.append(r)
            } else {
                seen[r.pid] = grouped.count
                grouped.append((pid: r.pid, name: r.name, items: [r]))
            }
        }

        for g in grouped {
            let pidLabel = g.pid == 0 ? "system" : "\(g.name) (PID \(g.pid))"
            print("\(C.dim)[\(ts)]\(C.reset) \(C.yellow)DIAG\(C.reset)  \(pidLabel):")
            for (i, r) in g.items.enumerated() {
                let connector = (i == g.items.count - 1) ? "\u{2514}\u{2500}" : "\u{251c}\u{2500}"
                if let err = r.error {
                    print("  \(connector) \(r.tool)    \(C.red)\(err)\(C.reset)")
                } else if let path = r.outputPath {
                    let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
                    print("  \(connector) \(TextLayout.pad(r.tool, 10)) \(URL(fileURLWithPath: path).lastPathComponent) (\(size) bytes, \(String(format: "%.1f", r.elapsed))s)")
                }
            }
        }
        fflush(stdout)
    }

    static func renderMonitorEvent(_ event: MonitorEvent) {
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm:ss"
        let ts = tf.string(from: event.timestamp)

        let label: String
        let color: String
        switch event.eventType {
        case .becameHung:       label = "HUNG "; color = C.boldRed
        case .becameResponsive: label = "OK   "; color = C.green
        case .processExited:    label = "EXIT "; color = C.dim
        }
        let bid = event.bundleID != "-" ? " [\(event.bundleID)]" : ""
        print("\(C.dim)[\(ts)]\(C.reset) \(color)\(label)\(C.reset) \(event.name) (PID \(event.pid))\(bid)")
        fflush(stdout)
    }

    static func renderMonitorMeta(type: String, interval: Double, pushActive: Bool, hungCount: Int) {
        if type == "monitor_start" {
            let pushStr = pushActive ? "push+poll" : "poll-only"
            print("\(C.bold)Monitor mode\(C.reset) (\(pushStr), interval \(interval)s) — press Ctrl+C to stop")
        } else {
            print("\n\(C.dim)Monitor stopped. \(hungCount) hung event(s) detected.\(C.reset)")
        }
        fflush(stdout)
    }
}

// MARK: - JSON Output

final class JSONRenderer {
    static func escJSON(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\t", with: "\\t")
    }

    static func renderProcessJSON(_ entries: [ProcEntry], diagnosis: [DiagToolResult] = []) {
    let hungN = entries.filter { !$0.responding }.count
    let okN = entries.count - hungN

    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime]

    var procs: [String] = []
    for e in entries {
        procs.append("""
            {
              "pid": \(e.pid),
              "ppid": \(e.ppid),
              "user": "\(escJSON(e.user))",
              "name": "\(escJSON(e.name))",
              "bundle_id": \(e.bundleID == "-" ? "null" : "\"\(escJSON(e.bundleID))\""),
              "executable_path": "\(escJSON(e.path))",
              "sha256": \(e.sha256 == "-" ? "null" : "\"\(e.sha256)\""),
              "arch": "\(e.arch)",
              "sandboxed": \(e.sandboxed),
              "preventing_sleep": \(e.preventingSleep),
              "elapsed_seconds": \(Int(e.uptime)),
              "responding": \(e.responding)
            }
        """)
    }

    var diagItems: [String] = []
    for d in diagnosis {
        let path = d.outputPath.map { "\"\(escJSON($0))\"" } ?? "null"
        let err = d.error.map { "\"\(escJSON($0))\"" } ?? "null"
        diagItems.append("""
            {"pid":\(d.pid),"name":"\(escJSON(d.name))","tool":"\(d.tool)","output_path":\(path),"elapsed":\(String(format: "%.1f", d.elapsed)),"error":\(err)}
        """.trimmingCharacters(in: .whitespaces))
    }

    let diagJSON = diagnosis.isEmpty ? "" : ",\n  \"diagnosis\": [\n    \(diagItems.joined(separator: ",\n    "))\n  ]"

    print("""
    {
      "scan_time": "\(fmt.string(from: Date()))",
      "summary": { "total": \(entries.count), "not_responding": \(hungN), "ok": \(okN) },
      "processes": [
    \(procs.joined(separator: ",\n"))
      ]\(diagJSON)
    }
    """)
    }

    static func renderDiagnosis(_ results: [DiagToolResult]) {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let ts = fmt.string(from: Date())

        for r in results {
            let path = r.outputPath.map { "\"\(escJSON($0))\"" } ?? "null"
            let err = r.error.map { "\"\(escJSON($0))\"" } ?? "null"
            print("""
            {"timestamp":"\(ts)","event":"diagnosis","pid":\(r.pid),"name":"\(escJSON(r.name))","tool":"\(r.tool)","output_path":\(path),"elapsed":\(String(format: "%.1f", r.elapsed)),"error":\(err)}
            """.trimmingCharacters(in: .whitespaces))
        }
        fflush(stdout)
    }

    static func renderMonitorEvent(_ event: MonitorEvent, formatter: ISO8601DateFormatter) {
        let ts = formatter.string(from: event.timestamp)
        print("""
        {"timestamp":"\(ts)","event":"\(event.eventType.rawValue)","pid":\(event.pid),"name":"\(escJSON(event.name))","bundle_id":\(event.bundleID == "-" ? "null" : "\"\(escJSON(event.bundleID))\"")}
        """.trimmingCharacters(in: .whitespaces))
        fflush(stdout)
    }

    static func renderMonitorMeta(type: String, interval: Double, pushAvailable: Bool, formatter: ISO8601DateFormatter) {
        let ts = formatter.string(from: Date())
        print("""
        {"timestamp":"\(ts)","event":"\(type)","interval":\(interval),"push_available":\(pushAvailable)}
        """.trimmingCharacters(in: .whitespaces))
        fflush(stdout)
    }
}

// MARK: - Diagnosis

struct DiagToolResult {
    let pid: pid_t
    let name: String
    let tool: String        // "sample", "spindump", "spindump-system"
    let outputPath: String?
    let elapsed: Double
    let error: String?
}

private final class DiagnosisRunner {
    private let opts: Options
    private let outputHandler: ([DiagToolResult]) -> Void
    // Prevent duplicate captures for the same PID while an async diagnosis job is still running.
    private var diagnosingPIDs = Set<pid_t>()
    private let diagnosingPIDsLock = NSLock()
    // Lazily resolve once so monitor mode keeps all artifacts in a single directory.
    private var resolvedOutdir: String?
    private let outdirLock = NSLock()
    private let diagnosisQueue = DispatchQueue(label: "com.hung_detect.diagnosis",
                                               attributes: .concurrent)

    init(opts: Options, outputHandler: @escaping ([DiagToolResult]) -> Void) {
        self.opts = opts
        self.outputHandler = outputHandler
    }

    func runSingleShot(hungProcesses: [(pid: pid_t, name: String)]) -> [DiagToolResult] {
        guard let outdir = resolveDiagOutdir() else {
            return diagnosisOutdirErrorResults(hungProcesses: hungProcesses,
                                               reason: "failed to create output directory")
        }
        let timestamp = Self.diagnosisTimestamp()
        var results: [DiagToolResult] = []
        let resultsLock = NSLock()
        let group = DispatchGroup()

        for proc in hungProcesses {
            if opts.sample {
                group.enter()
                diagnosisQueue.async {
                    let r = self.runSample(pid: proc.pid, name: proc.name,
                                           duration: self.opts.sampleDuration,
                                           intervalMs: self.opts.sampleIntervalMs,
                                           outdir: outdir,
                                           timestamp: timestamp)
                    resultsLock.lock(); results.append(r); resultsLock.unlock()
                    group.leave()
                }
            }
            if opts.spindump {
                group.enter()
                diagnosisQueue.async {
                    let r = self.runSpindumpPid(pid: proc.pid, name: proc.name,
                                                duration: self.opts.spindumpDuration,
                                                intervalMs: self.opts.spindumpIntervalMs,
                                                outdir: outdir,
                                                timestamp: timestamp)
                    resultsLock.lock(); results.append(r); resultsLock.unlock()
                    group.leave()
                }
            }
        }
        if opts.full {
            group.enter()
            diagnosisQueue.async {
                let r = self.runSpindumpSystem(duration: self.opts.spindumpSystemDuration,
                                               intervalMs: self.opts.spindumpSystemIntervalMs,
                                               outdir: outdir,
                                               timestamp: timestamp)
                resultsLock.lock(); results.append(r); resultsLock.unlock()
                group.leave()
            }
        }

        group.wait()
        fixOwnership(dir: outdir)
        return results
    }

    func triggerAsync(hungProcesses: [(pid: pid_t, name: String)]) {
        diagnosingPIDsLock.lock()
        let newProcs = hungProcesses.filter { !diagnosingPIDs.contains($0.pid) }
        for p in newProcs { diagnosingPIDs.insert(p.pid) }
        diagnosingPIDsLock.unlock()

        // --full may need a system-wide spindump even when no newly-hung PID is added.
        guard !newProcs.isEmpty || opts.full else { return }

        guard let outdir = resolveDiagOutdir() else {
            let errors = diagnosisOutdirErrorResults(hungProcesses: newProcs,
                                                     reason: "failed to create output directory")
            diagnosingPIDsLock.lock()
            for p in newProcs { diagnosingPIDs.remove(p.pid) }
            diagnosingPIDsLock.unlock()
            DispatchQueue.main.async {
                self.outputHandler(errors)
            }
            return
        }
        let timestamp = Self.diagnosisTimestamp()

        var results: [DiagToolResult] = []
        let resultsLock = NSLock()
        let group = DispatchGroup()

        for proc in newProcs {
            if opts.sample {
                group.enter()
                diagnosisQueue.async {
                    let r = self.runSample(pid: proc.pid, name: proc.name,
                                           duration: self.opts.sampleDuration,
                                           intervalMs: self.opts.sampleIntervalMs,
                                           outdir: outdir,
                                           timestamp: timestamp)
                    resultsLock.lock(); results.append(r); resultsLock.unlock()
                    group.leave()
                }
            }
            if opts.spindump {
                group.enter()
                diagnosisQueue.async {
                    let r = self.runSpindumpPid(pid: proc.pid, name: proc.name,
                                                duration: self.opts.spindumpDuration,
                                                intervalMs: self.opts.spindumpIntervalMs,
                                                outdir: outdir,
                                                timestamp: timestamp)
                    resultsLock.lock(); results.append(r); resultsLock.unlock()
                    group.leave()
                }
            }
        }
        if opts.full {
            group.enter()
            diagnosisQueue.async {
                let r = self.runSpindumpSystem(duration: self.opts.spindumpSystemDuration,
                                               intervalMs: self.opts.spindumpSystemIntervalMs,
                                               outdir: outdir,
                                               timestamp: timestamp)
                resultsLock.lock(); results.append(r); resultsLock.unlock()
                group.leave()
            }
        }

        diagnosisQueue.async {
            group.wait()
            self.fixOwnership(dir: outdir)
            self.diagnosingPIDsLock.lock()
            for p in newProcs { self.diagnosingPIDs.remove(p.pid) }
            self.diagnosingPIDsLock.unlock()
            DispatchQueue.main.async {
                self.outputHandler(results)
            }
        }
    }

    private func sudoOwner() -> (uid: UInt32, gid: UInt32)? {
        guard let uidStr = ProcessInfo.processInfo.environment["SUDO_UID"],
              let uid = UInt32(uidStr) else { return nil }
        let gid = ProcessInfo.processInfo.environment["SUDO_GID"].flatMap { UInt32($0) } ?? uid
        return (uid, gid)
    }

    private func chownPath(_ path: String, uid: UInt32, gid: UInt32) {
        _ = path.withCString { chown($0, uid, gid) }
    }

    private func fixOwnershipPath(_ path: String) {
        guard let owner = sudoOwner() else { return }
        chownPath(path, uid: owner.uid, gid: owner.gid)
    }

    private func resolveDiagOutdir() -> String? {
        outdirLock.lock()
        defer { outdirLock.unlock() }
        if let dir = resolvedOutdir { return dir }

        let dir: String
        if let custom = opts.outdir {
            dir = custom
        } else {
            dir = "hung_diag_\(Self.diagnosisTimestamp())"
        }
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            fputs("Error: failed to create output directory '\(dir)': \(error.localizedDescription)\n", stderr)
            return nil
        }
        // If launched via sudo, immediately hand directory ownership back to invoking user.
        fixOwnership(dir: dir)
        resolvedOutdir = dir
        return dir
    }

    private func safeName(_ s: String) -> String {
        s.replacingOccurrences(of: " ", with: "_")
         .replacingOccurrences(of: "/", with: "_")
    }

    private func diagnosisOutdirErrorResults(hungProcesses: [(pid: pid_t, name: String)],
                                             reason: String) -> [DiagToolResult] {
        let message = "diagnosis skipped: \(reason)"
        var results: [DiagToolResult] = []

        for proc in hungProcesses {
            if opts.sample {
                results.append(DiagToolResult(pid: proc.pid, name: proc.name, tool: "sample",
                                              outputPath: nil, elapsed: 0, error: message))
            }
            if opts.spindump {
                results.append(DiagToolResult(pid: proc.pid, name: proc.name, tool: "spindump",
                                              outputPath: nil, elapsed: 0, error: message))
            }
        }
        if opts.full {
            results.append(DiagToolResult(pid: 0, name: "system", tool: "spindump-system",
                                          outputPath: nil, elapsed: 0, error: message))
        }
        return results
    }

    private func runSample(pid: pid_t, name: String, duration: Int, intervalMs: Int,
                           outdir: String, timestamp: String) -> DiagToolResult {
        let outfile = "\(outdir)/\(timestamp)_\(safeName(name))_\(pid).sample.txt"
        let start = Date()
        let (ok, errStr) = Self.runDiagCommand(
            executablePath: "/usr/bin/sample",
            arguments: ["\(pid)", "\(duration)", "\(intervalMs)", "-file", outfile],
            timeout: TimeInterval(duration + 30))
        fixOwnershipPath(outfile)
        let elapsed = Date().timeIntervalSince(start)
        return DiagToolResult(pid: pid, name: name, tool: "sample",
                              outputPath: ok ? outfile : nil,
                              elapsed: elapsed,
                              error: ok ? nil : (errStr.isEmpty ? "sample failed" : errStr))
    }

    private func runSpindumpPid(pid: pid_t, name: String, duration: Int, intervalMs: Int,
                                outdir: String, timestamp: String) -> DiagToolResult {
        let outfile = "\(outdir)/\(timestamp)_\(safeName(name))_\(pid).spindump.txt"
        let start = Date()

        let isRoot = getuid() == 0
        let exe: String
        let args: [String]
        if isRoot {
            exe = "/usr/sbin/spindump"
            args = ["\(pid)", "\(duration)", "\(intervalMs)", "-file", outfile]
        } else {
            exe = "/usr/bin/sudo"
            args = ["-n", "/usr/sbin/spindump", "\(pid)", "\(duration)", "\(intervalMs)", "-file", outfile]
        }

        let (ok, errStr) = Self.runDiagCommand(executablePath: exe,
                                               arguments: args,
                                               timeout: TimeInterval(duration + 30))
        fixOwnershipPath(outfile)
        let elapsed = Date().timeIntervalSince(start)

        var finalErr: String? = nil
        if !ok {
            if errStr.lowercased().contains("password") || errStr.lowercased().contains("sudo") {
                finalErr = "spindump requires root privileges"
            } else {
                finalErr = errStr.isEmpty ? "spindump failed" : errStr
            }
        }
        return DiagToolResult(pid: pid, name: name, tool: "spindump",
                              outputPath: ok ? outfile : nil,
                              elapsed: elapsed, error: finalErr)
    }

    private func runSpindumpSystem(duration: Int, intervalMs: Int, outdir: String,
                                   timestamp: String) -> DiagToolResult {
        let outfile = "\(outdir)/\(timestamp)_system.spindump.txt"
        let start = Date()

        let isRoot = getuid() == 0
        let exe: String
        let args: [String]
        if isRoot {
            exe = "/usr/sbin/spindump"
            args = ["-noTarget", "\(duration)", "\(intervalMs)", "-file", outfile]
        } else {
            exe = "/usr/bin/sudo"
            args = ["-n", "/usr/sbin/spindump", "-noTarget", "\(duration)", "\(intervalMs)", "-file", outfile]
        }

        let (ok, errStr) = Self.runDiagCommand(executablePath: exe,
                                               arguments: args,
                                               timeout: TimeInterval(duration + 60))
        fixOwnershipPath(outfile)
        let elapsed = Date().timeIntervalSince(start)

        var finalErr: String? = nil
        if !ok {
            if errStr.lowercased().contains("password") || errStr.lowercased().contains("sudo") {
                finalErr = "system spindump requires root privileges"
            } else {
                finalErr = errStr.isEmpty ? "system spindump failed" : errStr
            }
        }
        return DiagToolResult(pid: 0, name: "system", tool: "spindump-system",
                              outputPath: ok ? outfile : nil,
                              elapsed: elapsed, error: finalErr)
    }

    private func fixOwnership(dir: String) {
        guard let owner = sudoOwner() else { return }
        chownPath(dir, uid: owner.uid, gid: owner.gid)
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: dir) else { return }
        // Keep resulting artifacts editable by the non-root caller after sudo execution.
        for case let rel as String in walker {
            chownPath("\(dir)/\(rel)", uid: owner.uid, gid: owner.gid)
        }
    }

    private static func diagnosisTimestamp(_ date: Date = Date()) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd_HHmmss"
        return df.string(from: date)
    }

    static func runDiagCommand(executablePath: String, arguments: [String],
                               timeout: TimeInterval) -> (success: Bool, stderr: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = arguments
        let errPipe = Pipe()
        let errRead = errPipe.fileHandleForReading
        let errLock = NSLock()
        var errData = Data()
        errRead.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            errLock.lock()
            errData.append(chunk)
            errLock.unlock()
        }
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            errRead.readabilityHandler = nil
            return (false, "Failed to launch: \(error.localizedDescription)")
        }

        // Hard timeout guard so diagnosis tools cannot block monitor mode forever.
        let killItem = DispatchWorkItem { [weak proc] in
            if let p = proc, p.isRunning { p.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killItem)

        proc.waitUntilExit()
        killItem.cancel()

        errRead.readabilityHandler = nil
        let tail = errRead.readDataToEndOfFile()
        errLock.lock()
        errData.append(tail)
        let finalErrData = errData
        errLock.unlock()

        let errStr = String(data: finalErrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (proc.terminationStatus == 0, errStr)
    }
}

// MARK: - Monitor

final class MonitorEngine {
    static func diffStates(previous: [pid_t: ProcessSnapshot],
                           current: [pid_t: ProcessSnapshot],
                           now: Date) -> [MonitorEvent] {
        var events: [MonitorEvent] = []

        // Detect exits and PID reuse
        for (pid, prev) in previous {
            if let cur = current[pid] {
                // PID reuse guard: different process occupying the same PID
                if cur.name != prev.name || cur.bundleID != prev.bundleID {
                    events.append(MonitorEvent(timestamp: now, eventType: .processExited,
                                               pid: pid, name: prev.name, bundleID: prev.bundleID))
                    if !cur.responding {
                        events.append(MonitorEvent(timestamp: now, eventType: .becameHung,
                                                   pid: pid, name: cur.name, bundleID: cur.bundleID))
                    }
                } else {
                    // Same process — check for state change (skip if push already handled it)
                    if prev.responding && !cur.responding {
                        events.append(MonitorEvent(timestamp: now, eventType: .becameHung,
                                                   pid: pid, name: cur.name, bundleID: cur.bundleID))
                    } else if !prev.responding && cur.responding {
                        events.append(MonitorEvent(timestamp: now, eventType: .becameResponsive,
                                                   pid: pid, name: cur.name, bundleID: cur.bundleID))
                    }
                }
            } else {
                events.append(MonitorEvent(timestamp: now, eventType: .processExited,
                                           pid: pid, name: prev.name, bundleID: prev.bundleID))
            }
        }

        // New processes that are already hung
        for (pid, cur) in current where previous[pid] == nil {
            if !cur.responding {
                events.append(MonitorEvent(timestamp: now, eventType: .becameHung,
                                           pid: pid, name: cur.name, bundleID: cur.bundleID))
            }
        }

        return events
    }

    // Extract PID from CGSProcessNotificationData payload using header-defined field offset.
    private static let notifyPayloadPIDOffset: Int = {
        guard let offset = MemoryLayout<CGSProcessNotificationData>.offset(of: \CGSProcessNotificationData.pid) else {
            preconditionFailure("failed to resolve notify payload pid offset")
        }
        return offset
    }()
    private static let cgsNotifyCallback: CGSNotifyProcPtr = {
        eventType, data, dataLength, userData in
        guard let userData else { return }
        let engine = Unmanaged<MonitorEngine>.fromOpaque(userData).takeUnretainedValue()
        guard eventType == kCGSNotificationAppUnresponsive ||
              eventType == kCGSNotificationAppResponsive else { return }
        let pid = MonitorEngine.pushPayloadPID(data, dataLength: dataLength)

        // Serialize all monitor state mutations onto the main queue.
        let apply: () -> Void = {
            engine.handlePushEvent(eventType: eventType, pid: pid)
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    private let opts: Options
    private let bridge: CGSBridge
    private let diagnosisRunner: DiagnosisRunner?
    private var state: [pid_t: ProcessSnapshot] = [:]
    private let monitorFmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private var hungCount = 0
    // Coalesce multiple push misses into a single asynchronous reconciliation scan.
    private var pushRescanScheduled = false
    private var pushActive = false
    private var sigintSrc: DispatchSourceSignal?
    private var sigtermSrc: DispatchSourceSignal?
    private var timer: DispatchSourceTimer?
    private var notifyUserData: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    fileprivate init(opts: Options,
                     bridge: CGSBridge,
                     diagnosisRunner: DiagnosisRunner?) {
        self.opts = opts
        self.bridge = bridge
        self.diagnosisRunner = diagnosisRunner
    }

    private func requireMainThread() {
        dispatchPrecondition(condition: .onQueue(.main))
    }

    func run() -> Int32 {
        requireMainThread()

        // Setup signal handling for clean shutdown
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigint.setEventHandler { [weak self] in self?.shutdown() }
        sigterm.setEventHandler { [weak self] in self?.shutdown() }
        sigint.resume()
        sigterm.resume()
        sigintSrc = sigint
        sigtermSrc = sigterm

        // Register push callbacks first (Activity Monitor-style startup ordering).
        // Unknown-PID callbacks during startup are reconciled via immediate rescan.
        enableMonitorPushIfAvailable()
        printMonitorMeta(type: "monitor_start")

        // Initial scan
        state = scanProcesses()

        // Report any already-hung processes
        let now = Date()
        var initialHung: [(pid: pid_t, name: String)] = []
        for (pid, snap) in state where !snap.responding {
            hungCount += 1
            outputMonitorEvent(MonitorEvent(timestamp: now, eventType: .becameHung,
                                            pid: pid, name: snap.name, bundleID: snap.bundleID))
            initialHung.append((pid: pid, name: snap.name))
        }
        if let diagnosisRunner, !initialHung.isEmpty {
            diagnosisRunner.triggerAsync(hungProcesses: initialHung)
        }

        // Polling timer (Layer 2)
        let pollTimer = DispatchSource.makeTimerSource(queue: .main)
        pollTimer.schedule(deadline: .now() + opts.interval,
                           repeating: opts.interval,
                           leeway: .milliseconds(100))
        pollTimer.setEventHandler { [weak self] in
            self?.pollTick()
        }
        pollTimer.resume()
        timer = pollTimer

        dispatchMain()  // never returns; exit via signal handler
    }

    private func pollTick() {
        requireMainThread()
        let current = scanProcesses()
        applyMonitorState(current: current, now: Date())
    }

    private func shutdown() {
        requireMainThread()
        if pushActive {
            disableMonitorPushIfNeeded()
        }
        printMonitorMeta(type: "monitor_stop")
        exit(hungCount > 0 ? 1 : 0)
    }

    private static func pushPayloadPID(_ data: UnsafeMutableRawPointer?, dataLength: UInt32) -> pid_t? {
        guard let data else { return nil }
        let endOffset = notifyPayloadPIDOffset + MemoryLayout<pid_t>.size
        guard dataLength >= UInt32(endOffset) else { return nil }
        var pid: pid_t = 0
        memcpy(&pid, data.advanced(by: notifyPayloadPIDOffset), MemoryLayout<pid_t>.size)
        guard pid != 0 else { return nil }
        return pid
    }

    private func handlePushEvent(eventType: CGSNotificationType, pid: pid_t?) {
        requireMainThread()
        guard let pid else {
            schedulePushRescan()
            return
        }
        let applied = applyPushEvent(eventType: eventType, pid: pid, now: Date())
        if !applied {
            // Unknown PID in callback map: reconcile immediately instead of waiting for next poll tick.
            schedulePushRescan()
        }
    }

    private func schedulePushRescan() {
        requireMainThread()
        if pushRescanScheduled { return }
        pushRescanScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pushRescanScheduled = false
            let current = self.scanProcesses()
            self.applyMonitorState(current: current, now: Date())
        }
    }

    private func applyMonitorState(current: [pid_t: ProcessSnapshot], now: Date) {
        requireMainThread()
        // Poll is source-of-truth reconciliation; it catches missed or out-of-order push notifications.
        let events = Self.diffStates(previous: state, current: current, now: now)
        var newlyHung: [(pid: pid_t, name: String)] = []
        for event in events {
            if event.eventType == .becameHung {
                hungCount += 1
                newlyHung.append((pid: event.pid, name: event.name))
            }
            outputMonitorEvent(event)
        }
        state = current
        if let diagnosisRunner, !newlyHung.isEmpty {
            diagnosisRunner.triggerAsync(hungProcesses: newlyHung)
        }
    }

    @discardableResult
    private func applyPushEvent(eventType: CGSNotificationType, pid: pid_t, now: Date) -> Bool {
        requireMainThread()
        guard var snap = state[pid] else { return false }
        // Align with Activity Monitor push behavior: evaluate foreground-app classification at callback time.
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        snap.foregroundApp = isForegroundAppType(app)
        // Apply push updates only to foreground-type apps.
        guard snap.foregroundApp else { return true }

        let isHungEvent = (eventType == kCGSNotificationAppUnresponsive)
        if isHungEvent {
            guard snap.responding else { return true }
            snap.responding = false
            state[pid] = snap
            hungCount += 1
            outputMonitorEvent(MonitorEvent(timestamp: now, eventType: .becameHung,
                                            pid: pid, name: snap.name, bundleID: snap.bundleID))
            if let diagnosisRunner {
                diagnosisRunner.triggerAsync(hungProcesses: [(pid: pid, name: snap.name)])
            }
            return true
        }

        guard !snap.responding else { return true }
        snap.responding = true
        state[pid] = snap
        outputMonitorEvent(MonitorEvent(timestamp: now, eventType: .becameResponsive,
                                        pid: pid, name: snap.name, bundleID: snap.bundleID))
        return true
    }

    private func isForegroundAppType(_ app: NSRunningApplication) -> Bool {
        // NSApplicationActivationPolicy.regular aligns with LaunchServices foreground application type.
        app.activationPolicy == .regular
    }

    private func scanProcesses() -> [pid_t: ProcessSnapshot] {
        requireMainThread()
        let allApps = NSWorkspace.shared.runningApplications
        let scopedApps = opts.foregroundOnly ? allApps.filter { isForegroundAppType($0) } : allApps
        let apps: [NSRunningApplication]

        if !opts.pids.isEmpty || !opts.names.isEmpty {
            let pidSet = Set(opts.pids)
            let lowerNames = opts.names.map { $0.lowercased() }
            apps = scopedApps.filter { app in
                if pidSet.contains(app.processIdentifier) { return true }
                let n = (app.localizedName ?? "").lowercased()
                let b = (app.bundleIdentifier ?? "").lowercased()
                return lowerNames.contains { n.contains($0) || b.contains($0) }
            }
        } else {
            apps = scopedApps
        }

        var result: [pid_t: ProcessSnapshot] = [:]
        for app in apps {
            let pid = app.processIdentifier
            let name = app.localizedName ?? app.bundleIdentifier ?? "PID \(pid)"
            let bid = app.bundleIdentifier ?? "-"
            let fg = isForegroundAppType(app)
            let hung = bridge.isAppUnresponsive(pid: pid) ?? false
            result[pid] = ProcessSnapshot(name: name, bundleID: bid, foregroundApp: fg, responding: !hung)
        }
        return result
    }

    private func outputMonitorEvent(_ event: MonitorEvent) {
        if opts.json {
            JSONRenderer.renderMonitorEvent(event, formatter: monitorFmt)
        } else {
            TableRenderer.renderMonitorEvent(event)
        }
    }

    private func printMonitorMeta(type: String) {
        if opts.json {
            JSONRenderer.renderMonitorMeta(type: type,
                                           interval: opts.interval,
                                           pushAvailable: pushActive,
                                           formatter: monitorFmt)
        } else {
            TableRenderer.renderMonitorMeta(type: type,
                                            interval: opts.interval,
                                            pushActive: pushActive,
                                            hungCount: hungCount)
        }
    }

    private func enableMonitorPushIfAvailable() {
        requireMainThread()
        pushActive = false
        guard bridge.canRegisterNotify else { return }

        let regHung = (bridge.registerNotify(callback: Self.cgsNotifyCallback,
                                             eventType: kCGSNotificationAppUnresponsive,
                                             userData: notifyUserData) == .success)
        let regResponsive = (bridge.registerNotify(callback: Self.cgsNotifyCallback,
                                                   eventType: kCGSNotificationAppResponsive,
                                                   userData: notifyUserData) == .success)
        // Push mode is only considered active when both edges (hung/responsive) are registered.
        guard regHung && regResponsive else {
            disableMonitorPushIfNeeded(registeredHung: regHung, registeredResponsive: regResponsive)
            return
        }
        pushActive = true
    }

    private func disableMonitorPushIfNeeded(registeredHung: Bool = true, registeredResponsive: Bool = true) {
        requireMainThread()
        guard bridge.canRemoveNotify else { return }
        if registeredHung {
            _ = bridge.removeNotify(callback: Self.cgsNotifyCallback,
                                    eventType: kCGSNotificationAppUnresponsive,
                                    userData: notifyUserData)
        }
        if registeredResponsive {
            _ = bridge.removeNotify(callback: Self.cgsNotifyCallback,
                                    eventType: kCGSNotificationAppResponsive,
                                    userData: notifyUserData)
        }
    }

    fileprivate static func runMonitor(opts: Options, diagnosisRunner: DiagnosisRunner?) -> Int32 {
        let engine = MonitorEngine(opts: opts, bridge: RuntimeAPI.bridge, diagnosisRunner: diagnosisRunner)
        return engine.run()
    }
}

// MARK: - Main

func main() -> Int32 {
    let opts = CLI.parseArgs()
    if opts.help { CLI.printHelp(); return 0 }
    if opts.version {
        print("hung_detect \(toolVersion)")
        return 0
    }

    // Colors: disable if --no-color, not a tty, or NO_COLOR env set
    C.enabled = !opts.noColor && !opts.json && isatty(STDOUT_FILENO) != 0
        && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

    guard RuntimeAPI.loadAPIs() else {
        fputs("Error: failed to load private APIs. Requires macOS with Window Server.\n", stderr)
        return 2
    }

    guard CLI.requireSpindumpPrivilegesIfNeeded(opts: opts) else { return 2 }
    let diagnosisRunner: DiagnosisRunner? = opts.diagnosisEnabled ? DiagnosisRunner(
        opts: opts,
        outputHandler: { results in
            if opts.json {
                JSONRenderer.renderDiagnosis(results)
            } else {
                TableRenderer.renderDiagnosis(results)
            }
        }) : nil

    if opts.monitor {
        exit(MonitorEngine.runMonitor(opts: opts, diagnosisRunner: diagnosisRunner))
    }

    // Collect bulk data upfront
    let sleepPIDs = ProcessInspector.sleepPreventingPIDs()

    // Filter candidates
    let allApps = NSWorkspace.shared.runningApplications
    let scopedApps = opts.foregroundOnly ? allApps.filter { $0.activationPolicy == .regular } : allApps
    let candidates: [NSRunningApplication]
    let targeted: Bool  // --pid or --name: always show matched regardless of status

    if !opts.pids.isEmpty || !opts.names.isEmpty {
        targeted = true
        let pidSet = Set(opts.pids)
        let lowerNames = opts.names.map { $0.lowercased() }
        candidates = scopedApps.filter { app in
            if pidSet.contains(app.processIdentifier) { return true }
            let n = (app.localizedName ?? "").lowercased()
            let b = (app.bundleIdentifier ?? "").lowercased()
            return lowerNames.contains { n.contains($0) || b.contains($0) }
        }
        if candidates.isEmpty { fputs("No matching processes found.\n", stderr); return 2 }
    } else {
        targeted = false
        candidates = scopedApps
    }

    // Gather info for each process
    var entries: [ProcEntry] = []
    for app in candidates {
        let pid = app.processIdentifier
        let info = ProcessInspector.procInfo(pid: pid)
        let ppid = info?.ppid ?? 0
        let uid  = info?.uid ?? 0
        let startTime = info?.startTime ?? Date().timeIntervalSince1970
        let uptime = Date().timeIntervalSince1970 - startTime

        let name = app.localizedName ?? app.bundleIdentifier ?? "PID \(pid)"
        let bid  = app.bundleIdentifier ?? "-"
        let path = ProcessInspector.executablePath(pid: pid) ?? "-"
        let hash = "-"
        let arch = ProcessInspector.archString(app)
        let user = ProcessInspector.userName(uid: uid)
        let sand = ProcessInspector.isSandboxed(pid: pid)
        let sleep = sleepPIDs.contains(pid)
        let hung = RuntimeAPI.isAppUnresponsive(pid: pid) ?? false

        entries.append(ProcEntry(
            pid: pid, ppid: ppid, user: user, name: name, bundleID: bid,
            path: path, sha256: hash, arch: arch, sandboxed: sand,
            preventingSleep: sleep, uptime: uptime, responding: !hung))
    }

    // Sort: not responding first, then by name
    entries.sort {
        if $0.responding != $1.responding { return !$0.responding }
        return $0.name.lowercased() < $1.name.lowercased()
    }

    // Run diagnosis if requested
    var diagResults: [DiagToolResult] = []
    if opts.diagnosisEnabled {
        let hungForDiag = entries.filter { !$0.responding }.map { (pid: $0.pid, name: $0.name) }
        if let diagnosisRunner, !hungForDiag.isEmpty {
            diagResults = diagnosisRunner.runSingleShot(hungProcesses: hungForDiag)
        }
    }

    // Output: targeted/--all shows everything, default shows only hung
    let showAll = targeted || opts.showAll
    if opts.json {
        // JSON always includes SHA-256, but compute lazily only for rows that will be emitted.
        let base = showAll ? entries : entries.filter { !$0.responding }
        let output = ProcessInspector.addSHA256(base)
        JSONRenderer.renderProcessJSON(output, diagnosis: diagResults)
    } else {
        if opts.showSHA {
            // Table without --all only prints hung rows, so avoid hashing healthy rows.
            entries = ProcessInspector.addSHA256(entries, onlyHung: !showAll)
        }
        TableRenderer.renderProcessTable(entries, showAll: showAll, showSHA: opts.showSHA)
        if !diagResults.isEmpty {
            TableRenderer.renderDiagnosis(diagResults)
        }
    }

    return entries.contains(where: { !$0.responding }) ? 1 : 0
}

exit(main())
