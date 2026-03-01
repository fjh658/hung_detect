import XCTest
import Darwin
@testable import hung_detect

final class HungDetectCoreTests: XCTestCase {
    private func captureStdout(_ body: () -> Void) -> String {
        fflush(stdout)
        let originalStdout = dup(STDOUT_FILENO)
        precondition(originalStdout != -1, "failed to dup stdout")

        let pipe = Pipe()
        _ = dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        body()
        fflush(stdout)

        pipe.fileHandleForWriting.closeFile()
        _ = dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        pipe.fileHandleForReading.closeFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func snapshot(name: String,
                          bundleID: String,
                          foregroundApp: Bool = true,
                          responding: Bool) -> ProcessSnapshot {
        ProcessSnapshot(name: name,
                        bundleID: bundleID,
                        foregroundApp: foregroundApp,
                        responding: responding,
                        appType: foregroundApp ? .foreground : .uiElement)
    }

    func testFormatUptimeBoundaries() {
        XCTAssertEqual(TextLayout.formatUptime(59), "59s")
        XCTAssertEqual(TextLayout.formatUptime(61), "1m1s")
        XCTAssertEqual(TextLayout.formatUptime(3601), "1h0m")
        XCTAssertEqual(TextLayout.formatUptime(90061), "1d1h")
    }

    func testEscJSON() {
        let raw = "a\\b\"c\nd\te"
        XCTAssertEqual(JSONRenderer.escJSON(raw), "a\\\\b\\\"c\\nd\\te")
    }

    func testDisplayWidthAndTruncation() {
        XCTAssertEqual(TextLayout.displayWidth("abc"), 3)
        XCTAssertEqual(TextLayout.displayWidth("你好"), 4)
        XCTAssertEqual(TextLayout.truncR("abcdef", 4), "abc…")
        XCTAssertEqual(TextLayout.truncL("abcdef", 4), "…def")
    }

    func testParseArgsDefaults() {
        let opts = CLI.parseArgs([])
        XCTAssertFalse(opts.monitor)
        XCTAssertEqual(opts.interval, 3.0, accuracy: 0.0001)
        XCTAssertFalse(opts.processType == .foreground)
        XCTAssertFalse(opts.sample)
        XCTAssertFalse(opts.spindump)
        XCTAssertFalse(opts.full)
        XCTAssertEqual(opts.sampleDuration, 10)
        XCTAssertEqual(opts.sampleIntervalMs, 1)
        XCTAssertEqual(opts.spindumpDuration, 10)
        XCTAssertEqual(opts.spindumpIntervalMs, 10)
        XCTAssertEqual(opts.spindumpSystemDuration, 10)
        XCTAssertEqual(opts.spindumpSystemIntervalMs, 10)
    }

    func testParseArgsImplicationsAndDurations() {
        let opts = CLI.parseArgs([
            "--monitor",
            "--interval", "2",
            "--full",
            "--sample-duration", "11",
            "--sample-interval-ms", "2",
            "--spindump-duration", "12",
            "--spindump-interval-ms", "15",
            "--spindump-system-duration", "13",
            "--spindump-system-interval-ms", "20",
        ])

        XCTAssertTrue(opts.monitor)
        XCTAssertEqual(opts.interval, 2.0, accuracy: 0.0001)
        XCTAssertTrue(opts.sample)
        XCTAssertTrue(opts.spindump)
        XCTAssertTrue(opts.full)
        XCTAssertEqual(opts.sampleDuration, 11)
        XCTAssertEqual(opts.sampleIntervalMs, 2)
        XCTAssertEqual(opts.spindumpDuration, 12)
        XCTAssertEqual(opts.spindumpIntervalMs, 15)
        XCTAssertEqual(opts.spindumpSystemDuration, 13)
        XCTAssertEqual(opts.spindumpSystemIntervalMs, 20)
    }

    func testParseArgsLegacyDurationShortcut() {
        let opts = CLI.parseArgs(["--duration", "7"])
        XCTAssertEqual(opts.sampleDuration, 7)
        XCTAssertEqual(opts.spindumpDuration, 7)
        XCTAssertEqual(opts.spindumpSystemDuration, 7)
    }

    func testParseArgsSpindumpImpliesSample() {
        let opts = CLI.parseArgs(["--spindump"])
        XCTAssertTrue(opts.sample)
        XCTAssertTrue(opts.spindump)
        XCTAssertFalse(opts.full)
    }

    func testParseArgsForegroundOnly() {
        let opts = CLI.parseArgs(["--foreground-only"])
        XCTAssertTrue(opts.processType == .foreground)
    }

    func testParseArgsDurationThenSpecificOverride() {
        let opts = CLI.parseArgs([
            "--duration", "7",
            "--sample-duration", "11",
        ])
        XCTAssertEqual(opts.sampleDuration, 11)
        XCTAssertEqual(opts.spindumpDuration, 7)
        XCTAssertEqual(opts.spindumpSystemDuration, 7)
    }

    func testDiagnosisLevelMapping() {
        let none = CLI.parseArgs([])
        XCTAssertFalse(none.diagnosisEnabled)
        XCTAssertEqual(none.diagLevel, 0)

        let sampleOnly = CLI.parseArgs(["--sample"])
        XCTAssertTrue(sampleOnly.diagnosisEnabled)
        XCTAssertEqual(sampleOnly.diagLevel, 1)

        let spindump = CLI.parseArgs(["--spindump"])
        XCTAssertTrue(spindump.diagnosisEnabled)
        XCTAssertEqual(spindump.diagLevel, 2)

        let full = CLI.parseArgs(["--full"])
        XCTAssertTrue(full.diagnosisEnabled)
        XCTAssertEqual(full.diagLevel, 3)
    }

    func testDiffMonitorStatesTransitionsAndPIDReuse() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let previous: [pid_t: ProcessSnapshot] = [
            100: snapshot(name: "Alpha", bundleID: "com.test.alpha", responding: true),
            101: snapshot(name: "Beta", bundleID: "com.test.beta", responding: false),
            102: snapshot(name: "Gamma", bundleID: "com.test.gamma", responding: false),
            103: snapshot(name: "Old", bundleID: "com.test.old", responding: true),
        ]
        let current: [pid_t: ProcessSnapshot] = [
            100: snapshot(name: "Alpha", bundleID: "com.test.alpha", responding: false), // hung
            101: snapshot(name: "Beta", bundleID: "com.test.beta", responding: true), // recovered
            103: snapshot(name: "New", bundleID: "com.test.new", responding: false), // pid reuse
            104: snapshot(name: "Delta", bundleID: "com.test.delta", responding: false), // new and hung
            105: snapshot(name: "Epsilon", bundleID: "com.test.epsilon", responding: true), // new and healthy
        ]

        let events = MonitorEngine.diffStates(previous: previous, current: current, now: now)
        let signatures = Set(events.map { "\($0.eventType.rawValue)|\($0.pid)|\($0.name)|\($0.bundleID)" })

        XCTAssertEqual(events.count, 6)
        XCTAssertEqual(signatures.count, 6)
        XCTAssertTrue(signatures.contains("became_hung|100|Alpha|com.test.alpha"))
        XCTAssertTrue(signatures.contains("became_responsive|101|Beta|com.test.beta"))
        XCTAssertTrue(signatures.contains("process_exited|102|Gamma|com.test.gamma"))
        XCTAssertTrue(signatures.contains("process_exited|103|Old|com.test.old"))
        XCTAssertTrue(signatures.contains("became_hung|103|New|com.test.new"))
        XCTAssertTrue(signatures.contains("became_hung|104|Delta|com.test.delta"))
    }

