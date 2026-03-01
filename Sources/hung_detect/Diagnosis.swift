// Diagnosis.swift — Automatic diagnosis (sample/spindump) for hung processes.
// DiagnosisRunner manages async diagnosis on hung state transitions.
// Security: SUDO_UID=0 filtered, output dir symlink resolved, files chmod 0600.

import Foundation

// MARK: - Diagnosis

/// Result of a single diagnosis tool invocation (sample or spindump).
struct DiagToolResult {
    let pid: pid_t           // Target process PID (0 for system-wide spindump)
    let name: String         // Target process name ("system" for system-wide)
    let tool: String         // "sample", "spindump", or "spindump-system"
    let outputPath: String?  // Path to output file, nil if failed
    let elapsed: Double      // Wall clock seconds
    let error: String?       // Error message if failed, nil on success
}

final class DiagnosisRunner {
    private let opts: Options
    private let outputHandler: ([DiagToolResult]) -> Void
    // Prevent duplicate captures for the same PID while an async diagnosis job is still running.
    private var diagnosingPIDs = Set<pid_t>()
    private let diagnosingPIDsLock = NSLock()
    // Lazily resolve once so monitor mode keeps all artifacts in a single directory.
    private var resolvedOutdir: String?
    private let outdirLock = NSLock()
    private let diagnosisQueue = DispatchQueue(label: "com.hung_detect.diagnosis",
                                               attributes: .concurrent)

    init(opts: Options, outputHandler: @escaping ([DiagToolResult]) -> Void) {
        self.opts = opts
        self.outputHandler = outputHandler
    }

    private final class DiagResultCollector {
        private var results: [DiagToolResult] = []
        private let lock = NSLock()
        func append(_ r: DiagToolResult) {
            lock.lock(); results.append(r); lock.unlock()
        }
        func collect() -> [DiagToolResult] {
            lock.lock(); defer { lock.unlock() }; return results
        }
    }

    /// Dispatch all diagnosis tools for the given processes.
    /// Callers wait on the returned group, then call collector.collect().
    private func dispatchDiagnosis(
        processes: [(pid: pid_t, name: String)],
        outdir: String,
        timestamp: String
    ) -> (collector: DiagResultCollector, group: DispatchGroup) {
        let collector = DiagResultCollector()
        let group = DispatchGroup()

        for proc in processes {
            if opts.sample {
                group.enter()
                diagnosisQueue.async {
                    let r = self.runSample(pid: proc.pid, name: proc.name,
                                           duration: self.opts.sampleDuration,
                                           intervalMs: self.opts.sampleIntervalMs,
                                           outdir: outdir,
                                           timestamp: timestamp)
                    collector.append(r)
                    group.leave()
                }
            }
            if opts.spindump {
                group.enter()
                diagnosisQueue.async {
                    let r = self.runSpindump(pid: proc.pid, name: proc.name,
                                              tool: "spindump",
                                              targetArgs: ["\(proc.pid)"],
                                              duration: self.opts.spindumpDuration,
                                              intervalMs: self.opts.spindumpIntervalMs,
                                              extraTimeout: 30,
                                              outdir: outdir,
                                              timestamp: timestamp)
                    collector.append(r)
                    group.leave()
                }
            }
        }
        if opts.full {
            group.enter()
            diagnosisQueue.async {
                let r = self.runSpindump(pid: 0, name: "system",
                                              tool: "spindump-system",
                                              targetArgs: ["-noTarget"],
                                              duration: self.opts.spindumpSystemDuration,
                                              intervalMs: self.opts.spindumpSystemIntervalMs,
                                              extraTimeout: 60,
                                              outdir: outdir,
                                              timestamp: timestamp)
                collector.append(r)
                group.leave()
            }
        }

        return (collector, group)
    }

    func runSingleShot(hungProcesses: [(pid: pid_t, name: String)]) -> [DiagToolResult] {
        guard let outdir = resolveDiagOutdir() else {
            return diagnosisOutdirErrorResults(hungProcesses: hungProcesses,
                                               reason: "failed to create output directory")
        }
        let timestamp = Self.diagnosisTimestamp()
        let (collector, group) = dispatchDiagnosis(
            processes: hungProcesses, outdir: outdir, timestamp: timestamp)
        group.wait()
        fixOwnership(dir: outdir)
        return collector.collect()
    }

