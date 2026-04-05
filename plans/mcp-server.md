# MCP Server Mode

## Context

AI models (Claude Code, Cursor, etc.) need to query hung process status at any time while working on tasks. The MCP (Model Context Protocol) server mode lets hung_detect run as a stdio-based tool server, exposing process scanning and real-time monitoring as MCP tools.

## Design Decisions

- **No external dependencies** — JSON-RPC 2.0 / MCP protocol implemented manually (consistent with project's zero-dep convention)
- **stdio transport** — read JSON-RPC from stdin, write responses to stdout, logs to stderr
- **Instance-based MCPServer** — supports stateful background monitoring with timer-based polling
- **Thread model** — stdin on background thread, main thread runs `CFRunLoopRun()` for timers and AppKit notifications, stdout serialized via `NSLock`

## Architecture

```
Background thread:  readLine() loop → parse JSON-RPC → dispatch to main queue
Main thread:        CFRunLoopRun() → process timers, poll ticks, dispatched requests
stdout writes:      serialized via stdoutLock (NSLock)
```

### Why this layout

- Process enumeration via `proc_listpids` + LaunchServices probe (no main thread requirement)
- stdin `readLine()` is blocking, must be on a background thread
- stdout needs a lock since both request handlers and monitor poll ticks write to it

## MCP Protocol

### Initialize capabilities

```json
{"protocolVersion":"2024-11-05","capabilities":{"tools":{},"logging":{}},"serverInfo":{"name":"hung_detect","version":"..."}}
```

`logging` capability declares the server can push `notifications/message` for monitor events.

### Method routing

| Method | Handler |
|---|---|
| `initialize` | Return protocol version, capabilities, server info |
| `notifications/initialized` | No response (notification) |
| `tools/list` | Return 5 tool definitions |
| `tools/call` | Dispatch to tool handler |
| `ping` | Return `{}` |
| unknown | JSON-RPC error -32601 |

## Tools

### Query tools

| Tool | Params | Description |
|---|---|---|
| `scan` | `list?: bool`, `show_sha?: bool`, `foreground_only?: bool`, `type?: string` | Scan all LS-known processes, report hung status |
| `check_pid` | `pid: int` (required) | Check specific process by PID |
| `check_name` | `name: string` (required) | Find processes by name/bundle ID (case-insensitive substring) |

Tool results use MCP content format:
```json
{"content":[{"type":"text","text":"<scan result JSON>"}]}
```

The inner text matches `--json` mode output (version, scan_time, summary, processes array). Error results set `"isError": true`.

### Monitor tools

| Tool | Params | Description |
|---|---|---|
| `start_monitor` | See below | Start background monitoring with push notifications and optional diagnosis |
| `stop_monitor` | (none) | Stop background monitoring |

**`start_monitor` parameters:**

| Param | Type | Default | Description |
|-------|------|---------|-------------|
| `pids` | `[int]` | all | Monitor specific PIDs only |
| `names` | `[string]` | all | Monitor specific process names/bundle IDs only |
| `interval` | `number` | 3 | Polling interval in seconds (min: 0.5) |
| `type` | `string` | `"all"` | Process scope: foreground, uielement, gui, background, all |
| `sample` | `bool` | false | Run `/usr/bin/sample` when a process becomes hung |
| `spindump` | `bool` | false | Run per-process spindump (implies `sample`, needs root) |
| `full` | `bool` | false | Full diagnosis: sample + spindump + system-wide spindump (needs root) |
| `sample_duration` | `int` | 10 | sample duration in seconds (min: 1, MCP max: 30) |
| `spindump_duration` | `int` | 10 | per-process spindump duration (min: 1, MCP max: 30) |
| `spindump_system_duration` | `int` | 10 | system spindump duration (min: 1, MCP max: 30) |
| `outdir` | `string` | auto | Output directory for diagnosis files |

**`start_monitor` behavior:**
- No params = monitor all LaunchServices-known processes
- `pids` / `names` = monitor only matching processes
- `type` = filter by ApplicationType (same as CLI `--type`)
- Re-calling `start_monitor` stops the previous monitor first
- Initial scan sets baseline; notifications fire on state transitions only
- Diagnosis runs asynchronously when a process becomes hung; `diagnosis_complete` notification pushed when done

**MCP safety limits:**
- Duration params capped at 30 seconds (prevents AI agent from launching unbounded diagnosis)
- `spindump`/`full` require root; if not root, diagnosis is skipped with error in notification

**Push notification format** — MCP `notifications/message`:
```json
{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"alert","logger":"hung_detect","data":"{\"event\":\"became_hung\",\"pid\":1234,\"name\":\"Safari\",\"bundle_id\":\"com.apple.Safari\",\"timestamp\":\"2026-03-11 14:30:25.123+08:00\"}"}}
```

**Notification events:**

| Event | Level | When |
|-------|-------|------|
| `became_hung` | `alert` | Process stopped responding |
| `became_responsive` | `info` | Previously hung process recovered |
| `process_exited` | `info` | Monitored process terminated |
| `diagnosis_complete` | `info` | sample/spindump finished for a hung process |

**`diagnosis_complete` notification format:**
```json
{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","logger":"hung_detect","data":"{\"event\":\"diagnosis_complete\",\"pid\":1234,\"name\":\"Safari\",\"tool\":\"sample\",\"output_path\":\"/path/to/sample.txt\",\"elapsed\":10.8,\"timestamp\":\"...\"}"}}
```

### Monitor implementation

- Background polling via `DispatchSource.makeTimerSource(queue: .main)`
- State tracked as `[pid_t: ProcessSnapshot]`
- State diffing reuses `MonitorEngine.diffStates()` (pure function, no side effects)
- `scanMonitorProcesses()` follows same pattern as `MonitorEngine.scanProcesses()` with local filter params
- False-positive mitigation: non-regular apps without WindowServer windows have hung flag cleared

## CLI Flags

| Flag | Description |
|---|---|
| `--mcp` | Run as MCP server over stdio |
| `--mcp-config` | Print MCP server configuration JSON |
| `--mcp-install` | Install MCP config to all detected AI clients |
| `--mcp-uninstall` | Remove MCP config from all detected AI clients |

### Supported clients (macOS)

`--mcp-install` / `--mcp-uninstall` auto-detect and configure:

| Client | Config path |
|---|---|
| Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` |
| Codex | `~/.codex/config.toml` (`[mcp_servers.hung_detect]` table) |
| Claude Code | `~/.claude.json` |
| Cursor | `~/.cursor/mcp.json` |
| Windsurf | `~/.codeium/windsurf/mcp_config.json` |
| VS Code | `~/Library/Application Support/Code/User/settings.json` (nested `mcp.servers`) |
| Cline | `~/Library/.../saoudrizwan.claude-dev/settings/cline_mcp_settings.json` |
| Roo Code | `~/Library/.../rooveterinaryinc.roo-cline/settings/mcp_settings.json` |
| Kilo Code | `~/Library/.../kilocode.kilo-code/settings/mcp_settings.json` |
| LM Studio | `~/.lmstudio/mcp.json` |
| Gemini CLI | `~/.gemini/settings.json` |
| BoltAI | `~/Library/Application Support/BoltAI/config.json` |
| Warp | `~/.warp/mcp_config.json` |
| Amazon Q | `~/.aws/amazonq/mcp_config.json` |

Only installs to clients whose config directory already exists. Writes atomically. Preserves existing config entries. Creates a `.bak` backup of the original config file before overwriting. Preserves original file permissions (e.g. 0600). Idempotent — skips with "already configured" if hung_detect entry already exists.

### MCP config JSON

```json
{
  "mcpServers": {
    "hung_detect": {
      "command": "hung_detect",
      "args": ["--mcp"]
    }
  }
}
```

## Key code structure

All in `Sources/hung_detect/main.swift`:

| Section | Content |
|---|---|
| `// MARK: - Scan` | `ScanResult` struct, `performScan()` — reusable scan logic for MCP tools |
| `JSONRenderer.renderProcessJSONString()` | Returns scan JSON as single-line `String` (no stdout contamination) |
| `// MARK: - MCP Server` | `MCPServer` class — protocol handling, tool dispatch, monitor state, polling timer |
| `CLI.printMCPConfig()` | Print MCP config JSON |
| `CLI.installMCPServers()` | Install/uninstall MCP config to AI clients |

## Multi-instance behavior

Each MCP client session launches its own `hung_detect --mcp` subprocess. Multiple instances are fully independent — `CGSEventIsAppUnresponsive` is a read-only query with no contention. No shared state or IPC needed.

## Verification

### Test commands

```bash
# Print config
hung_detect --mcp-config

# Install to all detected clients
hung_detect --mcp-install

# Full protocol flow test (initialize → tools/list → scan → start_monitor → stop_monitor → ping → error)
printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}\n{"jsonrpc":"2.0","method":"notifications/initialized"}\n{"jsonrpc":"2.0","id":2,"method":"tools/list"}\n{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"scan","arguments":{}}}\n{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"start_monitor","arguments":{"interval":1}}}\n{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"stop_monitor","arguments":{}}}\n{"jsonrpc":"2.0","id":6,"method":"ping"}\n{"jsonrpc":"2.0","id":7,"method":"unknown"}\n' | hung_detect --mcp

# Test targeted monitor (watch specific names)
printf '...\n{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"start_monitor","arguments":{"names":["Safari","Xcode"],"interval":1}}}\n' | hung_detect --mcp

# Test monitor push notifications (polls for 5s, observe notifications if any process state changes)
(printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}\n{"jsonrpc":"2.0","method":"notifications/initialized"}\n{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"start_monitor","arguments":{"interval":1}}}\n'; sleep 5) | hung_detect --mcp

# Uninstall from all clients
hung_detect --mcp-uninstall
```

### Verified results

| Test | Expected | Result |
|---|---|---|
| `initialize` | `protocolVersion`, `capabilities: {tools, logging}`, `serverInfo` | ✅ |
| `tools/list` | 5 tools: scan, check_pid, check_name, start_monitor, stop_monitor | ✅ |
| `scan` (default) | Only hung processes, JSON with summary + processes array | ✅ |
| `scan` (list) | All LS-known processes | ✅ (~243 processes) |
| `check_pid` (valid) | Single process info | ✅ |
| `check_pid` (invalid) | `isError: true` with "No process found" | ✅ |
| `check_name` | Matching processes by name/bundle ID | ✅ |
| `start_monitor` (global) | Confirmation text, polling timer starts | ✅ |
| `start_monitor` (targeted) | Confirmation with names/PIDs listed | ✅ |
| `stop_monitor` | "Monitoring stopped" | ✅ |
| `ping` | Empty result `{}` | ✅ |
| Unknown method | JSON-RPC error -32601 | ✅ |
| `--mcp-config` | Valid JSON with `mcpServers.hung_detect` | ✅ |
| `--mcp-install` | Installs to detected clients (Claude, Codex, Claude Code, Cursor, etc.) | ✅ (14 clients) |
| `--mcp-uninstall` | Removes hung_detect from all clients, preserves other entries | ✅ |
| Existing `--json` mode | No regression | ✅ |
| Existing table mode | No regression | ✅ |
| `bench/run.sh` AOP profiling | No regression | ✅ |

### Monitor notification format (verified)

When a process state changes during monitoring, the server pushes:

```json
{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"alert","logger":"hung_detect","data":{"event":"became_hung","pid":1234,"name":"Safari","bundle_id":"com.apple.Safari","timestamp":"2026-03-11 14:30:25.123+08:00"}}}
```

- `data` is a JSON object (not a string), clients parse it directly
- `level`: `"alert"` for became_hung, `"info"` for became_responsive / process_exited
- Notifications only fire on **state transitions**, not steady state
