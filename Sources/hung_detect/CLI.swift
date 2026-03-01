// CLI.swift — Command-line argument parsing, help text, and MCP client config install/uninstall.
// Defines Options struct (all CLI flags) and CLI class (parser, help, MCP install).

import Foundation

// MARK: - CLI

/// All CLI options parsed from command-line arguments.
/// Default values represent behavior with no flags (scan LS processes, show only hung).
struct Options {
    var json = false              // --json: output as JSON
    var noColor = false           // --no-color: disable ANSI escape codes
    var list = false              // --list / -l: show all processes, not just hung
    var showSHA = false           // --sha: include SHA-256 column
    var processType: ProcessType = .lsapp  // --type: filter by LS ApplicationType
    var pids: [pid_t] = []                // --pid: filter by PID (repeatable)
    var names: [String] = []              // --name: filter by name/bundleID (repeatable)
    var help = false                      // -h / --help
    var version = false                   // -v / --version
    var monitor = false                   // -m / --monitor: continuous monitoring mode
    var interval: Double = 3.0            // --interval: poll interval for monitor (seconds)
    var sample = false                    // --sample: run /usr/bin/sample on hung processes
    var spindump = false                  // --spindump: run spindump (implies --sample, needs root)
    var full = false                      // --full: system-wide spindump (implies --spindump)
    var sampleDuration: Int = 10          // --sample-duration: seconds (min 1)
    var sampleIntervalMs: Int = 1         // --sample-interval-ms: milliseconds (min 1)
    var spindumpDuration: Int = 10        // --spindump-duration: seconds (min 1)
    var spindumpIntervalMs: Int = 10      // --spindump-interval-ms: milliseconds (min 1)
    var spindumpSystemDuration: Int = 10  // --spindump-system-duration: seconds (min 1)
    var spindumpSystemIntervalMs: Int = 10 // --spindump-system-interval-ms: milliseconds (min 1)
    var outdir: String? = nil             // --outdir: diagnosis output directory
    var mcp = false                       // --mcp: run as MCP JSON-RPC server over stdio
    var mcpConfig = false                 // --mcp-config: print MCP server config JSON
    var mcpInstall = false                // --mcp-install: install MCP config to AI clients
    var mcpUninstall = false              // --mcp-uninstall: remove MCP config from AI clients

    /// Whether any diagnosis flag is set.
    var diagnosisEnabled: Bool { sample || spindump || full }
    /// Diagnosis level: 0=none, 1=sample only, 2=+per-process spindump, 3=+system-wide spindump.
    var diagLevel: Int {
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
            case "--list", "-l":  o.list = true
            case "--sha":         o.showSHA = true
            case "--foreground-only": o.processType = .foreground
            case "--type":
                i += 1
                guard i < args.count, let v = ProcessType(rawValue: args[i].lowercased()),
                      v != .all else {
                    fputs("--type must be one of: foreground, uielement, gui, background, lsapp\n", stderr); exit(2)
                }
                o.processType = v
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
            case "--mcp":         o.mcp = true
            case "--mcp-config":    o.mcpConfig = true
            case "--mcp-install":   o.mcpInstall = true
            case "--mcp-uninstall": o.mcpUninstall = true
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
            ("--list, -l", "List all processes (default: only Not Responding)"),
            ("--sha", "Show SHA-256 column"),
            ("--foreground-only", "Only include foreground-type apps (alias for --type foreground)"),
            ("--type <TYPE>", "Process type: foreground, uielement, gui, background, lsapp (default: lsapp)"),
            ("--pid <PID>", "Check specific PID (repeatable, shows all statuses)"),
            ("--name <NAME>", "Match name/bundle id (repeatable, shows all statuses)"),
            ("--monitor, -m", "Continuous monitoring mode (Ctrl+C to stop)"),
            ("--interval <SECS>", "Polling interval for monitor mode (default: 3, min: 0.5)"),
            ("--json", "JSON output (NDJSON in monitor mode)"),
            ("--no-color", "Disable ANSI colors"),
            ("--mcp", "Run as MCP server over stdio (for AI tool integration)"),
            ("--mcp-config", "Print MCP server configuration JSON"),
            ("--mcp-install", "Install MCP config to all detected AI clients"),
            ("--mcp-uninstall", "Remove MCP config from all detected AI clients"),
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
            ("hung_detect", "Detect hung processes (exit 1 if any found)"),
            ("hung_detect -l", "List all LS-registered processes"),
            ("hung_detect --type foreground -l", "List only Dock apps"),
            ("hung_detect --type gui -l", "List Dock + menu bar apps"),
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
            ("hung_detect --mcp", "Start MCP server for AI integration"),
        ]

        let optionsText = renderHelpRows(optionRows)
        let diagnosisText = renderHelpRows(diagnosisIntroRows) + "\n\n" + renderHelpRows(diagnosisParamRows)
        let examplesText = exampleRows.map { cmd, desc in
            "  # \(desc)\n  \(cmd)"
        }.joined(separator: "\n\n")

