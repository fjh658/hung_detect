# Monitor Mode for hung_detect

## Context

hung_detect is currently a single-shot tool: scan once, output, exit. The `--monitor` mode continuously watches for hung process state transitions using low-CPU multiplexing.

## Current Implementation Status (2026-02-20)

The monitor path has since been refactored from early function/global-state style to class-based structure. Treat the notes below as design history; current source of truth is `Sources/hung_detect/main.swift`.

- Runtime private API loading: `CGSBridge` resolves symbols once and keeps immutable loaded state.
- Monitor runtime: `MonitorEngine` owns monitor state, polling timer, signal handling, and push registration lifecycle.
- Push callback signature is 4-arg (`type, data, dataLength, userData`) and is wired via per-instance `userData` pointer.
- Unknown/early push PID now triggers immediate reconcile rescan (instead of dropping until next poll tick).
- Diagnosis runtime: `DiagnosisRunner` handles async diagnosis queueing and per-PID deduplication.

**Key insight from reverse-engineering Activity Monitor**: Apple uses a dual-layer approach:
1. **`CGSRegisterNotifyProc(kCGSNotificationAppUnresponsive/kCGSNotificationAppResponsive)`** — real-time push from Window Server for foreground apps (zero CPU, instant)
2. **`sysmon` + `CGSEventIsAppUnresponsive`** polling — periodic scan of all LaunchServices processes (1-5s interval)

We replicate this dual-layer architecture.

## File Modified

`Sources/hung_detect/main.swift`

## Changes

### 1. Private API Loading — add CGSRegisterNotifyProc (in existing `MARK: - Private API Loading`)

Added callback/registration function pointer types and resolved them alongside existing CGS symbols:

```swift
private typealias CGSNotifyProcPtr = @convention(c) (
    CGSNotificationType, UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?
) -> Void
private typealias CGSRegisterNotifyProcFunc = @convention(c) (
    CGSNotifyProcPtr, CGSNotificationType, UnsafeMutableRawPointer?
) -> CGError
private typealias CGSRemoveNotifyProcFunc = @convention(c) (
    CGSNotifyProcPtr, CGSNotificationType, UnsafeMutableRawPointer?
) -> CGError
```

Resolved in `CGSBridge.resolveSymbols()` via `CFBundleGetFunctionPointerForName` first, then `dlsym` fallback (including underscore variants where needed).

**This is optional/fallback** — if it fails to resolve, monitor mode still works via polling-only.

### 2. New Data Types (inserted after Data Types section, before `// MARK: - CLI`)

```swift
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
    let foregroundApp: Bool
    var responding: Bool
}
```

### 3. CLI Parsing Changes

**Options struct** — added two fields:
```swift
var monitor = false
var interval: Double = 3.0
```

**parseArgs()** — added cases:
```swift
case "--monitor", "-m": o.monitor = true
case "--interval":
    i += 1
    guard i < args.count, let v = Double(args[i]), v >= 0.5 else {
        fputs("--interval needs a number >= 0.5\n", stderr); exit(2)
    }
    o.interval = v
```

**printHelp()** — added to OPTIONS and EXAMPLES sections:
```
OPTIONS:
  --monitor, -m       Continuous monitoring mode (Ctrl+C to stop)
  --interval <SECS>   Polling interval for monitor mode (default: 3, min: 0.5)

EXAMPLES:
  hung_detect --monitor                 Watch for hung state changes
  hung_detect --monitor --json | jq .   Stream events as NDJSON
  hung_detect -m --name Safari --interval 2  Monitor Safari every 2s
```

### 4. Monitor Core Logic (new `MARK: - Monitor` section, inserted before `// MARK: - Main`)

#### Global State

```swift
private var monitorState: [pid_t: ProcessSnapshot] = [:]
private var monitorOpts: Options = Options()
private var monitorFmt: ISO8601DateFormatter = { ... }()
private var monitorHungCount = 0
private var pushRescanScheduled = false
```

All accessed from `.main` GCD queue only — no locks needed.

#### Layer 1: CGSRegisterNotifyProc callback (push, foreground only)

```swift
private let cgsNotifyCallback: CGSNotifyProcPtr = {
    eventType, data, dataLength, userData in
    _ = userData
    let pid = pushPayloadPID(data, dataLength: dataLength) // reads pid at payload + 0xC
    guard let pid else { schedulePushRescan(); return }    // unknown payload -> immediate reconcile
    if !applyPushEvent(eventType: eventType, pid: pid, now: Date()) {
        schedulePushRescan() // unknown PID in state map -> immediate reconcile
    }
}
```

Registered in `runMonitor()`:
```swift
enableMonitorPushIfAvailable() // requires both kCGSNotificationAppUnresponsive and kCGSNotificationAppResponsive registration success
```

Push updates are filtered to foreground-type apps (`activationPolicy == .regular`) to align with Activity Monitor behavior, and foreground classification is refreshed at callback time.

#### Layer 2: DispatchSourceTimer polling (all processes)

