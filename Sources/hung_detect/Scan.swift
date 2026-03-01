// Scan.swift — Single-shot process scan logic.
// Used by CLI default mode, MCP scan/check_pid/check_name tools.
// Delegates process enumeration to RuntimeAPI, entry building to ProcEntry factories.

import Foundation

// MARK: - Scan

/// Result of a single scan pass. Includes both the display entries (filtered by
/// list/targeted flags) and metadata for the summary line.
struct ScanResult {
    let entries: [ProcEntry]        // Filtered + enriched (codesign, SHA)
    let hungCount: Int
    let okCount: Int
    let totalScanned: Int           // All processes before display filtering
    let typeCounts: [AppType: Int]  // Breakdown by ApplicationType for summary
}

/// Perform a single-shot scan of processes.
/// - `list`: if true, include all processes in output (not just hung)
/// - `processType`: filter by ApplicationType (default: all LS-registered)
/// - `filterPIDs`/`filterNames`: targeted lookup (auto-expands to all processes including non-LS)
func performScan(list: Bool, showSHA: Bool, processType: ProcessType = .lsapp,
                 filterPIDs: [pid_t] = [], filterNames: [String] = []) -> ScanResult {
    let sleepPIDs = ProcessInspector.sleepPreventingPIDs()
    let targeted = !filterPIDs.isEmpty || !filterNames.isEmpty

    var entries: [ProcEntry]

    if !filterPIDs.isEmpty && filterNames.isEmpty {
        // Fast path: direct PID lookup — no full process enumeration needed.
        // Each PID is probed individually via LS + sysctl, O(n) where n = number of PIDs requested.
        entries = filterPIDs.compactMap { pid in
            if let lsInfo = RuntimeAPI.lsAppInfo(pid: pid) {
                return ProcEntry.from(pid: pid, lsInfo: lsInfo, sleepPIDs: sleepPIDs)
            } else {
                return ProcEntry.fromPID(pid, sleepPIDs: sleepPIDs)
            }
        }
    } else if !filterNames.isEmpty {
        // Name search: try LS processes first (fast, ~265), fall back to full scan only if no match.
        let lsProcs = RuntimeAPI.allLSProcesses()
        let lsMatched = RuntimeAPI.filterByPIDsAndNames(lsProcs, pids: filterPIDs, names: filterNames)
        if !lsMatched.isEmpty {
            entries = lsMatched.map { ProcEntry.from(pid: $0.pid, lsInfo: $0.info, sleepPIDs: sleepPIDs) }
        } else {
            // No LS match — expand to all processes (includes non-LS like wxutility, python, etc.)
            let allProcs = RuntimeAPI.allProcesses()
            let allMatched = RuntimeAPI.filterByPIDsAndNames(allProcs, pids: filterPIDs, names: filterNames)
            entries = allMatched.compactMap { c in
                if let info = c.info {
                    return ProcEntry.from(pid: c.pid, lsInfo: info, sleepPIDs: sleepPIDs)
                } else {
                    return ProcEntry.fromPID(c.pid, sleepPIDs: sleepPIDs)
                }
            }
        }
    } else {
        // Default: scan all LS processes matching the requested type
        let allLS = RuntimeAPI.allLSProcesses()
        let scoped = RuntimeAPI.filterByType(allLS, processType: processType)
        entries = scoped.map { ProcEntry.from(pid: $0.pid, lsInfo: $0.info, sleepPIDs: sleepPIDs) }
    }

    // Sort: hung first (nil responding = unknown, sort after hung but before ok), then by name
    entries.sort {
        let r0 = $0.responding ?? true  // nil treated as ok for sorting
        let r1 = $1.responding ?? true
        if r0 != r1 { return !r0 }
        return $0.name.lowercased() < $1.name.lowercased()
    }

    let display = (targeted || list) ? entries : entries.filter { $0.responding == false }
    var output = ProcessInspector.addCodeSign(display)
    if showSHA {
        output = ProcessInspector.addSHA256(output)
    }

    // Type breakdown from full scan (before display filtering)
    var typeCounts: [AppType: Int] = [:]
    for e in entries { typeCounts[e.appType, default: 0] += 1 }

    let hungCount = output.filter { $0.responding == false }.count
    return ScanResult(entries: output, hungCount: hungCount, okCount: output.count - hungCount,
                      totalScanned: entries.count, typeCounts: typeCounts)
}

