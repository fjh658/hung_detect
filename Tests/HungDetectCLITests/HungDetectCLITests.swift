import XCTest
import Foundation

private struct CommandResult {
    let code: Int32
    let stdout: String
    let stderr: String
}

private func runCommand(
    _ executable: String,
    _ args: [String],
    cwd: URL? = nil
) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    process.currentDirectoryURL = cwd

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    let outRead = outPipe.fileHandleForReading
    let errRead = errPipe.fileHandleForReading
    let outLock = NSLock()
    let errLock = NSLock()
    var outData = Data()
    var errData = Data()

    outRead.readabilityHandler = { handle in
        let chunk = handle.availableData
        guard !chunk.isEmpty else { return }
        outLock.lock()
        outData.append(chunk)
        outLock.unlock()
    }
    errRead.readabilityHandler = { handle in
        let chunk = handle.availableData
        guard !chunk.isEmpty else { return }
        errLock.lock()
        errData.append(chunk)
        errLock.unlock()
    }

    try process.run()
    process.waitUntilExit()

    outRead.readabilityHandler = nil
    errRead.readabilityHandler = nil

    let outTail = outRead.readDataToEndOfFile()
    let errTail = errRead.readDataToEndOfFile()
    outLock.lock()
    outData.append(outTail)
    outLock.unlock()
    errLock.lock()
    errData.append(errTail)
    errLock.unlock()

    return CommandResult(
        code: process.terminationStatus,
        stdout: String(decoding: outData, as: UTF8.self),
        stderr: String(decoding: errData, as: UTF8.self)
    )
}

private func assertRegex(
    _ text: String,
    _ pattern: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let range = text.range(of: pattern, options: .regularExpression)
    XCTAssertNotNil(range, "Regex did not match: \(pattern)\n\nText:\n\(text)", file: file, line: line)
}

