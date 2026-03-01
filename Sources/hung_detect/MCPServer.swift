// MCPServer.swift — MCP (Model Context Protocol) JSON-RPC server over stdio.
// Exposes 5 tools: scan, check_pid, check_name, start_monitor, stop_monitor.
// Monitor supports optional diagnosis (sample/spindump/full) with MCP safety caps.

import Foundation

// MARK: - MCP Server

final class MCPServer {
    private let stdoutLock = NSLock()
    private var monitorState: [pid_t: ProcessSnapshot] = [:]
    private var monitorTimer: DispatchSourceTimer?
    private var monitorPIDs: [pid_t] = []
    private var monitorNames: [String] = []
    private var monitorType: ProcessType = .all
    private var isMonitoring = false
    private var monitorDiagRunner: DiagnosisRunner?

    // MARK: JSON-RPC helpers

    private func jsonRpcResult(id: Any, result: String) -> String {
        let idStr = MCPServer.formatId(id)
        return "{\"jsonrpc\":\"2.0\",\"id\":\(idStr),\"result\":\(result)}"
    }

    private func jsonRpcError(id: Any?, code: Int, message: String) -> String {
        let idStr = id.map { MCPServer.formatId($0) } ?? "null"
        return "{\"jsonrpc\":\"2.0\",\"id\":\(idStr),\"error\":{\"code\":\(code),\"message\":\"\(JSONRenderer.escJSON(message))\"}}"
    }

    private static func formatId(_ id: Any) -> String {
        if let n = id as? Int { return "\(n)" }
        if let n = id as? Int64 { return "\(n)" }
        if let n = id as? Double { return n.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(n))" : "\(n)" }
        if let s = id as? String { return "\"\(JSONRenderer.escJSON(s))\"" }
        return "null"
    }

    private func toolResult(text: String) -> String {
        return "{\"content\":[{\"type\":\"text\",\"text\":\"\(JSONRenderer.escJSON(text))\"}]}"
    }

    private func toolError(text: String) -> String {
        return "{\"content\":[{\"type\":\"text\",\"text\":\"\(JSONRenderer.escJSON(text))\"}],\"isError\":true}"
    }

    private func send(_ text: String) {
        stdoutLock.lock()
        print(text)
        fflush(stdout)
        stdoutLock.unlock()
    }

    // MARK: MCP protocol handlers

    private func handleInitialize(id: Any) -> String {
        let result = """
        {"protocolVersion":"2024-11-05","capabilities":{"tools":{},"logging":{}},"serverInfo":{"name":"hung_detect","version":"\(toolVersion)"}}
        """.trimmingCharacters(in: .whitespacesAndNewlines)
        return jsonRpcResult(id: id, result: result)
    }

    private func handleToolsList(id: Any) -> String {
        let tools = """
        {"tools":[{"name":"scan","description":"Scan all processes and detect Not Responding. Returns summary and process list.","inputSchema":{"type":"object","properties":{"list":{"type":"boolean","description":"Show all processes, not just hung ones (default: false)"},"show_sha":{"type":"boolean","description":"Include SHA-256 hash (default: false)"},"foreground_only":{"type":"boolean","description":"Only foreground apps (default: false)"},"type":{"type":"string","description":"Process type (default: lsapp)","enum":["foreground","uielement","gui","background","lsapp"]}}}},{"name":"check_pid","description":"Check a specific process by PID.","inputSchema":{"type":"object","properties":{"pid":{"type":"integer","description":"Process ID"}},"required":["pid"]}},{"name":"check_name","description":"Find processes by name or bundle ID (case-insensitive substring).","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"Process name or bundle ID"}},"required":["name"]}},{"name":"start_monitor","description":"Start monitoring. Pushes notifications on hung state changes. Optional diagnosis on hung.","inputSchema":{"type":"object","properties":{"pids":{"type":"array","items":{"type":"integer"},"description":"Monitor specific PIDs only"},"names":{"type":"array","items":{"type":"string"},"description":"Monitor specific names/bundle IDs only"},"interval":{"type":"number","description":"Poll interval seconds (default: 3, min: 0.5)"},"type":{"type":"string","description":"Process type (default: lsapp)","enum":["foreground","uielement","gui","background","lsapp"]},"sample":{"type":"boolean","description":"Run sample on hung processes"},"spindump":{"type":"boolean","description":"Run spindump on hung (implies sample, needs root)"},"full":{"type":"boolean","description":"Full diagnosis (implies spindump, needs root)"},"sample_duration":{"type":"integer","description":"Sample duration seconds (default: 10, max: 30)"},"spindump_duration":{"type":"integer","description":"Spindump duration seconds (default: 10, max: 30)"},"spindump_system_duration":{"type":"integer","description":"System spindump duration seconds (default: 10, max: 30)"},"outdir":{"type":"string","description":"Output directory for diagnosis files"}}}},{"name":"stop_monitor","description":"Stop monitoring.","inputSchema":{"type":"object","properties":{}}}]}
        """.trimmingCharacters(in: .whitespacesAndNewlines)
        return jsonRpcResult(id: id, result: tools)
    }

