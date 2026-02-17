#!/usr/bin/swift
// main.swift — macOS Hung App Detector
// Uses the same private API as Activity Monitor (CGSEventIsAppUnresponsive)
//
// Build (universal, macOS 12+): ./build_hung_detect.sh
// Run:                         ./hung_detect  or  swift run hung_detect

import AppKit
import Darwin
import CryptoKit

// MARK: - Private API Loading

private typealias CGSConnectionID = Int32
private typealias CGSMainConnectionIDFunc = @convention(c) () -> CGSConnectionID
private typealias CGSEventIsAppUnresponsiveFunc = @convention(c) (CGSConnectionID, UnsafePointer<ProcessSerialNumber>) -> Bool
private typealias LSASNCreateWithPidFunc = @convention(c) (CFAllocator?, pid_t) -> CFTypeRef?
private typealias LSASNExtractHighAndLowPartsFunc = @convention(c) (CFTypeRef?, UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>) -> Void
private typealias IOPMCopyAssertionsByProcessFunc = @convention(c) (UnsafeMutablePointer<Unmanaged<CFDictionary>?>) -> Int32
private typealias SandboxCheckFunc = @convention(c) (pid_t, UnsafePointer<CChar>?, Int32) -> Int32
private typealias CGSRegisterNotifyProcFunc = @convention(c) (
    @convention(c) (Int32, UnsafeMutableRawPointer?) -> Void,  // callback
    Int32,              // event type (750 = hung, 751 = responsive)
    UnsafeMutableRawPointer?  // user data
) -> UInt32

private var fn_CGSMainConnectionID: CGSMainConnectionIDFunc!
private var fn_CGSEventIsAppUnresponsive: CGSEventIsAppUnresponsiveFunc!
private var fn_LSASNCreateWithPid: LSASNCreateWithPidFunc!
private var fn_LSASNExtractHighAndLowParts: LSASNExtractHighAndLowPartsFunc!
private var fn_IOPMCopyAssertionsByProcess: IOPMCopyAssertionsByProcessFunc?
private var fn_sandbox_check: SandboxCheckFunc?
private var fn_CGSRegisterNotifyProc: CGSRegisterNotifyProcFunc?

private func openAll(_ paths: [String]) -> [UnsafeMutableRawPointer] {
    var handles: [UnsafeMutableRawPointer] = []
    for path in paths {
        if let h = dlopen(path, RTLD_NOW) {
            handles.append(h)
        }
    }
    return handles
}

private func resolveAny(_ handles: [UnsafeMutableRawPointer], _ names: [String]) -> UnsafeMutableRawPointer? {
    for h in handles {
        for name in names {
            if let p = dlsym(h, name) {
                return p
            }
        }
    }
    return nil
}

