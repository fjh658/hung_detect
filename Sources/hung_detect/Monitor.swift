// Monitor.swift — Continuous monitoring mode (--monitor / -m).
// Polls process states at configurable interval, diffs against previous snapshot,
// emits state transition events. Supports push notifications via CGSRegisterNotifyProc.

import Foundation
import CGSInternalShim

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
                // Only report EXIT for processes that were hung — normal process
                // turnover (Finder extensions, helpers, etc.) is noise.
                if !prev.responding {
                    events.append(MonitorEvent(timestamp: now, eventType: .processExited,
                                               pid: pid, name: prev.name, bundleID: prev.bundleID))
                }
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
    private let diagnosisRunner: DiagnosisRunner?
    private var state: [pid_t: ProcessSnapshot] = [:]
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
                     diagnosisRunner: DiagnosisRunner?) {
        self.opts = opts
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

        // Use CFRunLoopRun instead of dispatchMain() so that AppKit/LaunchServices
        // notifications are fully processed — keeps NSWorkspace.shared.runningApplications
        // in sync with newly launched (or terminated) apps.
        // dispatchMain() only processes GCD events; it does NOT pump the NSRunLoop,
        // so NSWorkspace's cached process list never updates for apps launched after
        // the monitor started.  CFRunLoopRun processes all common-mode sources
        // (NSWorkspace, GCD main queue, signal sources) and never returns.
        withExtendedLifetime(self) {
            CFRunLoopRun()
        }
        // Unreachable — shutdown() calls exit() from the signal handler.
        return hungCount > 0 ? 1 : 0
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
        if let lsInfo = RuntimeAPI.lsAppInfo(pid: pid) {
            snap.foregroundApp = lsInfo.appType == .foreground
        }
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

    private func scanProcesses() -> [pid_t: ProcessSnapshot] {
        requireMainThread()
        let allLS = RuntimeAPI.allLSProcesses(useCache: true)
        let scoped = RuntimeAPI.filterByType(allLS, processType: opts.processType)
        let filtered = RuntimeAPI.filterByPIDsAndNames(scoped, pids: opts.pids, names: opts.names)

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

    private func outputMonitorEvent(_ event: MonitorEvent) {
        if opts.json {
            JSONRenderer.renderMonitorEvent(event)
        } else {
            TableRenderer.renderMonitorEvent(event)
        }
    }

    private func printMonitorMeta(type: String) {
        if opts.json {
            JSONRenderer.renderMonitorMeta(type: type,
                                           interval: opts.interval,
                                           pushAvailable: pushActive)
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

        let regHung = (RuntimeAPI.registerNotify(callback: Self.cgsNotifyCallback,
                                                  eventType: kCGSNotificationAppUnresponsive,
                                                  userData: notifyUserData) == .success)
        let regResponsive = (RuntimeAPI.registerNotify(callback: Self.cgsNotifyCallback,
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
        if registeredHung {
            _ = RuntimeAPI.removeNotify(callback: Self.cgsNotifyCallback,
                                         eventType: kCGSNotificationAppUnresponsive,
                                         userData: notifyUserData)
        }
        if registeredResponsive {
            _ = RuntimeAPI.removeNotify(callback: Self.cgsNotifyCallback,
                                         eventType: kCGSNotificationAppResponsive,
                                         userData: notifyUserData)
        }
    }

    static func runMonitor(opts: Options, diagnosisRunner: DiagnosisRunner?) -> Int32 {
        let engine = MonitorEngine(opts: opts, diagnosisRunner: diagnosisRunner)
        return engine.run()
    }
}