    private func handleToolCall(id: Any, params: [String: Any]?) -> String {
        guard let params = params,
              let toolName = params["name"] as? String else {
            return jsonRpcError(id: id, code: -32602, message: "Missing tool name")
        }
        let args = params["arguments"] as? [String: Any] ?? [:]

        switch toolName {
        case "scan":
            let listAll = args["list"] as? Bool ?? false
            let showSHA = args["show_sha"] as? Bool ?? false
            let fgOnly  = args["foreground_only"] as? Bool ?? false
            let typeStr = args["type"] as? String ?? "lsapp"
            let processType = fgOnly ? ProcessType.foreground : (ProcessType(rawValue: typeStr) ?? .lsapp)
            let result = performScan(list: listAll, showSHA: showSHA, processType: processType)
            let json = JSONRenderer.renderProcessJSONString(result.entries)
            return jsonRpcResult(id: id, result: toolResult(text: json))

        case "check_pid":
            guard let rawPID = (args["pid"] as? Int) ?? (args["pid"] as? Double).map({ Int($0) }),
                  rawPID >= 0, rawPID <= Int(Int32.max),
                  rawPID == rawPID /* NaN guard */ else {
                return jsonRpcError(id: id, code: -32602, message: "Missing or invalid 'pid' parameter")
            }
            let pid = pid_t(rawPID)
            let result = performScan(list: true, showSHA: false, filterPIDs: [pid])
            if result.entries.isEmpty {
                return jsonRpcResult(id: id, result: toolError(text: "No process found with PID \(pid)"))
            }
            let json = JSONRenderer.renderProcessJSONString(result.entries)
            return jsonRpcResult(id: id, result: toolResult(text: json))

        case "check_name":
            guard let name = args["name"] as? String, !name.isEmpty else {
                return jsonRpcError(id: id, code: -32602, message: "Missing or empty 'name' parameter")
            }
            let result = performScan(list: true, showSHA: false, filterNames: [name])
            if result.entries.isEmpty {
                return jsonRpcResult(id: id, result: toolError(text: "No processes found matching '\(name)'"))
            }
            let json = JSONRenderer.renderProcessJSONString(result.entries)
            return jsonRpcResult(id: id, result: toolResult(text: json))

        case "start_monitor":
            return handleStartMonitor(id: id, args: args)

        case "stop_monitor":
            return handleStopMonitor(id: id)

        default:
            return jsonRpcResult(id: id, result: toolError(text: "Unknown tool: \(toolName)"))
        }
    }

    // MARK: Monitor

    /// MCP safety cap for diagnosis durations (prevent AI agent from launching unbounded diagnosis).
    private static let mcpMaxDuration = 30

    private func clampDuration(_ val: Int?, default def: Int) -> Int {
        min(Self.mcpMaxDuration, max(1, val ?? def))
    }