final class HungDetectCLITests: XCTestCase {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // HungDetectCLITests.swift
            .deletingLastPathComponent() // HungDetectCLITests
            .deletingLastPathComponent() // Tests
    }

    private static var binaryPath: String {
        repoRoot.appendingPathComponent("hung_detect").path
    }

    private static var expectedVersion: String {
        let versionURL = repoRoot.appendingPathComponent("Sources/hung_detect/Version.swift")
        guard let text = try? String(contentsOf: versionURL, encoding: .utf8) else { return "0.0.0" }
        let pattern = #"(?m)^\s*let\s+toolVersion\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let versionRange = Range(match.range(at: 1), in: text) else {
            return "0.0.0"
        }
        return String(text[versionRange])
    }

    override class func setUp() {
        super.setUp()
        do {
            _ = try runCommand("/usr/bin/make", ["-C", repoRoot.path, "build"])
        } catch {
            XCTFail("Failed to build binary before tests: \(error)")
        }
    }

    private func runCLI(_ args: [String]) throws -> CommandResult {
        try runCommand(Self.binaryPath, args)
    }

    private func assertParseError(_ args: [String], message: String) throws {
        let result = try runCLI(args)
        XCTAssertEqual(
            result.code, 2,
            "Expected exit code 2 for args=\(args)\nstdout=\(result.stdout)\nstderr=\(result.stderr)"
        )
        XCTAssertTrue(
            result.stderr.contains(message),
            "Expected stderr to contain '\(message)' for args=\(args)\nActual stderr=\(result.stderr)"
        )
    }

    func testHelpContainsSectionsAndNewOptions() throws {
        let result = try runCLI(["--help"])
        XCTAssertEqual(result.code, 0, result.stderr)

        let out = result.stdout
        let requiredSnippets = [
            "USAGE: hung_detect [OPTIONS]",
            "OPTIONS:",
            "DIAGNOSIS:",
            "EXAMPLES:",
            "--foreground-only",
            "--sample-duration <SECS>",
            "--sample-interval-ms <MS>",
            "--spindump-duration <SECS>",
            "--spindump-interval-ms <MS>",
            "--spindump-system-duration <SECS>",
            "--spindump-system-interval-ms <MS>",
            "--version",
            "scope:",
            "note:",
        ]
        for snippet in requiredSnippets {
            XCTAssertTrue(out.contains(snippet), "Missing snippet '\(snippet)'")
        }

        assertRegex(out, "note:.*\\n\\n  --duration <SECS>")
        assertRegex(out, "# Show details for a specific PID\\n  hung_detect --pid 913")
        assertRegex(out, "# Monitor \\+ full auto-diagnose on hung\\n  sudo hung_detect -m --full")
        assertRegex(
            out,
            "# Monitor \\+ full auto-diagnose with 5s spindumps\\n  sudo hung_detect -m --full --spindump-duration 5 --spindump-system-duration 5"
        )
    }

    func testUnknownOptionExitsWith2() throws {
        let result = try runCLI(["--does-not-exist"])
        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.stderr.contains("Unknown option: --does-not-exist"))
    }

    func testVersionOption() throws {
        let long = try runCLI(["--version"])
        XCTAssertEqual(long.code, 0, long.stderr)
        let longOut = long.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(longOut.hasPrefix("hung_detect \(Self.expectedVersion) (built "),
                      "Expected version prefix, got: \(longOut)")

        let short = try runCLI(["-v"])
        XCTAssertEqual(short.code, 0, short.stderr)
        let shortOut = short.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(shortOut.hasPrefix("hung_detect \(Self.expectedVersion) (built "),
                      "Expected version prefix, got: \(shortOut)")
    }

    func testMissingValueErrors() throws {
        let cases: [([String], String)] = [
            (["--pid"], "--pid needs a number"),
            (["--name"], "--name needs an argument"),
            (["--interval"], "--interval needs a number >= 0.5"),
            (["--duration"], "--duration needs an integer >= 1"),
            (["--sample-duration"], "--sample-duration needs an integer >= 1"),
            (["--sample-interval-ms"], "--sample-interval-ms needs an integer >= 1"),
            (["--spindump-duration"], "--spindump-duration needs an integer >= 1"),
            (["--spindump-interval-ms"], "--spindump-interval-ms needs an integer >= 1"),
            (["--spindump-system-duration"], "--spindump-system-duration needs an integer >= 1"),
            (["--spindump-system-interval-ms"], "--spindump-system-interval-ms needs an integer >= 1"),
            (["--outdir"], "--outdir needs a path"),
        ]
        for (args, message) in cases {
            try assertParseError(args, message: message)
        }
    }

    func testMinimumValueValidationErrors() throws {
        let cases: [([String], String)] = [
            (["--interval", "0.4"], "--interval needs a number >= 0.5"),
            (["--duration", "0"], "--duration needs an integer >= 1"),
            (["--sample-duration", "0"], "--sample-duration needs an integer >= 1"),
            (["--sample-interval-ms", "0"], "--sample-interval-ms needs an integer >= 1"),
            (["--spindump-duration", "0"], "--spindump-duration needs an integer >= 1"),
            (["--spindump-interval-ms", "0"], "--spindump-interval-ms needs an integer >= 1"),
            (["--spindump-system-duration", "0"], "--spindump-system-duration needs an integer >= 1"),
            (["--spindump-system-interval-ms", "0"], "--spindump-system-interval-ms needs an integer >= 1"),
        ]
        for (args, message) in cases {
            try assertParseError(args, message: message)
        }
    }

    func testDiagnosisFlagsParseWithHelp() throws {
        let result = try runCLI([
            "--duration", "9",
            "--sample-duration", "11",
            "--sample-interval-ms", "2",
            "--spindump-duration", "12",
            "--spindump-interval-ms", "15",
            "--spindump-system-duration", "13",
            "--spindump-system-interval-ms", "20",
            "--outdir", "/tmp/hd_test_out",
            "--help",
        ])
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("DIAGNOSIS:"))
    }

    // MARK: - Default scan

    func testDefaultScanExitCodeAndHeader() throws {
        let result = try runCLI([])
        // Exit 0 (no hung) or 1 (hung found) — both are valid runtime outcomes, not errors.
        XCTAssertTrue(result.code == 0 || result.code == 1,
                      "Expected exit 0 or 1, got \(result.code)\nstderr=\(result.stderr)")
        // Header line contains version and scan time
        assertRegex(result.stdout, "hung_detect \(Self.expectedVersion) \\(built [^)]+\\) scanned \\d{4}-\\d{2}-\\d{2}T")
    }

    // MARK: - JSON output structure

    func testJSONOutputStructure() throws {
        // Use --name Finder — Finder is always running
        let result = try runCLI(["--json", "--name", "Finder"])
        XCTAssertTrue(result.code == 0 || result.code == 1,
                      "Unexpected exit code \(result.code)\nstderr=\(result.stderr)")

        let data = result.stdout.data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // Top-level traceability fields
        XCTAssertEqual(obj["version"] as? String, Self.expectedVersion)
        XCTAssertNotNil(obj["build_time"] as? String, "Missing build_time")
        XCTAssertNotNil(obj["scan_time"] as? String, "Missing scan_time")

        // Summary object
        let summary = obj["summary"] as? [String: Any]
        XCTAssertNotNil(summary, "Missing summary")
        XCTAssertNotNil(summary?["total"] as? Int)
        XCTAssertNotNil(summary?["not_responding"] as? Int)
        XCTAssertNotNil(summary?["ok"] as? Int)

        // Processes array with expected fields
        let processes = obj["processes"] as? [[String: Any]]
        XCTAssertNotNil(processes, "Missing processes array")
        XCTAssertFalse(processes!.isEmpty, "Expected at least one process (Finder)")
        let proc = processes![0]
        for key in ["pid", "ppid", "user", "name", "bundle_id", "executable_path",
                     "sha256", "arch", "codesign_authority", "sandboxed",
                     "preventing_sleep", "elapsed_seconds", "responding"] {
            XCTAssertTrue(proc.keys.contains(key), "Missing key '\(key)' in process object")
        }
    }

    // MARK: - PID / name filters

    func testPidFilterShowsProcess() throws {
        // Get Finder's PID via the binary itself
        let json = try runCLI(["--json", "--name", "Finder"])
        let data = json.stdout.data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let procs = obj["processes"] as! [[String: Any]]
        let finderPid = procs[0]["pid"] as! Int

        let result = try runCLI(["--pid", "\(finderPid)"])
        XCTAssertTrue(result.code == 0 || result.code == 1)
        XCTAssertTrue(result.stdout.contains("Finder"), "Expected Finder in output")
    }

    func testNameFilterShowsProcess() throws {
        let result = try runCLI(["--name", "Finder"])
        XCTAssertTrue(result.code == 0 || result.code == 1)
        XCTAssertTrue(result.stdout.contains("Finder"), "Expected Finder in output")
    }

    func testNonExistentPidExitsWith2() throws {
        try assertParseError(["--pid", "99999"], message: "No matching processes found")
    }

    func testNonExistentNameExitsWith2() throws {
        try assertParseError(["--name", "nonexistent_app_xyz_999"], message: "No matching processes found")
    }

    // MARK: - Display flags

    func testAllFlagShowsMultipleProcesses() throws {
        let result = try runCLI(["--all"])
        XCTAssertTrue(result.code == 0 || result.code == 1)
        // --all should show many processes; at least the table header + a few rows
        let lines = result.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertGreaterThan(lines.count, 5, "Expected multiple output lines with --all")
    }

    func testShortAllFlag() throws {
        let result = try runCLI(["-a"])
        XCTAssertTrue(result.code == 0 || result.code == 1)
        let lines = result.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertGreaterThan(lines.count, 5, "Expected multiple output lines with -a")
    }

    func testForegroundOnlyReducesScope() throws {
        let all = try runCLI(["--all"])
        let fg = try runCLI(["--foreground-only", "--all"])
        // --foreground-only should produce fewer or equal lines
        let allLines = all.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
        let fgLines = fg.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertLessThanOrEqual(fgLines.count, allLines.count,
                                  "--foreground-only should not produce more output than --all alone")
    }

    func testNoColorFlagSuppressesANSI() throws {
        let result = try runCLI(["--no-color", "--name", "Finder"])
        XCTAssertTrue(result.code == 0 || result.code == 1)
        // ANSI escape sequences start with ESC (0x1b)
        XCTAssertFalse(result.stdout.contains("\u{1b}"),
                       "Output should not contain ANSI escape codes with --no-color")
    }

    func testShaFlagShowsSHAColumn() throws {
        let result = try runCLI(["--sha", "--name", "Finder"])
        XCTAssertTrue(result.code == 0 || result.code == 1)
        XCTAssertTrue(result.stdout.contains("SHA"), "Expected SHA column header")
    }
}
