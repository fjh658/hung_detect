#!/usr/bin/swift
// hung_detect.swift — macOS Hung App Detector
// Uses the same private API as Activity Monitor (CGSEventIsAppUnresponsive)
//
// Build (universal, macOS 12+): ./build_hung_detect.sh
// Run:                         ./hung_detect  or  swift hung_detect.swift

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

private var fn_CGSMainConnectionID: CGSMainConnectionIDFunc!
private var fn_CGSEventIsAppUnresponsive: CGSEventIsAppUnresponsiveFunc!
private var fn_LSASNCreateWithPid: LSASNCreateWithPidFunc!
private var fn_LSASNExtractHighAndLowParts: LSASNExtractHighAndLowPartsFunc!
private var fn_IOPMCopyAssertionsByProcess: IOPMCopyAssertionsByProcessFunc?
private var fn_sandbox_check: SandboxCheckFunc?

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

// MARK: - CLI

struct Options {
    var json = false
    var noColor = false
    var showAll = false       // show all processes (default: only hung)
    var showSHA = false       // show SHA-256 column (hidden by default)
    var pids: [pid_t] = []
    var names: [String] = []
    var help = false
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
        case "-h", "--help":  o.help = true
        default: fputs("Unknown option: \(args[i])\n", stderr); exit(2)
        }
        i += 1
    }
    return o
}

func printHelp() {
    print("""
    hung_detect — macOS Hung App Detector
    Uses the same Window Server API as Activity Monitor.

    By default scans ALL GUI processes and only shows Not Responding ones.

    USAGE: hung_detect [OPTIONS]

    OPTIONS:
      --all, -a        Show all processes (default: only Not Responding)
      --sha            Show SHA-256 column
      --pid <PID>      Check specific PID (repeatable, shows all statuses)
      --name <NAME>    Match name/bundle id (repeatable, shows all statuses)
      --json           JSON output (always includes SHA-256)
      --no-color       Disable ANSI colors
      -h, --help       Show help

    EXIT CODES: 0 = all ok, 1 = hung detected, 2 = error

    EXAMPLES:
      hung_detect              Detect hung apps (exit 1 if any found)
      hung_detect --all        List all GUI apps with full details
      hung_detect --name Chrome  Show details for Chrome processes
      hung_detect --json       Machine-readable output
    """)
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

func printJSON(_ entries: [ProcEntry]) {
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

    print("""
    {
      "scan_time": "\(fmt.string(from: Date()))",
      "summary": { "total": \(entries.count), "not_responding": \(hungN), "ok": \(okN) },
      "processes": [
    \(procs.joined(separator: ",\n"))
      ]
    }
    """)
}

// MARK: - Main

func main() -> Int32 {
    let opts = parseArgs()
    if opts.help { printHelp(); return 0 }

    // Colors: disable if --no-color, not a tty, or NO_COLOR env set
    C.enabled = !opts.noColor && !opts.json && isatty(STDOUT_FILENO) != 0
        && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

    guard loadAPIs() else {
        fputs("Error: failed to load private APIs. Requires macOS with Window Server.\n", stderr)
        return 2
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

    // Output: targeted/--all shows everything, default shows only hung
    let showAll = targeted || opts.showAll
    if opts.json {
        // JSON always includes SHA-256, but compute lazily only for rows that will be emitted.
        let base = showAll ? entries : entries.filter { !$0.responding }
        let output = addSHA256(base)
        printJSON(output)
    } else {
        if opts.showSHA {
            // Table without --all only prints hung rows, so avoid hashing healthy rows.
            entries = addSHA256(entries, onlyHung: !showAll)
        }
        printTable(entries, showAll: showAll, showSHA: opts.showSHA)
    }

    return entries.contains(where: { !$0.responding }) ? 1 : 0
}

exit(main())