    private func handleStartMonitor(id: Any, args: [String: Any]) -> String {
        stopMonitorInternal()

        monitorPIDs = (args["pids"] as? [Any])?.compactMap { v -> pid_t? in
            guard let raw = (v as? Int) ?? (v as? Double).map({ Int($0) }),
                  raw >= 0, raw <= Int(Int32.max) else { return nil }
            return pid_t(raw)
        } ?? []
        monitorNames = (args["names"] as? [Any])?.compactMap { $0 as? String } ?? []
        let interval = max(0.5, args["interval"] as? Double ?? 3.0)
        let typeStr = args["type"] as? String ?? "lsapp"
        monitorType = ProcessType(rawValue: typeStr) ?? .lsapp

        // Diagnosis params
        let wantSample = args["sample"] as? Bool ?? false
        let wantSpindump = args["spindump"] as? Bool ?? false
        let wantFull = args["full"] as? Bool ?? false
        let diagEnabled = wantSample || wantSpindump || wantFull

        if diagEnabled {
            var diagOpts = Options()
            diagOpts.sample = wantSample || wantSpindump || wantFull
            diagOpts.spindump = wantSpindump || wantFull
            diagOpts.full = wantFull
            diagOpts.sampleDuration = clampDuration(args["sample_duration"] as? Int, default: 10)
            diagOpts.spindumpDuration = clampDuration(args["spindump_duration"] as? Int, default: 10)
            diagOpts.spindumpSystemDuration = clampDuration(args["spindump_system_duration"] as? Int, default: 10)
            if let outdir = args["outdir"] as? String, !outdir.isEmpty {
                diagOpts.outdir = outdir
            }
            // Check spindump privileges upfront
            if (wantSpindump || wantFull) && getuid() != 0 {
                // Build equivalent CLI hint for the user
                var hint = "sudo hung_detect -m"
                if wantFull { hint += " --full" }
                else if wantSpindump { hint += " --spindump" }
                else { hint += " --sample" }
                if !monitorPIDs.isEmpty {
                    for p in monitorPIDs { hint += " --pid \(p)" }
                }
                if !monitorNames.isEmpty {
                    for n in monitorNames { hint += " --name \(n)" }
                }
                return jsonRpcResult(id: id, result: toolError(
                    text: "spindump/full diagnosis requires root. Run in terminal:\n  \(hint)\nOr restart MCP server with sudo:\n  sudo hung_detect --mcp"))
            }
            monitorDiagRunner = DiagnosisRunner(opts: diagOpts) { [weak self] results in
                self?.sendDiagnosisNotifications(results)
            }
        }

        isMonitoring = true
        monitorState = scanMonitorProcesses()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.monitorPollTick() }
        timer.resume()
        monitorTimer = timer