    func testDiffMonitorStatesIgnoresNewResponsiveProcess() {
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let events = MonitorEngine.diffStates(
            previous: [:],
            current: [200: snapshot(name: "Healthy", bundleID: "com.test.healthy", responding: true)],
            now: now
        )
        XCTAssertTrue(events.isEmpty)
    }

    func testJSONRendererMonitorMetaOutput() {
        let output = captureStdout {
            JSONRenderer.renderMonitorMeta(type: "monitor_start",
                                           interval: 3.0,
                                           pushAvailable: true)
        }
        XCTAssertTrue(output.contains("\"event\":\"monitor_start\""))
        XCTAssertTrue(output.contains("\"interval\":3.0"))
        XCTAssertTrue(output.contains("\"push_available\":true"))
    }

    func testJSONRendererMonitorEventWithNullBundleID() {
        let event = MonitorEvent(timestamp: Date(timeIntervalSince1970: 1_700_000_200),
                                 eventType: .becameHung,
                                 pid: 321,
                                 name: "FrozenApp",
                                 bundleID: "-")
        let output = captureStdout {
            JSONRenderer.renderMonitorEvent(event)
        }
        XCTAssertTrue(output.contains("\"event\":\"became_hung\""))
        XCTAssertTrue(output.contains("\"pid\":321"))
        XCTAssertTrue(output.contains("\"bundle_id\":null"))
    }

