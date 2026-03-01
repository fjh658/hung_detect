#!/usr/bin/swift
// main.swift — macOS Hung App Detector
// Entry point: parses CLI args, dispatches to the appropriate command handler.
// Simple commands (help, version, MCP install) run without loading private APIs.
// Scan and monitor commands require RuntimeAPI.loadAPIs() to resolve CGS/LS symbols.

import Foundation

// MARK: - Commands

private func doHelp() -> Int32 {
    CLI.printHelp()
    return 0
}

private func doVersion() -> Int32 {
    print("hung_detect \(toolVersion) (built \(buildTime))")
    return 0
}

private func doMCPConfig() -> Int32 {
    CLI.printMCPConfig()
    return 0
}

private func doMCPInstall(uninstall: Bool) -> Int32 {
    CLI.installMCPServers(uninstall: uninstall)
    return 0
}

private func doMCP() -> Int32 {
    MCPServer.run()
}

private func doMonitor(opts: Options, diagnosisRunner: DiagnosisRunner?) -> Int32 {
    MonitorEngine.runMonitor(opts: opts, diagnosisRunner: diagnosisRunner)
}

private func doScan(opts: Options, diagnosisRunner: DiagnosisRunner?) -> Int32 {
    let targeted = !opts.pids.isEmpty || !opts.names.isEmpty
    let scanResult = performScan(list: opts.list || targeted, showSHA: opts.showSHA,
                                 processType: opts.processType, filterPIDs: opts.pids, filterNames: opts.names)
    if targeted && scanResult.entries.isEmpty {
        fputs("No matching processes found.\n", stderr)
        return 2
    }
    let entries = scanResult.entries

    var diagResults: [DiagToolResult] = []
    if opts.diagnosisEnabled {
        let hungForDiag = entries.filter { $0.responding == false }.map { (pid: $0.pid, name: $0.name) }
        if let diagnosisRunner, !hungForDiag.isEmpty {
            diagResults = diagnosisRunner.runSingleShot(hungProcesses: hungForDiag)
        }
    }

    if opts.json {
        var output = entries
        if !opts.showSHA { output = ProcessInspector.addSHA256(output) }
        JSONRenderer.renderProcessJSON(output, diagnosis: diagResults)
    } else {
        TableRenderer.renderProcessTable(entries, list: targeted || opts.list, showSHA: opts.showSHA,
                                         totalScanned: scanResult.totalScanned, typeCounts: scanResult.typeCounts)
        if !diagResults.isEmpty { TableRenderer.renderDiagnosis(diagResults) }
    }

    return scanResult.hungCount > 0 ? 1 : 0
}

// MARK: - Setup

private func setupRuntime(opts: Options) -> Bool {
    C.enabled = !opts.noColor && !opts.json && isatty(STDOUT_FILENO) != 0
        && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

    guard RuntimeAPI.loadAPIs() else {
        fputs("Error: failed to load private APIs. Requires macOS with Window Server.\n", stderr)
        return false
    }
    guard CLI.requireSpindumpPrivilegesIfNeeded(opts: opts) else { return false }
    return true
}

private func makeDiagnosisRunner(opts: Options) -> DiagnosisRunner? {
    guard opts.diagnosisEnabled else { return nil }
    return DiagnosisRunner(opts: opts) { results in
        if opts.json { JSONRenderer.renderDiagnosis(results) }
        else         { TableRenderer.renderDiagnosis(results) }
    }
}

// MARK: - Main

func main() -> Int32 {
    let opts = CLI.parseArgs()

    if opts.help         { return doHelp() }
    if opts.version      { return doVersion() }
    if opts.mcpConfig    { return doMCPConfig() }
    if opts.mcpInstall   { return doMCPInstall(uninstall: false) }
    if opts.mcpUninstall { return doMCPInstall(uninstall: true) }
    if opts.mcp          { return doMCP() }

    guard setupRuntime(opts: opts) else { return 2 }
    let diagRunner = makeDiagnosisRunner(opts: opts)

    if opts.monitor { return doMonitor(opts: opts, diagnosisRunner: diagRunner) }
    return doScan(opts: opts, diagnosisRunner: diagRunner)
}

exit(main())