        var desc = "Monitoring started"
        if !monitorPIDs.isEmpty {
            desc += " (PIDs: \(monitorPIDs.map { String($0) }.joined(separator: ", ")))"
        } else if !monitorNames.isEmpty {
            desc += " (names: \(monitorNames.joined(separator: ", ")))"
        } else {
            desc += " (all processes)"
        }
        desc += ", type: \(monitorType.rawValue), interval: \(interval)s"
        if diagEnabled {
            var diag = [String]()
            if wantFull { diag.append("full") }
            else if wantSpindump { diag.append("spindump") }
            else if wantSample { diag.append("sample") }
            desc += ", diagnosis: \(diag.joined(separator: "+"))"
        }
        fputs("[hung_detect-mcp] \(desc)\n", stderr)
        return jsonRpcResult(id: id, result: toolResult(text: desc))
    }

    private func sendDiagnosisNotifications(_ results: [DiagToolResult]) {
        let ts = isoFormatter.string(from: Date())
        for r in results {
            let path = r.outputPath.map { "\"\(JSONRenderer.escJSON($0))\"" } ?? "null"
            let err = r.error.map { "\"\(JSONRenderer.escJSON($0))\"" } ?? "null"
            let notification = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{\"level\":\"info\",\"logger\":\"hung_detect\",\"data\":{\"event\":\"diagnosis_complete\",\"pid\":\(r.pid),\"name\":\"\(JSONRenderer.escJSON(r.name))\",\"tool\":\"\(r.tool)\",\"output_path\":\(path),\"elapsed\":\(String(format: "%.1f", r.elapsed)),\"error\":\(err),\"timestamp\":\"\(ts)\"}}}"
            send(notification)
        }
    }

    private func handleStopMonitor(id: Any) -> String {
        let wasActive = isMonitoring
        stopMonitorInternal()
        let msg = wasActive ? "Monitoring stopped" : "No active monitor"
        fputs("[hung_detect-mcp] \(msg)\n", stderr)
        return jsonRpcResult(id: id, result: toolResult(text: msg))
    }

    private func stopMonitorInternal() {
        monitorTimer?.cancel()
        monitorTimer = nil
        monitorState = [:]
        monitorPIDs = []
        monitorNames = []
        monitorType = .lsapp
        isMonitoring = false
        monitorDiagRunner = nil
    }

    private func monitorPollTick() {
        let current = scanMonitorProcesses()
        let events = MonitorEngine.diffStates(previous: monitorState, current: current, now: Date())
        monitorState = current

        var newlyHung: [(pid: pid_t, name: String)] = []
        for event in events {
            let level = event.eventType == .becameHung ? "alert" : "info"
            let bid = event.bundleID == "-" ? "null" : "\"\(JSONRenderer.escJSON(event.bundleID))\""
            let notification = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{\"level\":\"\(level)\",\"logger\":\"hung_detect\",\"data\":{\"event\":\"\(event.eventType.rawValue)\",\"pid\":\(event.pid),\"name\":\"\(JSONRenderer.escJSON(event.name))\",\"bundle_id\":\(bid),\"timestamp\":\"\(isoFormatter.string(from: event.timestamp))\"}}}"
            send(notification)
            if event.eventType == .becameHung {
                newlyHung.append((pid: event.pid, name: event.name))
            }
        }

        // Trigger async diagnosis for newly hung processes
        if let diagRunner = monitorDiagRunner, !newlyHung.isEmpty {
            diagRunner.triggerAsync(hungProcesses: newlyHung)
        }
    }

    private func scanMonitorProcesses() -> [pid_t: ProcessSnapshot] {
        let allLS = RuntimeAPI.allLSProcesses(useCache: true)
        let scoped = RuntimeAPI.filterByType(allLS, processType: monitorType)
        let filtered = RuntimeAPI.filterByPIDsAndNames(scoped, pids: monitorPIDs, names: monitorNames)

        var result: [pid_t: ProcessSnapshot] = [:]
        for entry in filtered {
            let pid = entry.pid
            let name = entry.info.resolvedName(pid: pid)
            let bid = entry.info.resolvedBundleID
            let fg = entry.info.appType == .foreground
            let hung = RuntimeAPI.isAppUnresponsive(pid: pid) ?? false
            result[pid] = ProcessSnapshot(name: name, bundleID: bid, foregroundApp: fg, responding: !hung,
                                          appType: entry.info.appType)
        }
        return result
    }

    // MARK: Request dispatch

    private func handleRequest(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            send(jsonRpcError(id: nil, code: -32700, message: "Parse error"))
            return
        }
        guard let method = json["method"] as? String else {
            send(jsonRpcError(id: json["id"], code: -32600, message: "Invalid request: missing method"))
            return
        }

        let id = json["id"]
        let params = json["params"] as? [String: Any]

        let response: String?
        switch method {
        case "initialize":
            response = id.map { handleInitialize(id: $0) }
        case "notifications/initialized":
            response = nil
        case "tools/list":
            response = id.map { handleToolsList(id: $0) }
        case "tools/call":
            response = id.map { handleToolCall(id: $0, params: params) }
        case "ping":
            response = id.map { jsonRpcResult(id: $0, result: "{}") }
        default:
            if id != nil {
                response = jsonRpcError(id: id, code: -32601, message: "Method not found: \(method)")
            } else {
                response = nil
            }
        }

        if let response = response {
            send(response)
        }
    }

    // MARK: Entry point

    static func run() -> Int32 {
        guard RuntimeAPI.loadAPIs() else {
            fputs("[hung_detect-mcp] Error: failed to load private APIs\n", stderr)
            return 2
        }
        fputs("[hung_detect-mcp] server started (pid \(getpid()), version \(toolVersion))\n", stderr)

        let server = MCPServer()

        // Read stdin on background thread, dispatch to main queue
        DispatchQueue.global(qos: .default).async {
            while let line = readLine(strippingNewline: true) {
                if line.isEmpty { continue }
                DispatchQueue.main.async {
                    server.handleRequest(line)
                }
            }
            DispatchQueue.main.async {
                fputs("[hung_detect-mcp] stdin closed, shutting down\n", stderr)
                server.stopMonitorInternal()
                CFRunLoopStop(CFRunLoopGetMain())
            }
        }

        // Main thread: run loop processes timers, AppKit notifications, dispatched requests
        withExtendedLifetime(server) {
            CFRunLoopRun()
        }
        return 0
    }
}