    func triggerAsync(hungProcesses: [(pid: pid_t, name: String)]) {
        diagnosingPIDsLock.lock()
        let newProcs = hungProcesses.filter { !diagnosingPIDs.contains($0.pid) }
        for p in newProcs { diagnosingPIDs.insert(p.pid) }
        diagnosingPIDsLock.unlock()

        // --full may need a system-wide spindump even when no newly-hung PID is added.
        guard !newProcs.isEmpty || opts.full else { return }

        guard let outdir = resolveDiagOutdir() else {
            let errors = diagnosisOutdirErrorResults(hungProcesses: newProcs,
                                                     reason: "failed to create output directory")
            diagnosingPIDsLock.lock()
            for p in newProcs { diagnosingPIDs.remove(p.pid) }
            diagnosingPIDsLock.unlock()
            DispatchQueue.main.async {
                self.outputHandler(errors)
            }
            return
        }
        let timestamp = Self.diagnosisTimestamp()
        let (collector, group) = dispatchDiagnosis(
            processes: newProcs, outdir: outdir, timestamp: timestamp)

        diagnosisQueue.async {
            group.wait()
            self.fixOwnership(dir: outdir)
            let results = collector.collect()
            self.diagnosingPIDsLock.lock()
            for p in newProcs { self.diagnosingPIDs.remove(p.pid) }
            self.diagnosingPIDsLock.unlock()
            DispatchQueue.main.async {
                self.outputHandler(results)
            }
        }
    }

    /// Resolve original user for privilege drop when running under sudo.
    /// SUDO_UID=0 is filtered (forgery attempt to retain root). Same pattern as esmon.
    private func sudoOwner() -> (uid: UInt32, gid: UInt32)? {
        guard let uidStr = ProcessInfo.processInfo.environment["SUDO_UID"],
              let uid = UInt32(uidStr), uid != 0 else { return nil }
        let gid = ProcessInfo.processInfo.environment["SUDO_GID"].flatMap { UInt32($0) } ?? uid
        return (uid, gid)
    }

    private func chownPath(_ path: String, uid: UInt32, gid: UInt32) {
        _ = path.withCString { chown($0, uid, gid) }
    }

    private func fixOwnershipPath(_ path: String) {
        // Restrict permissions: diagnosis output may contain stack traces
        if getuid() == 0 { chmod(path, 0o600) }
        guard let owner = sudoOwner() else { return }
        chownPath(path, uid: owner.uid, gid: owner.gid)
    }

