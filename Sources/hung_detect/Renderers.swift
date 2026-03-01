// Renderers.swift — Output formatting for table and JSON modes.
// TableRenderer: box-drawing table with terminal width fitting and ANSI colors.
// JSONRenderer: pretty-printed (CLI) and compact (MCP) JSON output.
// TextLayout: Unicode-aware string measurement and truncation.
// C: ANSI color code helpers.

import Foundation

// MARK: - ANSI Colors

final class C {
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
    private static func typeBreakdownFromCounts(_ total: Int, _ counts: [AppType: Int]) -> String {
        var detail = [String]()
        if let n = counts[.foreground], n > 0 { detail.append("FG:\(n)") }
        if let n = counts[.uiElement], n > 0 { detail.append("UIElem:\(n)") }
        if let n = counts[.backgroundOnly], n > 0 { detail.append("BG:\(n)") }
        if let n = counts[.unregistered], n > 0 { detail.append("other:\(n)") }
        return detail.isEmpty ? "\(total) scanned" : "\(total) scanned (\(detail.joined(separator: " ")))"
    }

    static func renderProcessTable(_ entries: [ProcEntry], list: Bool, showSHA: Bool,
                                    totalScanned: Int = 0, typeCounts: [AppType: Int] = [:]) {
        let rows = list ? entries : entries.filter { $0.responding == false }

        // Summary counts
        let hungN = entries.filter { $0.responding == false }.count
        let scanTotal = totalScanned > 0 ? totalScanned : entries.count
        let scanBreakdown = typeBreakdownFromCounts(scanTotal, typeCounts)

        let scanTime = isoFormatter.string(from: Date())

        if rows.isEmpty {
            print("\(C.dim)hung_detect \(toolVersion) (built \(buildTime)) scanned \(scanTime)\(C.reset)")
            print("\(C.green)All processes responding.\(C.reset) \(C.dim)\(scanBreakdown)\(C.reset)")
            return
        }

        // Column defs: header, rightAlign, flexible (shares remaining width), truncateLeft, getter
        var colDefs: [(hdr: String, rAlign: Bool, flex: Bool, tLeft: Bool, get: (ProcEntry) -> String)] = [
            ("ST",     false, false, false, { e in
                switch e.responding { case true: return "OK"; case false: return "HUNG"; case nil: return "-" }
            }),
            ("TYPE",   false, false, false, { $0.appType.shortLabel }),
            ("PID",    true,  false, false, { "\($0.pid)" }),
            ("PPID",   true,  false, false, { "\($0.ppid)" }),
            ("USER",   false, false, false, { $0.user }),
            ("NAME",   false, true,  false, { $0.name }),
            ("BUNDLE ID", false, true, false, { $0.bundleID }),
            ("ARCH",   false, false, false, { $0.arch }),
            ("SIGN",   false, true,  false, { $0.codesign }),
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

        print("\(C.dim)hung_detect \(toolVersion) (built \(buildTime)) scanned \(scanTime)\(C.reset)")
        print(hLine("\u{250c}", "\u{252c}", "\u{2510}"))

        let hdr = colDefs.enumerated().map { (i, c) in " \(TextLayout.pad(c.hdr, widths[i], right: c.rAlign)) " }
        print("\(C.bold)\u{2502}" + hdr.joined(separator: "\u{2502}") + "\u{2502}\(C.reset)")

        print(hLine("\u{251c}", "\u{253c}", "\u{2524}"))

        for (r, row) in rows.enumerated() {
            let cells = rawCells[r].enumerated().map { (i, s) in " \(TextLayout.pad(s, widths[i], right: colDefs[i].rAlign)) " }
            let color = row.responding == false ? C.red : ""
            print("\(color)\u{2502}" + cells.joined(separator: "\u{2502}") + "\u{2502}\(C.reset)")
        }

        print(hLine("\u{2514}", "\u{2534}", "\u{2518}"))

        let okN = scanTotal - hungN
        if hungN > 0 {
            print("\(C.boldRed)\(hungN) not responding\(C.reset), \(okN) ok  \(C.dim)\(scanBreakdown)\(C.reset)")
        } else {
            print("\(C.green)\(okN) ok\(C.reset)  \(C.dim)\(scanBreakdown)\(C.reset)")
        }
        var legend = "ST=Status  SAND=Sandboxed  SLEEP=Preventing Sleep"
        if showSHA { legend += "  SHA=SHA-256 first 8 chars" }
        print("\(C.dim)\(legend)\(C.reset)")
    }

    static func renderDiagnosis(_ results: [DiagToolResult]) {
        let ts = isoFormatter.string(from: Date())

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
        let ts = isoFormatter.string(from: event.timestamp)

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
            print("\(C.dim)hung_detect \(toolVersion) (built \(buildTime)) started \(isoFormatter.string(from: Date()))\(C.reset)")
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
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.append(Character(ch))
                }
            }
        }
        return out
    }

    static func renderProcessJSON(_ entries: [ProcEntry], diagnosis: [DiagToolResult] = []) {
    let hungN = entries.filter { $0.responding == false }.count
    let okN = entries.count - hungN

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
              "codesign_authority": \(e.codesign == "-" ? "null" : "\"\(escJSON(e.codesign))\""),
              "sandboxed": \(e.sandboxed),
              "preventing_sleep": \(e.preventingSleep),
              "elapsed_seconds": \(Int(e.uptime)),
              "responding": \(e.responding.map { "\($0)" } ?? "null"),
              "app_type": "\(e.appType.rawValue)"
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
      "version": "\(toolVersion)",
      "build_time": "\(buildTime)",
      "scan_time": "\(isoFormatter.string(from: Date()))",
      "summary": { "total": \(entries.count), "not_responding": \(hungN), "ok": \(okN) },
      "processes": [
    \(procs.joined(separator: ",\n"))
      ]\(diagJSON)
    }
    """)
    }

    static func renderProcessJSONString(_ entries: [ProcEntry]) -> String {
        let hungN = entries.filter { $0.responding == false }.count
        let okN = entries.count - hungN

        var procs: [String] = []
        for e in entries {
            procs.append("""
              {"pid":\(e.pid),"ppid":\(e.ppid),"user":"\(escJSON(e.user))","name":"\(escJSON(e.name))","bundle_id":\(e.bundleID == "-" ? "null" : "\"\(escJSON(e.bundleID))\""),"executable_path":"\(escJSON(e.path))","sha256":\(e.sha256 == "-" ? "null" : "\"\(e.sha256)\""),"arch":"\(e.arch)","codesign_authority":\(e.codesign == "-" ? "null" : "\"\(escJSON(e.codesign))\""),"sandboxed":\(e.sandboxed),"preventing_sleep":\(e.preventingSleep),"elapsed_seconds":\(Int(e.uptime)),"responding":\(e.responding.map { "\($0)" } ?? "null"),"app_type":"\(e.appType.rawValue)"}
            """.trimmingCharacters(in: .whitespaces))
        }

        return """
        {"version":"\(toolVersion)","build_time":"\(buildTime)","scan_time":"\(isoFormatter.string(from: Date()))","summary":{"total":\(entries.count),"not_responding":\(hungN),"ok":\(okN)},"processes":[\(procs.joined(separator: ","))]}
        """.trimmingCharacters(in: .whitespaces)
    }

    static func renderDiagnosis(_ results: [DiagToolResult]) {
        let ts = isoFormatter.string(from: Date())

        for r in results {
            let path = r.outputPath.map { "\"\(escJSON($0))\"" } ?? "null"
            let err = r.error.map { "\"\(escJSON($0))\"" } ?? "null"
            print("""
            {"timestamp":"\(ts)","event":"diagnosis","pid":\(r.pid),"name":"\(escJSON(r.name))","tool":"\(r.tool)","output_path":\(path),"elapsed":\(String(format: "%.1f", r.elapsed)),"error":\(err)}
            """.trimmingCharacters(in: .whitespaces))
        }
        fflush(stdout)
    }

    static func renderMonitorEvent(_ event: MonitorEvent) {
        let ts = isoFormatter.string(from: event.timestamp)
        print("""
        {"timestamp":"\(ts)","event":"\(event.eventType.rawValue)","pid":\(event.pid),"name":"\(escJSON(event.name))","bundle_id":\(event.bundleID == "-" ? "null" : "\"\(escJSON(event.bundleID))\"")}
        """.trimmingCharacters(in: .whitespaces))
        fflush(stdout)
    }

    static func renderMonitorMeta(type: String, interval: Double, pushAvailable: Bool) {
        let ts = isoFormatter.string(from: Date())
        print("""
        {"timestamp":"\(ts)","event":"\(type)","version":"\(toolVersion)","build_time":"\(buildTime)","interval":\(interval),"push_available":\(pushAvailable)}
        """.trimmingCharacters(in: .whitespaces))
        fflush(stdout)
    }
}

