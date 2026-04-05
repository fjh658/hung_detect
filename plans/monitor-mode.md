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

Push updates are filtered to foreground-type apps (LS ApplicationType == "Foreground") to align with Activity Monitor behavior, and foreground classification is refreshed at callback time via `RuntimeAPI.lsAppInfo(pid:)`.

#### Layer 2: DispatchSourceTimer polling (all LS-registered processes)

**`scanProcesses(opts:)`** — lightweight scan returning `[pid_t: ProcessSnapshot]`:
- Enumerates LS-registered processes via `RuntimeAPI.allLSProcesses(useCache: true)`
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
- **Thread safety** — push callback and timer both run on `.main` queue, no locks needed
- **`CFRunLoopRun()` run loop** — full NSRunLoop processing for CGS push notifications and GCD timer ticks; exit via signal handler

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

## Hung Detection False-Positive Mitigation (2026-02-26) — SUPERSEDED

> **Note (2026-04-05):** This section is historical. The false-positive filter (`activationPolicy != .regular && !windowOwnerPIDs`) was removed in v0.5.2.
> Process enumeration switched from `NSWorkspace.shared.runningApplications` to `proc_listpids` + `_LSCopyApplicationInformation`.
> Hung detection now applies only to LS-registered processes (same as Activity Monitor's `knownToLaunchServices` check).
> Non-LS processes are not checked — `CGSEventIsAppUnresponsive` returns meaningless results for processes without a Window Server event loop.
> See `plans/process-model.md` and `plans/tech-decisions.md` for current architecture.

## ~~Hung Detection False-Positive Mitigation (2026-02-26)~~

### Problem

`CGSEventIsAppUnresponsive` returns false positives for certain processes that lack a WindowServer event loop. Activity Monitor avoids this via the private entitlement `com.apple.private.SkyLight.user-accessibility-report`, which we cannot use. Empirically observed: PID 697 (`com.apple.hiservices-xpcservice`, an XPC service under HIServices.framework) consistently returns `hungRaw=true` while Activity Monitor shows it as normal.

### Root Cause (from reverse engineering Activity Monitor)

Activity Monitor's `-[SMProcess updateWithSysmonRow:sampleInterval:inspected:]` gates the hung check:

```objc
if ([self knownToLaunchServices]) {
    psn = [self psn];
    connID = CGSMainConnectionID();
    [self setHung: CGSEventIsAppUnresponsive(connID, &psn)];
}
```

The `knownToLaunchServices` flag (set via `_LSCopyApplicationInformation`) was tested but returns non-nil for PID 697 from unprivileged callers, so it cannot filter the false positive. The entitlement `com.apple.private.SkyLight.user-accessibility-report` is the differentiator — it gives Activity Monitor more accurate results from the WindowServer API. Confirmed identical logic in both arm64 and x86_64 binaries.

### Comprehensive Process Audit

Full audit of all 209 processes via `NSWorkspace.shared.runningApplications`, cross-referencing 6 dimensions:

| activationPolicy | LS Type (`_kLSApplicationTypeKey`) | Count | Has Windows | Hung (raw) | XPC Services |
|---|---|---|---|---|---|
| `.regular` (0) | Foreground | 24 | 24 (100%) | 0 | 0 |
| `.accessory` (1) | UIElement | 94 | 26 (28%) | 1 (PID 697) | 81 |
| `.prohibited` (2) | BackgroundOnly | 91 | 38 (42%) | 0 | 0 |

Key observations:
- `NSApplication.ActivationPolicy` is an enum with exactly 3 values — no fourth type exists
- Only PID 697 is a false positive across all 209 processes
- All 63 non-regular processes with windows correctly show as not-hung
- All 24 regular/Foreground apps have windows (none with 0 windows)

### Decision Matrix

All 12 combinations of `activationPolicy × hasWindows × hungRaw`:

| # | Policy | Windows | hungRaw | Action | Rationale |
|---|--------|---------|---------|--------|-----------|
| 1 | regular | yes | true | **Report HUNG** | Genuine hung foreground app with WS event loop |
| 2 | regular | yes | false | Report OK | Normal |
| 3 | regular | no | true | **Report HUNG** | Trust API for Dock-level apps (0 such processes exist currently) |
| 4 | regular | no | false | Report OK | Normal |
| 5 | accessory | yes | true | **Report HUNG** | Has windows → has WS event loop → API reliable |
| 6 | accessory | yes | false | Report OK | 26 processes verified correct |
| 7 | accessory | no | true | **Suppress** | No WS event loop → likely false positive (PID 697 falls here) |
| 8 | accessory | no | false | Report OK | 67 processes verified correct |
| 9 | prohibited | yes | true | **Report HUNG** | Has windows → has WS event loop → API reliable |
| 10 | prohibited | yes | false | Report OK | 38 processes verified correct |
| 11 | prohibited | no | true | **Suppress** | No WS event loop → likely false positive |
| 12 | prohibited | no | false | Report OK | 53 processes verified correct |

### Fix Implementation

Added `ProcessInspector.processHasWindows(pid:)` using `CGWindowListCopyWindowInfo`, applied in both code paths:

```swift
// One-shot scan (line ~1792) and monitor scan (line ~1638):
var hung = RuntimeAPI.isAppUnresponsive(pid: pid) ?? false
if hung && app.activationPolicy != .regular
    && !ProcessInspector.processHasWindows(pid: pid) {
    hung = false
}
```

Logic: when `CGSEventIsAppUnresponsive` reports a non-regular app as hung, cross-check whether it has windows registered with WindowServer. If no windows → suppress (no WS event loop, API unreliable; also no visible hung UI for user).

### Design Rationale

- **Window presence = WS event loop**: a process with windows must be registered with WindowServer and processes its events. `CGSEventIsAppUnresponsive` is reliable for these processes regardless of activation policy.
- **Windowless non-regular = no visual impact**: "Not Responding" is a UI responsiveness concept. A process with no windows cannot have a spinning beachball or frozen UI. Even if it were genuinely unresponsive, the user would not see it — the hung state would manifest through upstream callers (which do have windows).
- **Regular apps always trusted**: `.regular` (Dock-level) apps nearly always have windows and are expected to maintain a WS event loop. No current instances of regular apps with 0 windows exist. Conservatively trust the API here.
- **XPC services are NOT excluded**: the user confirmed Activity Monitor can detect XPC services as hung. Our fix does not filter by XPC status — if an XPC service has windows and genuinely hangs, it will be reported.
- **Matches Activity Monitor behavior**: Activity Monitor also does not show PID 697 as hung, confirming our suppression is correct.

### Verification Result

After the fix, all 209 processes match Activity Monitor's behavior:
- PID 697 (`com.apple.hiservices-xpcservice`): suppressed, shows OK
- All other 208 processes: unchanged, all show as responding
- Build: universal binary (arm64 + x86_64) compiles successfully

## 8. Bug Fix: Monitor Missing Newly Launched Processes (0.5.1, 2026-02-26)

### Problem

In monitor mode, processes launched **after** the monitor started were never detected as hung. The running monitor would only see processes that existed at startup time. A fresh `hung_detect -m` instance could detect the same hung process immediately.

### Root Cause

`MonitorEngine.run()` used `dispatchMain()` as its event loop. While `dispatchMain()` processes GCD events (timer ticks, async blocks, signal sources), it does **not** fully pump the NSRunLoop. Apple documents `NSWorkspace.shared.runningApplications` as: *"this property will only change when the main run loop is run in a common mode"*. The property maintains an internal cache that updates via AppKit/LaunchServices notifications delivered through NSRunLoop sources — sources that `dispatchMain()` never processes.

Result: the cached `runningApplications` array froze at its initial snapshot. Any app launched after the monitor started was invisible to all subsequent poll ticks.

### Discovery

Confirmed via reverse-engineering Activity Monitor (arm64 binary in IDA Pro):
- Activity Monitor is a full NSApplication GUI app using `[NSApp run]`, which fully processes NSRunLoop.
- Its `updateWithSysmonRow:sampleInterval:inspected:` calls `CGSEventIsAppUnresponsive` for each process on every refresh — same polling approach, but with a proper run loop.
- Its push callback (`CGSRegisterNotifyProc` for 750/751) also filters to foreground apps only — same as hung_detect.

### Fix

Replaced `dispatchMain()` with `CFRunLoopRun()` wrapped in `withExtendedLifetime(self)`:

```swift
// Before:
dispatchMain()

// After:
withExtendedLifetime(self) {
    CFRunLoopRun()
}
```

`CFRunLoopRun()` processes all common-mode run loop sources: NSWorkspace notifications, GCD main queue (timer/signal/async), and CGS push callbacks. This keeps `runningApplications` in sync with the live process list.

`withExtendedLifetime(self)` prevents ARC from releasing the `MonitorEngine` before the run loop starts (defensive measure against optimized builds).

### Follow-up: EXIT Event Noise Suppression

The `CFRunLoopRun()` fix caused a side effect: `NSWorkspace.shared.runningApplications` now properly tracks process lifecycle, so short-lived processes (Finder extensions, Quick Look helpers, etc.) that launch and exit between poll ticks each generate an EXIT event — flooding the monitor output with irrelevant noise.

Fix: `diffStates()` now only emits `processExited` events for processes that were **not responding** at the time they disappeared. Normal process turnover is silently ignored. This matches what users care about: knowing when a **hung** process dies.

```swift
// Before: EXIT for every disappeared process
events.append(MonitorEvent(timestamp: now, eventType: .processExited, ...))

// After: EXIT only for processes that were hung
if !prev.responding {
    events.append(MonitorEvent(timestamp: now, eventType: .processExited, ...))
}
```

Note: the PID-reuse guard (different process occupying the same PID) still always emits EXIT for correctness.

## 9. Code Signing Authority Field (2026-02-27)

### Feature

Added `codesign_authority` field to process output, showing the code signing certificate identity for each process.

### Three-State Output

| Value | Meaning |
|---|---|
| `"Developer ID Application: AgileBits Inc. (2BUA8C4S2C)"` | Properly signed — leaf certificate CN |
| `"adhoc"` | Ad-hoc / linker-signed, no certificate |
| `"unsigned"` | No code signature at all |
| `null` (JSON) / `-` (table) | Path unavailable |

### Implementation

- **Security framework**: `SecStaticCodeCreateWithPath` → `SecCodeCopySigningInformation` → `SecCertificateCopyCommonName`
- **Two-pass optimization**: First pass uses empty `SecCSFlags()` to quickly read `kSecCodeInfoFlags` and check the adhoc bit (`0x0002`). Only non-adhoc signed binaries proceed to the second pass with `kSecCSSigningInformation` flag (which extracts the full certificate chain).
- **Lazy computation**: Like SHA-256, codesign is initialized as `"-"` in `ProcEntry` and only resolved for rows that will be displayed (via `ProcessInspector.addCodeSign()`).
- **NSCache dedup**: Results cached by executable path within a single run. With 326 processes → 152 unique paths, 174 lookups are saved per scan.

### Performance Benchmark (326 processes, 152 unique paths)

| Mode | Wall time |
|---|---|
| Default (hung only) | ~0.1s |
| `--name <APP>` | ~0.09s |
| `--all` with cache | ~1.2s |
| `--all` without cache | ~1.4s (+12%) |

### Scope

- **Single-shot mode**: `codesign_authority` in JSON, `SIGN` column in table
- **Monitor mode**: No impact — monitor uses `ProcessSnapshot` (lightweight), not `ProcEntry`

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
- **0.5.1 regression test**: monitor correctly detects processes launched after monitor startup (verified with IDA Pro child process PID 26221)
