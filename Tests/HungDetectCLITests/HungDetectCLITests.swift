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

    try process.run()
    process.waitUntilExit()

    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
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
        XCTAssertEqual(long.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hung_detect \(Self.expectedVersion)")

        let short = try runCLI(["-v"])
        XCTAssertEqual(short.code, 0, short.stderr)
        XCTAssertEqual(short.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hung_detect \(Self.expectedVersion)")
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
}