**`scanProcesses(opts:)`** — lightweight scan returning `[pid_t: ProcessSnapshot]`:
- Enumerates `NSWorkspace.shared.runningApplications`
- Applies `--pid`/`--name` filters (reuses existing filter pattern from main)
- Calls `isAppUnresponsive()` for each
- Returns dictionary keyed by PID

**`diffStates(previous:current:now:)`** — produces `[MonitorEvent]`:
- Processes in previous but not current -> `.processExited`
- Processes where `responding` changed: `true->false` = `.becameHung`, `false->true` = `.becameResponsive`
- PID reuse guard: if same PID but different name/bundleID -> emit exit + new hung if applicable
- New processes that are already hung -> `.becameHung` (report initial hung state)

**`runMonitor(opts:)`** — the main entry point:
1. Setup `DispatchSource.makeSignalSource` for SIGINT/SIGTERM on `.main` queue
2. Register CGSRegisterNotifyProc(kCGSNotificationAppUnresponsive/kCGSNotificationAppResponsive) and mark push active only if both registrations succeed (Layer 1)
3. Initial scan -> `monitorState`
4. Report any already-hung processes immediately
5. Create `DispatchSource.makeTimerSource` with `opts.interval` and 100ms leeway (Layer 2)
6. On each timer tick: scan -> diff against `monitorState` -> output changes -> update state
7. `dispatchMain()` (never returns; exit via signal handler)
8. Signal handler: unregister push callbacks (if available), print summary, `exit(hungCount > 0 ? 1 : 0)`

#### Output Functions

- `outputMonitorEvent(_ event:)` — dispatches to table or JSON based on `monitorOpts`
- `printMonitorEventTable(event:)` — `[HH:mm:ss] HUNG  AppName (PID 1234)` with ANSI color
- `printMonitorEventJSON(event:)` — NDJSON: `{"timestamp":"...","event":"became_hung","pid":1234,...}`
- `printMonitorMeta(type:interval:json:)` — startup/shutdown banners (table or JSON)

### 5. main() Integration

```swift
if opts.monitor {
    exit(runMonitor(opts: opts))
}
```

Single line after `loadAPIs()`. Existing single-shot path completely unchanged.

### 6. Design Decisions

- **Dual-layer detection** — CGSRegisterNotifyProc for low-latency updates + timer polling for comprehensive coverage
- **Push is optional** — if CGSRegisterNotifyProc fails to resolve or callback registration fails, monitor mode falls back to polling-only
- **Foreground-type push filter** — push state updates only apply to foreground-type apps, matching Activity Monitor callback behavior
- **Startup-window hardening** — push registration is active at startup, and unknown-PID push triggers immediate rescan
- **Dedup between layers** — polling diff checks against `monitorState` which push already updates, so no duplicate events
- **Terminal output only** — no osascript notifications; users can pipe `--json --monitor` to external tools
- **Report initial hung** — on startup, immediately report any already-hung processes
- **Lightweight scan** — monitor only collects PID/name/bundleID/hung status per tick (no sysctl, sha256, sandbox, etc.)
- **Thread safety** — push callback and timer both run on `.main` GCD queue via `dispatchMain()`, no locks needed
- **`dispatchMain()` pattern** — idiomatic Swift for GCD-driven CLI tools; exit via signal handler

### 7. Architecture Diagram

```
                    +---------------------------+
                    |     Window Server          |
                    +------------+--------------+
                                 | CGSRegisterNotifyProc
                    +------------v--------------+
                    |  Layer 1: Push Callback     |  kCGSNotificationAppUnresponsive
                    |  (instant, foreground)      |  kCGSNotificationAppResponsive
                    +------------+--------------+
                                 | updates monitorState
                                 | emits MonitorEvent
                    +------------v--------------+
  DispatchSource -->|  Layer 2: Timer Polling     |  every N seconds
  Timer (kqueue)    |  (comprehensive, all PIDs)  |  CGSEventIsAppUnresponsive
                    +------------+--------------+
                                 | diff against monitorState
                                 | emits MonitorEvent (deduped)
                    +------------v--------------+
                    |     Output (table/JSON)     |
                    +----------------------------+
```

## Verification

```bash
make build
# Basic monitor mode (dual-layer)
./hung_detect --monitor
# Filtered monitoring
./hung_detect --monitor --name Safari --interval 2
# JSON event stream (NDJSON, pipeable to jq)
./hung_detect --monitor --json | jq .
# Ctrl+C for clean shutdown, check exit code
echo $?
```

## Test Results

- Build: universal binary (arm64 + x86_64) compiles successfully
- `--help`: shows new `--monitor`, `--interval` options and examples
- Monitor table mode: starts with `Monitor mode (push+poll, interval 3.0s)`, clean SIGINT shutdown with `Monitor stopped. 0 hung event(s) detected.`, exit code 0
- Monitor JSON mode: emits `monitor_start` and `monitor_stop` NDJSON events with `push_available: true`
- Existing single-shot mode: completely unchanged
