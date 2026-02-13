# Monitor Mode for hung_detect

## Context

hung_detect is currently a single-shot tool: scan once, output, exit. The `--monitor` mode continuously watches for hung process state transitions using low-CPU multiplexing.

**Key insight from reverse-engineering Activity Monitor**: Apple uses a dual-layer approach:
1. **`CGSRegisterNotifyProc(750/751)`** — real-time push from Window Server for foreground apps (zero CPU, instant)
2. **`sysmon` + `CGSEventIsAppUnresponsive`** polling — periodic scan of all LaunchServices processes (1-5s interval)

We replicate this dual-layer architecture.

## File Modified

`hung_detect.swift` (grew from ~614 lines to ~870 lines)

## Changes

### 1. Private API Loading — add CGSRegisterNotifyProc (in existing `MARK: - Private API Loading`)

Added a new function pointer type and resolved it alongside existing CGS symbols:

```swift
private typealias CGSRegisterNotifyProcFunc = @convention(c) (
    @convention(c) (Int32, UnsafeMutableRawPointer?) -> Void,  // callback
    Int32,              // event type (750 = hung, 751 = responsive)
    UnsafeMutableRawPointer?  // user data
) -> UInt32

private var fn_CGSRegisterNotifyProc: CGSRegisterNotifyProcFunc?
```

Resolved in `loadAPIs()` from the same SkyLight/CoreGraphics handles, trying name variants `CGSRegisterNotifyProc` / `_CGSRegisterNotifyProc`.

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
```

All accessed from `.main` GCD queue only — no locks needed.

#### Layer 1: CGSRegisterNotifyProc callback (push, foreground only)

```swift
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
        outputMonitorEvent(MonitorEvent(..., eventType: .becameHung, ...))
    } else if !isHung && !wasResponding {
        snap.responding = true
        monitorState[pid] = snap
        outputMonitorEvent(MonitorEvent(..., eventType: .becameResponsive, ...))
    }
}
```

Registered in `runMonitor()`:
```swift
if fn_CGSRegisterNotifyProc != nil {
    _ = fn_CGSRegisterNotifyProc!(cgsNotifyCallback, 750, nil)  // app became hung
    _ = fn_CGSRegisterNotifyProc!(cgsNotifyCallback, 751, nil)  // app became responsive
}
```

**Key difference from Activity Monitor**: we do NOT check `isForegroundApp` — we accept push notifications for any tracked process. Activity Monitor limits this because it only updates UI for the foreground app via this path, but we want all events.

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
2. Register CGSRegisterNotifyProc(750/751) if available (Layer 1)
3. Initial scan -> `monitorState`; report any already-hung processes immediately
4. Create `DispatchSource.makeTimerSource` with `opts.interval` and 100ms leeway (Layer 2)
5. On each timer tick: scan -> diff against `monitorState` -> output changes -> update state
6. `dispatchMain()` (never returns; exit via signal handler)
7. Signal handler: cancel timer, print summary, `exit(hungCount > 0 ? 1 : 0)`

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

- **Dual-layer detection** — mirrors Activity Monitor's architecture: CGSRegisterNotifyProc for instant foreground detection + timer polling for comprehensive coverage
- **Push is optional** — if CGSRegisterNotifyProc fails to resolve (older macOS or API changes), falls back to polling-only gracefully
- **No `isForegroundApp` filter on push** — unlike Activity Monitor, we accept all push notifications since we want comprehensive monitoring (Activity Monitor filters because it only updates UI for foreground)
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
                    |  Layer 1: Push Callback     |  event 750 (hung)
                    |  (instant, foreground)      |  event 751 (responsive)
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