private func loadAPIs() -> Bool {
    // Private symbols moved/re-exported across releases, so resolve from multiple candidates.
    // Newer SDK exports CGS symbols via CoreGraphics, while older systems may expose them via SkyLight.
    let cgsHandles = openAll([
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        "/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics",
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
    ])
    // Some exports appear with a leading underscore in symbol tables (e.g. _CGSEventIsAppUnresponsive).
    guard !cgsHandles.isEmpty,
          let p1 = resolveAny(cgsHandles, ["CGSMainConnectionID", "_CGSMainConnectionID"]),
          let p2 = resolveAny(cgsHandles, ["CGSEventIsAppUnresponsive", "_CGSEventIsAppUnresponsive"]) else { return false }
    fn_CGSMainConnectionID = unsafeBitCast(p1, to: CGSMainConnectionIDFunc.self)
    fn_CGSEventIsAppUnresponsive = unsafeBitCast(p2, to: CGSEventIsAppUnresponsiveFunc.self)

    // CGSRegisterNotifyProc is optional — monitor mode falls back to polling-only if unavailable.
    if let p = resolveAny(cgsHandles, ["CGSRegisterNotifyProc", "_CGSRegisterNotifyProc"]) {
        fn_CGSRegisterNotifyProc = unsafeBitCast(p, to: CGSRegisterNotifyProcFunc.self)
    }

    // LSASN helpers are re-exported by CoreServices/LaunchServices depending on macOS generation.
    let lsHandles = openAll([
        "/System/Library/Frameworks/CoreServices.framework/Versions/A/CoreServices",
        "/System/Library/Frameworks/CoreServices.framework/CoreServices",
        "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/LaunchServices",
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/LaunchServices.framework/Versions/A/LaunchServices",
    ])
    // On current SDKs these often appear as __LSASN*; older systems may expose _LSASN* or LSASN*.
    guard !lsHandles.isEmpty,
          let p3 = resolveAny(lsHandles, ["_LSASNCreateWithPid", "LSASNCreateWithPid", "__LSASNCreateWithPid"]),
          let p4 = resolveAny(lsHandles, ["_LSASNExtractHighAndLowParts", "LSASNExtractHighAndLowParts", "__LSASNExtractHighAndLowParts"]) else { return false }
    fn_LSASNCreateWithPid = unsafeBitCast(p3, to: LSASNCreateWithPidFunc.self)
    fn_LSASNExtractHighAndLowParts = unsafeBitCast(p4, to: LSASNExtractHighAndLowPartsFunc.self)

    if let iokit = openAll([
        "/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit",
        "/System/Library/Frameworks/IOKit.framework/IOKit",
    ]).first,
       let p5 = dlsym(iokit, "IOPMCopyAssertionsByProcess") {
        fn_IOPMCopyAssertionsByProcess = unsafeBitCast(p5, to: IOPMCopyAssertionsByProcessFunc.self)
    }

    if let libsys = openAll([
        "/usr/lib/system/libsystem_sandbox.dylib",
    ]).first,
       let p6 = dlsym(libsys, "sandbox_check") {
        fn_sandbox_check = unsafeBitCast(p6, to: SandboxCheckFunc.self)
    }

    return true
}

// MARK: - Hung Detection (same as Activity Monitor)

private func isAppUnresponsive(pid: pid_t) -> Bool? {
    let connID = fn_CGSMainConnectionID()
    var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 0)
    guard let asn = fn_LSASNCreateWithPid(kCFAllocatorDefault, pid) else { return nil }
    fn_LSASNExtractHighAndLowParts(asn, &psn.highLongOfPSN, &psn.lowLongOfPSN)
    if psn.highLongOfPSN == 0 && psn.lowLongOfPSN == 0 { return nil }
    return fn_CGSEventIsAppUnresponsive(connID, &psn)
}

// MARK: - Sandbox Check

private func isSandboxed(pid: pid_t) -> Bool {
    guard let check = fn_sandbox_check else { return false }
    return check(pid, nil, 0) != 0
}

// MARK: - Preventing Sleep (IOPMAssertions)

private func sleepPreventingPIDs() -> Set<pid_t> {
    guard let copyFn = fn_IOPMCopyAssertionsByProcess else { return [] }
    var raw: Unmanaged<CFDictionary>?
    guard copyFn(&raw) == 0, let dict = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
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

// MARK: - Process Info via sysctl / proc

private func procInfo(pid: pid_t) -> (ppid: pid_t, uid: uid_t, startTime: Double)? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let st = info.kp_proc.p_starttime
    let startSec = Double(st.tv_sec) + Double(st.tv_usec) / 1_000_000.0
    return (info.kp_eproc.e_ppid, info.kp_eproc.e_ucred.cr_uid, startSec)
}

private func executablePath(pid: pid_t) -> String? {
    let buf = UnsafeMutablePointer<CChar>.allocate(capacity: Int(MAXPATHLEN))
    defer { buf.deallocate() }
    let len = proc_pidpath(pid, buf, UInt32(MAXPATHLEN))
    guard len > 0 else { return nil }
    return String(cString: buf)
}

private func userName(uid: uid_t) -> String {
    if let pw = getpwuid(uid) { return String(cString: pw.pointee.pw_name) }
    return "\(uid)"
}