    private func resolveDiagOutdir() -> String? {
        outdirLock.lock()
        defer { outdirLock.unlock() }
        if let dir = resolvedOutdir { return dir }

        let dir: String
        if let custom = opts.outdir {
            // Resolve symlinks on the parent directory to prevent intermediate symlink attacks
            // (e.g., /tmp/evil_link/diag where /tmp/evil_link → /etc). Same pattern as esmon.
            let parent = (custom as NSString).deletingLastPathComponent
            let leaf = (custom as NSString).lastPathComponent
            if !parent.isEmpty {
                let resolvedParent = (parent as NSString).resolvingSymlinksInPath
                dir = (resolvedParent as NSString).appendingPathComponent(leaf)
                if dir != custom {
                    fputs("[warn] Output path resolved: \(custom) -> \(dir)\n", stderr)
                }
            } else {
                dir = custom
            }
        } else {
            dir = "hung_diag_\(Self.diagnosisTimestamp())"
        }
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            // Restrict directory permissions when running as root
            if getuid() == 0 { chmod(dir, 0o700) }
        } catch {
            fputs("Error: failed to create output directory '\(dir)': \(error.localizedDescription)\n", stderr)
            return nil
        }
        // If launched via sudo, immediately hand directory ownership back to invoking user.
        fixOwnership(dir: dir)
        resolvedOutdir = dir
        return dir
    }

    /// Sanitize process name for use in filenames. Allowlist approach: only permit
    /// safe characters, replace everything else with underscore.
    private func safeName(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.prefix(64))
    }

    private func diagnosisOutdirErrorResults(hungProcesses: [(pid: pid_t, name: String)],
                                             reason: String) -> [DiagToolResult] {
        let message = "diagnosis skipped: \(reason)"
        var results: [DiagToolResult] = []

        for proc in hungProcesses {
            if opts.sample {
                results.append(DiagToolResult(pid: proc.pid, name: proc.name, tool: "sample",
                                              outputPath: nil, elapsed: 0, error: message))
            }
            if opts.spindump {
                results.append(DiagToolResult(pid: proc.pid, name: proc.name, tool: "spindump",
                                              outputPath: nil, elapsed: 0, error: message))
            }
        }
        if opts.full {
            results.append(DiagToolResult(pid: 0, name: "system", tool: "spindump-system",
                                          outputPath: nil, elapsed: 0, error: message))
        }
        return results
    }

    private func runSample(pid: pid_t, name: String, duration: Int, intervalMs: Int,
                           outdir: String, timestamp: String) -> DiagToolResult {
        let outfile = "\(outdir)/\(timestamp)_\(safeName(name))_\(pid).sample.txt"
        let start = Date()
        let (ok, errStr) = Self.runDiagCommand(
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

    private func runSpindump(pid: pid_t, name: String, tool: String,
                              targetArgs: [String], duration: Int, intervalMs: Int,
                              extraTimeout: Int, outdir: String, timestamp: String) -> DiagToolResult {
        let suffix = pid == 0 ? "system.spindump.txt" : "\(safeName(name))_\(pid).spindump.txt"
        let outfile = "\(outdir)/\(timestamp)_\(suffix)"
        let start = Date()

        let isRoot = getuid() == 0
        let spindumpArgs = targetArgs + ["\(duration)", "\(intervalMs)", "-file", outfile]
        let exe: String
        let args: [String]
        if isRoot {
            exe = "/usr/sbin/spindump"
            args = spindumpArgs
        } else {
            exe = "/usr/bin/sudo"
            args = ["-n", "/usr/sbin/spindump"] + spindumpArgs
        }

        let (ok, errStr) = Self.runDiagCommand(executablePath: exe,
                                               arguments: args,
                                               timeout: TimeInterval(duration + extraTimeout))
        fixOwnershipPath(outfile)
        let elapsed = Date().timeIntervalSince(start)

        var finalErr: String?
        if !ok {
            if errStr.lowercased().contains("password") || errStr.lowercased().contains("sudo") {
                finalErr = "\(tool) requires root privileges"
            } else {
                finalErr = errStr.isEmpty ? "\(tool) failed" : errStr
            }
        }
        return DiagToolResult(pid: pid, name: name, tool: tool,
                              outputPath: ok ? outfile : nil,
                              elapsed: elapsed, error: finalErr)
    }

    private func fixOwnership(dir: String) {
        let isRoot = getuid() == 0
        // Restrict permissions regardless of sudo — diagnosis output contains stack traces
        if isRoot { chmod(dir, 0o700) }
        guard let owner = sudoOwner() else { return }
        chownPath(dir, uid: owner.uid, gid: owner.gid)
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: dir) else { return }
        // Keep resulting artifacts editable by the non-root caller after sudo execution.
        for case let rel as String in walker {
            let path = "\(dir)/\(rel)"
            if isRoot { chmod(path, 0o600) }
            chownPath(path, uid: owner.uid, gid: owner.gid)
        }
    }

    private static func diagnosisTimestamp(_ date: Date = Date()) -> String {
        fileTimestampFormatter.string(from: date)
    }

    static func runDiagCommand(executablePath: String, arguments: [String],
                               timeout: TimeInterval) -> (success: Bool, stderr: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = arguments
        let errPipe = Pipe()
        let errRead = errPipe.fileHandleForReading
        let errLock = NSLock()
        var errData = Data()
        errRead.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            errLock.lock()
            errData.append(chunk)
            errLock.unlock()
        }
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            errRead.readabilityHandler = nil
            return (false, "Failed to launch: \(error.localizedDescription)")
        }

        // Hard timeout guard so diagnosis tools cannot block monitor mode forever.
        let killItem = DispatchWorkItem { [weak proc] in
            if let p = proc, p.isRunning { p.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killItem)

        proc.waitUntilExit()
        killItem.cancel()

        errRead.readabilityHandler = nil
        let tail = errRead.readDataToEndOfFile()
        errLock.lock()
        errData.append(tail)
        let finalErrData = errData
        errLock.unlock()

        let errStr = String(data: finalErrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (proc.terminationStatus == 0, errStr)
    }
}