    func testTableRendererMonitorMetaStartAndStop() {
        let wasEnabled = C.enabled
        C.enabled = false
        defer { C.enabled = wasEnabled }

        let startOutput = captureStdout {
            TableRenderer.renderMonitorMeta(type: "monitor_start",
                                            interval: 3.0,
                                            pushActive: false,
                                            hungCount: 0)
        }
        XCTAssertTrue(startOutput.contains("Monitor mode"))
        XCTAssertTrue(startOutput.contains("(poll-only, interval 3.0s)"))

        let stopOutput = captureStdout {
            TableRenderer.renderMonitorMeta(type: "monitor_stop",
                                            interval: 3.0,
                                            pushActive: false,
                                            hungCount: 2)
        }
        XCTAssertTrue(stopOutput.contains("Monitor stopped. 2 hung event(s) detected."))
    }

    func testTableRendererMonitorMetaStartPushPoll() {
        let wasEnabled = C.enabled
        C.enabled = false
        defer { C.enabled = wasEnabled }

        let output = captureStdout {
            TableRenderer.renderMonitorMeta(type: "monitor_start",
                                            interval: 2.0,
                                            pushActive: true,
                                            hungCount: 0)
        }
        XCTAssertTrue(output.contains("Monitor mode"))
        XCTAssertTrue(output.contains("(push+poll, interval 2.0s)"))
    }

    func testTableRendererDiagnosisRendersToolAndError() {
        let wasEnabled = C.enabled
        C.enabled = false
        defer { C.enabled = wasEnabled }

        let results = [
            DiagToolResult(pid: 42,
                           name: "BadApp",
                           tool: "sample",
                           outputPath: nil,
                           elapsed: 0.1,
                           error: "sample failed")
        ]
        let output = captureStdout {
            TableRenderer.renderDiagnosis(results)
        }
        XCTAssertTrue(output.contains("DIAG"))
        XCTAssertTrue(output.contains("BadApp (PID 42):"))
        XCTAssertTrue(output.contains("sample"))
        XCTAssertTrue(output.contains("sample failed"))
    }

    // MARK: - diffStates additional coverage

    func testDiffMonitorStatesRespondingProcessExitsSilently() {
        let now = Date(timeIntervalSince1970: 1_700_000_300)
        let previous: [pid_t: ProcessSnapshot] = [
            200: snapshot(name: "Healthy", bundleID: "com.test.healthy", responding: true),
        ]
        let events = MonitorEngine.diffStates(previous: previous, current: [:], now: now)
        // Responding process disappearing should NOT generate any event (noise suppression).
        XCTAssertTrue(events.isEmpty, "Expected no events for responding process exit, got: \(events)")
    }

    func testDiffMonitorStatesPIDReuseNewResponding() {
        let now = Date(timeIntervalSince1970: 1_700_000_400)
        let previous: [pid_t: ProcessSnapshot] = [
            300: snapshot(name: "OldApp", bundleID: "com.test.old", responding: true),
        ]
        let current: [pid_t: ProcessSnapshot] = [
            300: snapshot(name: "NewApp", bundleID: "com.test.new", responding: true),
        ]
        let events = MonitorEngine.diffStates(previous: previous, current: current, now: now)
        let signatures = Set(events.map { "\($0.eventType.rawValue)|\($0.pid)|\($0.name)" })
        // PID reuse: EXIT for old process, but no becameHung since new is responding.
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(signatures.contains("process_exited|300|OldApp"))
    }

    func testDiffMonitorStatesNoChange() {
        let now = Date(timeIntervalSince1970: 1_700_000_500)
        let state: [pid_t: ProcessSnapshot] = [
            400: snapshot(name: "Stable", bundleID: "com.test.stable", responding: true),
            401: snapshot(name: "StillHung", bundleID: "com.test.hung", responding: false),
        ]
        let events = MonitorEngine.diffStates(previous: state, current: state, now: now)
        XCTAssertTrue(events.isEmpty, "Expected no events when state is unchanged, got: \(events)")
    }