private func archString(_ app: NSRunningApplication) -> String {
    switch app.executableArchitecture {
    case NSBundleExecutableArchitectureARM64:  return "arm64"
    case NSBundleExecutableArchitectureX86_64: return "x86_64"
    case NSBundleExecutableArchitectureI386:   return "i386"
    default: return "-"
    }
}

// MARK: - SHA-256

private var sha256Cache: [String: String] = [:]

private func sha256OfFile(_ path: String) -> String {
    if let cached = sha256Cache[path] { return cached }
    guard let handle = FileHandle(forReadingAtPath: path) else {
        sha256Cache[path] = "-"
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
    sha256Cache[path] = hex
    return hex
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

private func addSHA256(_ entries: [ProcEntry], onlyHung: Bool = false) -> [ProcEntry] {
    entries.map { entry in
        if onlyHung && entry.responding { return entry }
        if entry.path == "-" { return entry }
        var out = entry
        out.sha256 = sha256OfFile(entry.path)
        return out
    }
}

// MARK: - Monitor Types

private enum MonitorEventType: String {
    case becameHung = "became_hung"
    case becameResponsive = "became_responsive"
    case processExited = "process_exited"
}

private struct MonitorEvent {
    let timestamp: Date
    let eventType: MonitorEventType
    let pid: pid_t
    let name: String
    let bundleID: String
}

private struct ProcessSnapshot {
    let name: String
    let bundleID: String
    var responding: Bool
}

// MARK: - CLI

struct Options {
    var json = false
    var noColor = false
    var showAll = false       // show all processes (default: only hung)
    var showSHA = false       // show SHA-256 column (hidden by default)
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

func parseArgs() -> Options {
    var o = Options()
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--json":        o.json = true
        case "--no-color":    o.noColor = true
        case "--all", "-a":   o.showAll = true
        case "--sha":         o.showSHA = true
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

private func renderHelpRows(_ rows: [(String, String)], indent: String = "  ", align: Bool = true) -> String {
    if !align {
        return rows.map { left, right in "\(indent)\(left)  \(right)" }.joined(separator: "\n")
    }
    let leftWidth = rows.reduce(0) { max($0, $1.0.count) }
    return rows.map { left, right in
        let gap = String(repeating: " ", count: max(2, leftWidth - left.count + 2))
        return "\(indent)\(left)\(gap)\(right)"
    }.joined(separator: "\n")
}

func printHelp() {
    let optionRows: [(String, String)] = [
        ("--all, -a", "Show all processes (default: only Not Responding)"),
        ("--sha", "Show SHA-256 column"),
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

private func requireSpindumpPrivilegesIfNeeded(opts: Options) -> Bool {
    guard opts.spindump || opts.full else { return true }
    if getuid() == 0 { return true }

    let probe = runDiagCommand(
        executablePath: "/usr/bin/sudo",
        arguments: ["-n", "/usr/sbin/spindump", "-h"],
        timeout: 5)
    if probe.success { return true }

    fputs("""
    Error: --spindump/--full runs in strict mode and requires spindump privileges. Re-run with sudo, or configure passwordless sudo for /usr/sbin/spindump.
    """.trimmingCharacters(in: .whitespaces) + "\n", stderr)
    return false
}

// MARK: - ANSI Colors

struct C {
    static var enabled = true
    static var reset:   String { enabled ? "\u{1b}[0m"  : "" }
    static var bold:    String { enabled ? "\u{1b}[1m"  : "" }
    static var red:     String { enabled ? "\u{1b}[31m" : "" }
    static var green:   String { enabled ? "\u{1b}[32m" : "" }
    static var yellow:  String { enabled ? "\u{1b}[33m" : "" }
    static var dim:     String { enabled ? "\u{1b}[2m"  : "" }
    static var boldRed: String { enabled ? "\u{1b}[1;31m" : "" }
}

// MARK: - Table Output

func formatUptime(_ s: Double) -> String {
    let t = Int(s)
    if t >= 86400 { return "\(t/86400)d\((t%86400)/3600)h" }
    if t >= 3600  { return "\(t/3600)h\((t%3600)/60)m" }
    if t >= 60    { return "\(t/60)m\(t%60)s" }
    return "\(t)s"
}

// Terminal display width (handles zero-width, full-width, and normal characters)
private func scalarWidth(_ v: UInt32) -> Int {
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

func charWidth(_ ch: Character) -> Int {
    ch.unicodeScalars.reduce(0) { $0 + scalarWidth($1.value) }
}

func displayWidth(_ s: String) -> Int {
    s.unicodeScalars.reduce(0) { $0 + scalarWidth($1.value) }
}

func pad(_ s: String, _ w: Int, right: Bool = false) -> String {
    let dw = displayWidth(s)
    if dw >= w { return s }
    let p = String(repeating: " ", count: w - dw)
    return right ? p + s : s + p
}

func truncR(_ s: String, _ maxW: Int) -> String {
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

func truncL(_ s: String, _ maxW: Int) -> String {
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

func termWidth() -> Int {
    var ws = winsize()
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 { return Int(ws.ws_col) }
    if let c = ProcessInfo.processInfo.environment["COLUMNS"], let n = Int(c) { return n }
    return 120
}

func printTable(_ entries: [ProcEntry], showAll: Bool, showSHA: Bool) {
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
        ("UPTIME", true,  false, false, { formatUptime($0.uptime) }),
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
    var natural = colDefs.map { displayWidth($0.hdr) }
    for cells in rawCells {
        for (i, s) in cells.enumerated() { natural[i] = max(natural[i], displayWidth(s)) }
    }

    // Fit to terminal
    let tw = termWidth()
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
        for (i, col) in colDefs.enumerated() where displayWidth(rawCells[r][i]) > widths[i] {
            rawCells[r][i] = col.tLeft ? truncL(rawCells[r][i], widths[i]) : truncR(rawCells[r][i], widths[i])
        }
    }

    // Box-drawing
    func hLine(_ l: String, _ m: String, _ r: String) -> String {
        l + widths.map { String(repeating: "\u{2500}", count: $0 + 2) }.joined(separator: m) + r
    }

    print(hLine("\u{250c}", "\u{252c}", "\u{2510}"))

    let hdr = colDefs.enumerated().map { (i, c) in " \(pad(c.hdr, widths[i], right: c.rAlign)) " }
    print("\(C.bold)\u{2502}" + hdr.joined(separator: "\u{2502}") + "\u{2502}\(C.reset)")

    print(hLine("\u{251c}", "\u{253c}", "\u{2524}"))

    for (r, row) in rows.enumerated() {
        let cells = rawCells[r].enumerated().map { (i, s) in " \(pad(s, widths[i], right: colDefs[i].rAlign)) " }
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

// MARK: - JSON Output

func escJSON(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
     .replacingOccurrences(of: "\"", with: "\\\"")
     .replacingOccurrences(of: "\n", with: "\\n")
     .replacingOccurrences(of: "\t", with: "\\t")
}

func printJSON(_ entries: [ProcEntry], diagnosis: [DiagToolResult] = []) {
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

// MARK: - Diagnosis

struct DiagToolResult {
    let pid: pid_t
    let name: String
    let tool: String        // "sample", "spindump", "spindump-system"
    let outputPath: String?
    let elapsed: Double
    let error: String?
}

private var diagnosingPIDs = Set<pid_t>()
private let diagnosingPIDsLock = NSLock()
private var resolvedOutdir: String?
private let outdirLock = NSLock()
private let diagnosisQueue = DispatchQueue(label: "com.hung_detect.diagnosis",
                                            attributes: .concurrent)

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

private func resolveDiagOutdir(opts: Options) -> String {
    outdirLock.lock()
    defer { outdirLock.unlock() }
    if let dir = resolvedOutdir { return dir }

    let dir: String
    if let custom = opts.outdir {
        dir = custom
    } else {
        let df = DateFormatter()
        df.dateFormat = "YYYYMMdd_HHmmss"
        dir = "hung_diag_\(df.string(from: Date()))"
    }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    fixOwnership(dir: dir)
    resolvedOutdir = dir
    return dir
}

private func safeName(_ s: String) -> String {
    s.replacingOccurrences(of: " ", with: "_")
     .replacingOccurrences(of: "/", with: "_")
}

private func runDiagCommand(executablePath: String, arguments: [String],
                            timeout: TimeInterval) -> (success: Bool, stderr: String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: executablePath)
    proc.arguments = arguments
    let errPipe = Pipe()
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = errPipe

    do {
        try proc.run()
    } catch {
        return (false, "Failed to launch: \(error.localizedDescription)")
    }

    let killItem = DispatchWorkItem { [weak proc] in
        if let p = proc, p.isRunning { p.terminate() }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killItem)

    proc.waitUntilExit()
    killItem.cancel()

    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (proc.terminationStatus == 0, errStr)
}

private func runSample(pid: pid_t, name: String, duration: Int, intervalMs: Int,
                       outdir: String, timestamp: String) -> DiagToolResult {
    let outfile = "\(outdir)/\(timestamp)_\(safeName(name))_\(pid).sample.txt"
    let start = Date()
    let (ok, errStr) = runDiagCommand(
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

    let (ok, errStr) = runDiagCommand(executablePath: exe, arguments: args,
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

    let (ok, errStr) = runDiagCommand(executablePath: exe, arguments: args,
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
    for case let rel as String in walker {
        chownPath("\(dir)/\(rel)", uid: owner.uid, gid: owner.gid)
    }
}

private func runDiagnosisSingleShot(hungProcesses: [(pid: pid_t, name: String)],
                                     opts: Options) -> [DiagToolResult] {
    let outdir = resolveDiagOutdir(opts: opts)
    let df = DateFormatter()
    df.dateFormat = "YYYYMMdd_HHmmss"
    let timestamp = df.string(from: Date())

    var results: [DiagToolResult] = []
    let resultsLock = NSLock()
    let group = DispatchGroup()

    // Per-process tools
    for proc in hungProcesses {
        if opts.sample {
            group.enter()
            diagnosisQueue.async {
                let r = runSample(pid: proc.pid, name: proc.name,
                                  duration: opts.sampleDuration,
                                  intervalMs: opts.sampleIntervalMs,
                                  outdir: outdir,
                                  timestamp: timestamp)
                resultsLock.lock(); results.append(r); resultsLock.unlock()
                group.leave()
            }
        }
        if opts.spindump {
            group.enter()
            diagnosisQueue.async {
                let r = runSpindumpPid(pid: proc.pid, name: proc.name,
                                       duration: opts.spindumpDuration,
                                       intervalMs: opts.spindumpIntervalMs,
                                       outdir: outdir,
                                       timestamp: timestamp)
                resultsLock.lock(); results.append(r); resultsLock.unlock()
                group.leave()
            }
        }
    }

    // System-wide spindump
    if opts.full {
        group.enter()
        diagnosisQueue.async {
            let r = runSpindumpSystem(duration: opts.spindumpSystemDuration,
                                      intervalMs: opts.spindumpSystemIntervalMs,
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

private func triggerDiagnosisAsync(hungProcesses: [(pid: pid_t, name: String)],
                                    opts: Options) {
    // Dedup: skip PIDs already being diagnosed
    diagnosingPIDsLock.lock()
    let newProcs = hungProcesses.filter { !diagnosingPIDs.contains($0.pid) }
    for p in newProcs { diagnosingPIDs.insert(p.pid) }
    diagnosingPIDsLock.unlock()

    guard !newProcs.isEmpty || opts.full else { return }

    let outdir = resolveDiagOutdir(opts: opts)
    let df = DateFormatter()
    df.dateFormat = "YYYYMMdd_HHmmss"
    let timestamp = df.string(from: Date())

    var results: [DiagToolResult] = []
    let resultsLock = NSLock()
    let group = DispatchGroup()

    for proc in newProcs {
        if opts.sample {
            group.enter()
            diagnosisQueue.async {
                let r = runSample(pid: proc.pid, name: proc.name,
                                  duration: opts.sampleDuration,
                                  intervalMs: opts.sampleIntervalMs,
                                  outdir: outdir,
                                  timestamp: timestamp)
                resultsLock.lock(); results.append(r); resultsLock.unlock()
                group.leave()
            }
        }
        if opts.spindump {
            group.enter()
            diagnosisQueue.async {
                let r = runSpindumpPid(pid: proc.pid, name: proc.name,
                                       duration: opts.spindumpDuration,
                                       intervalMs: opts.spindumpIntervalMs,
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
            let r = runSpindumpSystem(duration: opts.spindumpSystemDuration,
                                      intervalMs: opts.spindumpSystemIntervalMs,
                                      outdir: outdir,
                                      timestamp: timestamp)
            resultsLock.lock(); results.append(r); resultsLock.unlock()
            group.leave()
        }
    }

    diagnosisQueue.async {
        group.wait()
        fixOwnership(dir: outdir)

        // Remove PIDs from in-progress set
        diagnosingPIDsLock.lock()
        for p in newProcs { diagnosingPIDs.remove(p.pid) }
        diagnosingPIDsLock.unlock()

        // Output results on main queue
        DispatchQueue.main.async {
            if monitorOpts.json {
                outputDiagnosisJSON(results)
            } else {
                outputDiagnosisTable(results)
            }
        }
    }
}

private func outputDiagnosisTable(_ results: [DiagToolResult]) {
    let tf = DateFormatter()
    tf.dateFormat = "HH:mm:ss"
    let ts = tf.string(from: Date())

    // Group results by (pid, name)
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
                print("  \(connector) \(pad(r.tool, 10)) \(URL(fileURLWithPath: path).lastPathComponent) (\(size) bytes, \(String(format: "%.1f", r.elapsed))s)")
            }
        }
    }
    fflush(stdout)
}

private func outputDiagnosisJSON(_ results: [DiagToolResult]) {
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

// MARK: - Monitor

// Global state for the C callback and monitor loop (both run on .main queue)
private var monitorState: [pid_t: ProcessSnapshot] = [:]
private var monitorOpts: Options = Options()
private var monitorFmt: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()
private var monitorHungCount = 0

// C-convention callback for Window Server push notifications (Layer 1)
private let cgsNotifyCallback: @convention(c) (Int32, UnsafeMutableRawPointer?) -> Void = {
    eventType, data in
    guard let data = data else { return }
    let pid = pid_t(data.load(fromByteOffset: 12, as: UInt32.self))

    guard var snap = monitorState[pid] else { return }

    let isHung = (eventType == 750)
    let wasResponding = snap.responding

    if isHung && wasResponding {
        snap.responding = false
        monitorState[pid] = snap
        monitorHungCount += 1
        outputMonitorEvent(MonitorEvent(timestamp: Date(), eventType: .becameHung,
                                        pid: pid, name: snap.name, bundleID: snap.bundleID))
        if monitorOpts.diagnosisEnabled {
            triggerDiagnosisAsync(hungProcesses: [(pid: pid, name: snap.name)], opts: monitorOpts)
        }
    } else if !isHung && !wasResponding {
        snap.responding = true
        monitorState[pid] = snap
        outputMonitorEvent(MonitorEvent(timestamp: Date(), eventType: .becameResponsive,
                                        pid: pid, name: snap.name, bundleID: snap.bundleID))
    }
}

private func scanProcesses(opts: Options) -> [pid_t: ProcessSnapshot] {
    let allApps = NSWorkspace.shared.runningApplications
    let apps: [NSRunningApplication]

    if !opts.pids.isEmpty || !opts.names.isEmpty {
        let pidSet = Set(opts.pids)
        let lowerNames = opts.names.map { $0.lowercased() }
        apps = allApps.filter { app in
            if pidSet.contains(app.processIdentifier) { return true }
            let n = (app.localizedName ?? "").lowercased()
            let b = (app.bundleIdentifier ?? "").lowercased()
            return lowerNames.contains { n.contains($0) || b.contains($0) }
        }
    } else {
        apps = allApps
    }

    var result: [pid_t: ProcessSnapshot] = [:]
    for app in apps {
        let pid = app.processIdentifier
        let name = app.localizedName ?? app.bundleIdentifier ?? "PID \(pid)"
        let bid = app.bundleIdentifier ?? "-"
        let hung = isAppUnresponsive(pid: pid) ?? false
        result[pid] = ProcessSnapshot(name: name, bundleID: bid, responding: !hung)
    }
    return result
}

private func diffStates(previous: [pid_t: ProcessSnapshot],
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

private func outputMonitorEvent(_ event: MonitorEvent) {
    if monitorOpts.json {
        printMonitorEventJSON(event)
    } else {
        printMonitorEventTable(event)
    }
}

private func printMonitorEventTable(_ event: MonitorEvent) {
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

private func printMonitorEventJSON(_ event: MonitorEvent) {
    let ts = monitorFmt.string(from: event.timestamp)
    print("""
    {"timestamp":"\(ts)","event":"\(event.eventType.rawValue)","pid":\(event.pid),"name":"\(escJSON(event.name))","bundle_id":\(event.bundleID == "-" ? "null" : "\"\(escJSON(event.bundleID))\"")}
    """.trimmingCharacters(in: .whitespaces))
    fflush(stdout)
}

private func printMonitorMeta(type: String, interval: Double, json: Bool) {
    if json {
        let ts = monitorFmt.string(from: Date())
        let push = fn_CGSRegisterNotifyProc != nil
        print("""
        {"timestamp":"\(ts)","event":"\(type)","interval":\(interval),"push_available":\(push)}
        """.trimmingCharacters(in: .whitespaces))
        fflush(stdout)
    } else {
        if type == "monitor_start" {
            let pushStr = fn_CGSRegisterNotifyProc != nil ? "push+poll" : "poll-only"
            print("\(C.bold)Monitor mode\(C.reset) (\(pushStr), interval \(interval)s) — press Ctrl+C to stop")
        } else {
            print("\n\(C.dim)Monitor stopped. \(monitorHungCount) hung event(s) detected.\(C.reset)")
        }
        fflush(stdout)
    }
}

private func runMonitor(opts: Options) -> Int32 {
    monitorOpts = opts

    // Setup signal handling for clean shutdown
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let sigintSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let sigtermSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

    let shutdown: () -> Void = {
        printMonitorMeta(type: "monitor_stop", interval: opts.interval, json: opts.json)
        exit(monitorHungCount > 0 ? 1 : 0)
    }
    sigintSrc.setEventHandler(handler: shutdown)
    sigtermSrc.setEventHandler(handler: shutdown)
    sigintSrc.resume()
    sigtermSrc.resume()

    printMonitorMeta(type: "monitor_start", interval: opts.interval, json: opts.json)

    // Register push notifications (Layer 1) — optional
    if fn_CGSRegisterNotifyProc != nil {
        _ = fn_CGSRegisterNotifyProc!(cgsNotifyCallback, 750, nil)  // app became hung
        _ = fn_CGSRegisterNotifyProc!(cgsNotifyCallback, 751, nil)  // app became responsive
    }

    // Initial scan
    monitorState = scanProcesses(opts: opts)

    // Report any already-hung processes
    let now = Date()
    var initialHung: [(pid: pid_t, name: String)] = []
    for (pid, snap) in monitorState where !snap.responding {
        monitorHungCount += 1
        outputMonitorEvent(MonitorEvent(timestamp: now, eventType: .becameHung,
                                        pid: pid, name: snap.name, bundleID: snap.bundleID))
        initialHung.append((pid: pid, name: snap.name))
    }
    if opts.diagnosisEnabled && !initialHung.isEmpty {
        triggerDiagnosisAsync(hungProcesses: initialHung, opts: opts)
    }

    // Polling timer (Layer 2)
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + opts.interval,
                   repeating: opts.interval,
                   leeway: .milliseconds(100))
    timer.setEventHandler {
        let current = scanProcesses(opts: opts)
        let events = diffStates(previous: monitorState, current: current, now: Date())
        var newlyHung: [(pid: pid_t, name: String)] = []
        for event in events {
            if event.eventType == .becameHung {
                monitorHungCount += 1
                newlyHung.append((pid: event.pid, name: event.name))
            }
            outputMonitorEvent(event)
        }
        monitorState = current
        if opts.diagnosisEnabled && !newlyHung.isEmpty {
            triggerDiagnosisAsync(hungProcesses: newlyHung, opts: opts)
        }
    }
    timer.resume()

    dispatchMain()  // never returns; exit via signal handler
}

// MARK: - Main

func main() -> Int32 {
    let opts = parseArgs()
    if opts.help { printHelp(); return 0 }
    if opts.version {
        print("hung_detect \(toolVersion)")
        return 0
    }

    // Colors: disable if --no-color, not a tty, or NO_COLOR env set
    C.enabled = !opts.noColor && !opts.json && isatty(STDOUT_FILENO) != 0
        && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

    guard loadAPIs() else {
        fputs("Error: failed to load private APIs. Requires macOS with Window Server.\n", stderr)
        return 2
    }

    guard requireSpindumpPrivilegesIfNeeded(opts: opts) else { return 2 }

    if opts.monitor {
        exit(runMonitor(opts: opts))
    }

    // Collect bulk data upfront
    let sleepPIDs = sleepPreventingPIDs()

    // Filter candidates — always scan all process types
    let allApps = NSWorkspace.shared.runningApplications
    let candidates: [NSRunningApplication]
    let targeted: Bool  // --pid or --name: always show matched regardless of status

    if !opts.pids.isEmpty || !opts.names.isEmpty {
        targeted = true
        let pidSet = Set(opts.pids)
        let lowerNames = opts.names.map { $0.lowercased() }
        candidates = allApps.filter { app in
            if pidSet.contains(app.processIdentifier) { return true }
            let n = (app.localizedName ?? "").lowercased()
            let b = (app.bundleIdentifier ?? "").lowercased()
            return lowerNames.contains { n.contains($0) || b.contains($0) }
        }
        if candidates.isEmpty { fputs("No matching processes found.\n", stderr); return 2 }
    } else {
        targeted = false
        candidates = allApps
    }

    // Gather info for each process
    var entries: [ProcEntry] = []
    for app in candidates {
        let pid = app.processIdentifier
        let info = procInfo(pid: pid)
        let ppid = info?.ppid ?? 0
        let uid  = info?.uid ?? 0
        let startTime = info?.startTime ?? Date().timeIntervalSince1970
        let uptime = Date().timeIntervalSince1970 - startTime

        let name = app.localizedName ?? app.bundleIdentifier ?? "PID \(pid)"
        let bid  = app.bundleIdentifier ?? "-"
        let path = executablePath(pid: pid) ?? "-"
        let hash = "-"
        let arch = archString(app)
        let user = userName(uid: uid)
        let sand = isSandboxed(pid: pid)
        let sleep = sleepPIDs.contains(pid)
        let hung = isAppUnresponsive(pid: pid) ?? false

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
        if !hungForDiag.isEmpty {
            diagResults = runDiagnosisSingleShot(hungProcesses: hungForDiag, opts: opts)
        }
    }

    // Output: targeted/--all shows everything, default shows only hung
    let showAll = targeted || opts.showAll
    if opts.json {
        // JSON always includes SHA-256, but compute lazily only for rows that will be emitted.
        let base = showAll ? entries : entries.filter { !$0.responding }
        let output = addSHA256(base)
        printJSON(output, diagnosis: diagResults)
    } else {
        if opts.showSHA {
            // Table without --all only prints hung rows, so avoid hashing healthy rows.
            entries = addSHA256(entries, onlyHung: !showAll)
        }
        printTable(entries, showAll: showAll, showSHA: opts.showSHA)
        if !diagResults.isEmpty {
            outputDiagnosisTable(diagResults)
        }
    }

    return entries.contains(where: { !$0.responding }) ? 1 : 0
}

exit(main())