        print("""
        hung_detect — macOS Hung App Detector
        Uses the same Window Server API as Activity Monitor.

        By default scans ALL LaunchServices-known processes and only shows Not Responding ones.

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

    // MARK: MCP client config install

    // Keep mcpServerConfig and mcpServerTOMLConfig in sync — they represent the same MCP entry.
    private static let mcpServerConfig: [String: Any] = [
        "command": "hung_detect",
        "args": ["--mcp"]
    ]
    private static let mcpServerTOMLConfig = """
    [mcp_servers.hung_detect]
    command = "hung_detect"
    args = [
        "--mcp",
    ]
    """

    /// Config file format for MCP client auto-install.
    private enum MCPClientFormat {
        case json(topKey: String?, nestedKey: String?)  // Standard JSON (most clients), optional nested key path (e.g. VS Code "mcp.servers")
        case toml                                       // TOML format (Codex)
    }

    /// An AI client that supports MCP server configuration.
    private struct MCPClientTarget {
        let name: String       // Display name (e.g. "Claude Desktop")
        let configDir: String  // Config directory (must exist for install)
        let configFile: String // Config filename within configDir
        let format: MCPClientFormat
    }

    private static func userHomeDirectoryPath() -> String {
        ProcessInfo.processInfo.environment["HUNG_DETECT_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    private static func removeTOMLTable(named tableName: String, from text: String) -> String {
        let header = "[\(tableName)]"
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [String] = []
        var index = 0

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed == header else {
                result.append(lines[index])
                index += 1
                continue
            }

            index += 1
            while index < lines.count {
                let nextTrimmed = lines[index].trimmingCharacters(in: .whitespaces)
                if nextTrimmed.hasPrefix("[") && nextTrimmed.hasSuffix("]") {
                    break
                }
                index += 1
            }
        }

        return result.joined(separator: "\n")
    }

    private static func ensureTOMLSectionSpacing(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var out = text
        if !out.hasSuffix("\n") { out += "\n" }
        if !out.hasSuffix("\n\n") { out += "\n" }
        return out
    }

    /// Back up the original file, write new content, and preserve file permissions.
    private static func writePreservingPermissions(_ content: String, toFile path: String) throws {
        let fm = FileManager.default
        let backupPath = path + ".bak"
        let origPerms = (try? fm.attributesOfItem(atPath: path))?[.posixPermissions] as? Int

        // Back up existing file before overwrite
        if fm.fileExists(atPath: path) {
            try? fm.removeItem(atPath: backupPath)
            try fm.copyItem(atPath: path, toPath: backupPath)
        }

        try content.write(toFile: path, atomically: true, encoding: .utf8)
        if let perms = origPerms {
            try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: path)
        }
    }

    private static func updateJSONMCPClient(
        name: String,
        configPath: String,
        topKey: String?,
        nestedKey: String?,
        uninstall: Bool
    ) -> Bool {
        let fm = FileManager.default

        var config: [String: Any] = [:]
        if let data = fm.contents(atPath: configPath) {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                config = json
            } else if !data.isEmpty {
                // File exists but is not valid JSON (e.g. JSONC with comments) — skip to avoid data loss
                fputs("Skipping \(name): \(configPath) contains non-standard JSON (comments?)\n", stderr)
                return false
            }
        }

        let mcpServers: NSMutableDictionary
        if let topKey = topKey, let nestedKey = nestedKey {
            let topDict = (config[topKey] as? [String: Any]) ?? [:]
            let mTop = NSMutableDictionary(dictionary: topDict)
            let nested = (topDict[nestedKey] as? [String: Any]) ?? [:]
            let mNested = NSMutableDictionary(dictionary: nested)
            mcpServers = mNested
            mTop[nestedKey] = mcpServers
            config[topKey] = mTop
        } else {
            let servers = (config["mcpServers"] as? [String: Any]) ?? [:]
            mcpServers = NSMutableDictionary(dictionary: servers)
            config["mcpServers"] = mcpServers
        }

        if uninstall {
            guard mcpServers["hung_detect"] != nil else { return false }
            mcpServers.removeObject(forKey: "hung_detect")
        } else {
            // Already configured — skip rewrite
            if mcpServers["hung_detect"] != nil { return false }
            mcpServers["hung_detect"] = mcpServerConfig
        }

        guard let outData = try? JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .sortedKeys]),
              let outStr = String(data: outData, encoding: .utf8) else {
            return false
        }

        do {
            try writePreservingPermissions(outStr, toFile: configPath)
            return true
        } catch {
            fputs("Error writing \(configPath): \(error)\n", stderr)
            return false
        }
    }

    private static func updateTOMLMCPClient(name: String, configPath: String, uninstall: Bool) -> Bool {
        let fm = FileManager.default
        var config = ""

        if let data = fm.contents(atPath: configPath) {
            guard let text = String(data: data, encoding: .utf8) else {
                fputs("Skipping \(name): \(configPath) contains non-UTF-8 data\n", stderr)
                return false
            }
            config = text
        }

        let cleaned = removeTOMLTable(named: "mcp_servers.hung_detect", from: config)
        let updated: String

        if uninstall {
            guard cleaned != config else { return false }
            updated = cleaned
        } else {
            // Already configured — skip rewrite
            if cleaned != config { /* had existing entry, will re-add below */ }
            else if config.contains("[mcp_servers.hung_detect]") { return false }
            updated = ensureTOMLSectionSpacing(cleaned) + mcpServerTOMLConfig + "\n"
        }

        do {
            try writePreservingPermissions(updated, toFile: configPath)
            return true
        } catch {
            fputs("Error writing \(configPath): \(error)\n", stderr)
            return false
        }
    }

    static func printMCPConfig() {
        let config: [String: Any] = ["mcpServers": ["hung_detect": mcpServerConfig]]
        if let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }

    static func installMCPServers(uninstall: Bool) {
        let home = userHomeDirectoryPath()
        let appSupport = "\(home)/Library/Application Support"

        let clients: [MCPClientTarget] = [
            MCPClientTarget(name: "Claude", configDir: "\(appSupport)/Claude", configFile: "claude_desktop_config.json",
                            format: .json(topKey: nil, nestedKey: nil)),
            MCPClientTarget(name: "Claude Code", configDir: home, configFile: ".claude.json",
                            format: .json(topKey: nil, nestedKey: nil)),
            MCPClientTarget(name: "Cursor", configDir: "\(home)/.cursor", configFile: "mcp.json",
                            format: .json(topKey: nil, nestedKey: nil)),
            MCPClientTarget(name: "Windsurf", configDir: "\(home)/.codeium/windsurf", configFile: "mcp_config.json",
                            format: .json(topKey: nil, nestedKey: nil)),
            MCPClientTarget(name: "Cline", configDir: "\(appSupport)/Code/User/globalStorage/saoudrizwan.claude-dev/settings",
                            configFile: "cline_mcp_settings.json", format: .json(topKey: nil, nestedKey: nil)),
            MCPClientTarget(name: "Roo Code", configDir: "\(appSupport)/Code/User/globalStorage/rooveterinaryinc.roo-cline/settings",
                            configFile: "mcp_settings.json", format: .json(topKey: nil, nestedKey: nil)),
            MCPClientTarget(name: "Kilo Code", configDir: "\(appSupport)/Code/User/globalStorage/kilocode.kilo-code/settings",
                            configFile: "mcp_settings.json", format: .json(topKey: nil, nestedKey: nil)),
            MCPClientTarget(name: "LM Studio", configDir: "\(home)/.lmstudio", configFile: "mcp.json",
                            format: .json(topKey: nil, nestedKey: nil)),
            MCPClientTarget(name: "Gemini CLI", configDir: "\(home)/.gemini", configFile: "settings.json",
                            format: .json(topKey: nil, nestedKey: nil)),
            MCPClientTarget(name: "BoltAI", configDir: "\(appSupport)/BoltAI", configFile: "config.json",
                            format: .json(topKey: nil, nestedKey: nil)),
            MCPClientTarget(name: "Warp", configDir: "\(home)/.warp", configFile: "mcp_config.json",
                            format: .json(topKey: nil, nestedKey: nil)),
            MCPClientTarget(name: "Amazon Q", configDir: "\(home)/.aws/amazonq", configFile: "mcp_config.json",
                            format: .json(topKey: nil, nestedKey: nil)),
            MCPClientTarget(name: "VS Code", configDir: "\(appSupport)/Code/User", configFile: "settings.json",
                            format: .json(topKey: "mcp", nestedKey: "servers")),
            MCPClientTarget(name: "Codex", configDir: "\(home)/.codex", configFile: "config.toml",
                            format: .toml),
        ]

        var installed = 0
        let fm = FileManager.default
        for client in clients {
            let configPath = "\(client.configDir)/\(client.configFile)"

            guard fm.fileExists(atPath: client.configDir) else {
                print("Skipping \(client.name)\n  Config: \(configPath) (not found)")
                continue
            }

            let updated: Bool
            switch client.format {
            case let .json(topKey, nestedKey):
                updated = updateJSONMCPClient(
                    name: client.name,
                    configPath: configPath,
                    topKey: topKey,
                    nestedKey: nestedKey,
                    uninstall: uninstall
                )
            case .toml:
                updated = updateTOMLMCPClient(name: client.name, configPath: configPath, uninstall: uninstall)
            }

            if updated {
                let action = uninstall ? "Uninstalled" : "Installed"
                print("\(action) \(client.name) MCP server (restart required)\n  Config: \(configPath)")
                installed += 1
            } else if !uninstall {
                print("\(client.name) already configured\n  Config: \(configPath)")
            }
        }

        if !uninstall && installed == 0 {
            print("No MCP clients detected. Use --mcp-config to print config manually.")
        }
    }
}