    func testDiffMonitorStatesHungProcessExitReportsExit() {
        let now = Date(timeIntervalSince1970: 1_700_000_600)
        let previous: [pid_t: ProcessSnapshot] = [
            500: snapshot(name: "HungApp", bundleID: "com.test.hung", responding: false),
        ]
        let events = MonitorEngine.diffStates(previous: previous, current: [:], now: now)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].eventType.rawValue, "process_exited")
        XCTAssertEqual(events[0].pid, 500)
        XCTAssertEqual(events[0].name, "HungApp")
    }

    // MARK: - parseArgs basic flags coverage

    func testParseArgsJsonFlag() {
        let opts = CLI.parseArgs(["--json"])
        XCTAssertTrue(opts.json)
    }

    func testParseArgsNoColorFlag() {
        let opts = CLI.parseArgs(["--no-color"])
        XCTAssertTrue(opts.noColor)
    }

    func testParseArgsListFlag() {
        let opts = CLI.parseArgs(["--list"])
        XCTAssertTrue(opts.list)
        let short = CLI.parseArgs(["-l"])
        XCTAssertTrue(short.list)
    }

    func testParseArgsTypeFlag() {
        let def = CLI.parseArgs([])
        XCTAssertEqual(def.processType, .lsapp)

        let fg = CLI.parseArgs(["--type", "foreground"])
        XCTAssertEqual(fg.processType, .foreground)
        XCTAssertTrue(fg.processType == .foreground)

        let gui = CLI.parseArgs(["--type", "gui"])
        XCTAssertEqual(gui.processType, .gui)

        let bg = CLI.parseArgs(["--type", "background"])
        XCTAssertEqual(bg.processType, .background)

        let fgOnly = CLI.parseArgs(["--foreground-only"])
        XCTAssertEqual(fgOnly.processType, .foreground)
        XCTAssertTrue(fgOnly.processType == .foreground)
    }

    func testParseArgsShaFlag() {
        let opts = CLI.parseArgs(["--sha"])
        XCTAssertTrue(opts.showSHA)
    }

    func testParseArgsMonitorFlag() {
        let opts = CLI.parseArgs(["--monitor"])
        XCTAssertTrue(opts.monitor)
        let short = CLI.parseArgs(["-m"])
        XCTAssertTrue(short.monitor)
    }

    func testParseArgsPidAndNameFilters() {
        let opts = CLI.parseArgs(["--pid", "123", "--pid", "456", "--name", "Foo", "--name", "Bar"])
        XCTAssertEqual(opts.pids, [123, 456])
        XCTAssertEqual(opts.names, ["Foo", "Bar"])
    }

    func testParseArgsVersionAndHelpFlags() {
        let v = CLI.parseArgs(["--version"])
        XCTAssertTrue(v.version)
        let vShort = CLI.parseArgs(["-v"])
        XCTAssertTrue(vShort.version)
        let h = CLI.parseArgs(["--help"])
        XCTAssertTrue(h.help)
        let hShort = CLI.parseArgs(["-h"])
        XCTAssertTrue(hShort.help)
    }

    func testParseArgsOutdir() {
        let opts = CLI.parseArgs(["--outdir", "/tmp/test_dir"])
        XCTAssertEqual(opts.outdir, "/tmp/test_dir")
    }

    func testParseArgsIntervalValue() {
        let opts = CLI.parseArgs(["--interval", "5.5"])
        XCTAssertEqual(opts.interval, 5.5, accuracy: 0.0001)
    }

    // MARK: - Renderer version/build_time fields

    func testJSONRendererMonitorMetaIncludesVersionAndBuildTime() {
        let output = captureStdout {
            JSONRenderer.renderMonitorMeta(type: "monitor_start",
                                           interval: 3.0,
                                           pushAvailable: true)
        }
        XCTAssertTrue(output.contains("\"version\":"), "Missing version in monitor meta JSON")
        XCTAssertTrue(output.contains("\"build_time\":"), "Missing build_time in monitor meta JSON")
    }

    func testTableRendererMonitorMetaStartIncludesVersion() {
        let wasEnabled = C.enabled
        C.enabled = false
        defer { C.enabled = wasEnabled }

        let output = captureStdout {
            TableRenderer.renderMonitorMeta(type: "monitor_start",
                                            interval: 3.0,
                                            pushActive: true,
                                            hungCount: 0)
        }
        XCTAssertTrue(output.contains("hung_detect"), "Missing hung_detect in start banner")
        XCTAssertTrue(output.contains("(built "), "Missing build time in start banner")
        XCTAssertTrue(output.contains("started "),
                      "Missing 'started' keyword. Output bytes: \(Array(output.utf8))")
    }
}
