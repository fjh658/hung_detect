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
                        responding: responding)
    }

    func testSymbolResolutionChainPrefersFrameworkLookup() {
        var frameworkCalls = 0
        var dynamicCalls = 0
        let frameworkPtr = UnsafeMutableRawPointer(bitPattern: 0x1234)

        let chain = SymbolResolutionChain(
            frameworkLookup: { frameworkPaths, names in
                frameworkCalls += 1
                XCTAssertEqual(frameworkPaths, ["/Framework"])
                XCTAssertEqual(names, ["TargetSym"])
                return frameworkPtr
            },
            dynamicLookup: { _, _ in
                dynamicCalls += 1
                return UnsafeMutableRawPointer(bitPattern: 0x5678)
            }
        )

        let result = chain.resolve(frameworkPaths: ["/Framework"],
                                   handles: [],
                                   names: ["TargetSym"])
        XCTAssertEqual(result, frameworkPtr)
        XCTAssertEqual(frameworkCalls, 1)
        XCTAssertEqual(dynamicCalls, 0)
    }

    func testSymbolResolutionChainFallsBackToDynamicLookup() {
        var frameworkCalls = 0
        var dynamicCalls = 0
        let fallbackPtr = UnsafeMutableRawPointer(bitPattern: 0x5678)
        let handle = UnsafeMutableRawPointer(bitPattern: 0x1111)!

        let chain = SymbolResolutionChain(
            frameworkLookup: { _, _ in
                frameworkCalls += 1
                return nil
            },
            dynamicLookup: { handles, names in
                dynamicCalls += 1
                XCTAssertEqual(handles, [handle])
                XCTAssertEqual(names, ["TargetSym", "_TargetSym"])
                return fallbackPtr
            }
        )

        let result = chain.resolve(frameworkPaths: ["/Framework"],
                                   handles: [handle],
                                   names: ["TargetSym", "_TargetSym"])
        XCTAssertEqual(result, fallbackPtr)
        XCTAssertEqual(frameworkCalls, 1)
        XCTAssertEqual(dynamicCalls, 1)
    }

    func testSymbolResolutionChainReturnsNilWhenBothMiss() {
        var frameworkCalls = 0
        var dynamicCalls = 0
        let handle = UnsafeMutableRawPointer(bitPattern: 0x2222)!

        let chain = SymbolResolutionChain(
            frameworkLookup: { _, _ in
                frameworkCalls += 1
                return nil
            },
            dynamicLookup: { _, _ in
                dynamicCalls += 1
                return nil
            }
        )

        let result = chain.resolve(frameworkPaths: ["/Framework"],
                                   handles: [handle],
                                   names: ["MissingSym"])
        XCTAssertNil(result)
        XCTAssertEqual(frameworkCalls, 1)
        XCTAssertEqual(dynamicCalls, 1)
    }

    func testRuntimeSymbolCatalogCGSPathsAndSymbols() {
        XCTAssertEqual(RuntimeSymbolCatalog.cgsFrameworkPaths, [
            "/System/Library/PrivateFrameworks/SkyLight.framework",
            "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A",
        ])
        XCTAssertEqual(RuntimeSymbolCatalog.cgsLibraryPaths, [
            "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        ])
        XCTAssertEqual(RuntimeSymbolCatalog.cgsMainConnectionSymbols, ["CGSMainConnectionID", "_CGSMainConnectionID"])
        XCTAssertEqual(RuntimeSymbolCatalog.cgsEventIsUnresponsiveSymbols, ["CGSEventIsAppUnresponsive", "_CGSEventIsAppUnresponsive"])
        XCTAssertEqual(RuntimeSymbolCatalog.cgsRegisterNotifySymbols, ["CGSRegisterNotifyProc", "_CGSRegisterNotifyProc"])
        XCTAssertEqual(RuntimeSymbolCatalog.cgsRemoveNotifySymbols, ["CGSRemoveNotifyProc", "_CGSRemoveNotifyProc"])
    }

    func testRuntimeSymbolCatalogLaunchServicesPathsAndSymbols() {
        XCTAssertEqual(RuntimeSymbolCatalog.launchServicesFrameworkPaths, [
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework",
            "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework",
            "/System/Library/PrivateFrameworks/LaunchServices.framework",
            "/System/Library/PrivateFrameworks/LaunchServices.framework/Versions/A",
        ])
        XCTAssertEqual(RuntimeSymbolCatalog.launchServicesLibraryPaths, [
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Versions/A/LaunchServices",
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/LaunchServices",
            "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/LaunchServices",
            "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/LaunchServices",
            "/System/Library/PrivateFrameworks/LaunchServices.framework/Versions/A/LaunchServices",
            "/System/Library/PrivateFrameworks/LaunchServices.framework/LaunchServices",
        ])
        XCTAssertEqual(RuntimeSymbolCatalog.lsasnCreateSymbols, ["LSASNCreateWithPid", "_LSASNCreateWithPid", "__LSASNCreateWithPid"])
        XCTAssertEqual(RuntimeSymbolCatalog.lsasnExtractSymbols, ["LSASNExtractHighAndLowParts", "_LSASNExtractHighAndLowParts", "__LSASNExtractHighAndLowParts"])
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
        XCTAssertFalse(opts.foregroundOnly)
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
        XCTAssertTrue(opts.foregroundOnly)
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
            102: snapshot(name: "Gamma", bundleID: "com.test.gamma", responding: true),
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
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let output = captureStdout {
            JSONRenderer.renderMonitorMeta(type: "monitor_start",
                                           interval: 3.0,
                                           pushAvailable: true,
                                           formatter: formatter)
        }
        XCTAssertTrue(output.contains("\"event\":\"monitor_start\""))
        XCTAssertTrue(output.contains("\"interval\":3.0"))
        XCTAssertTrue(output.contains("\"push_available\":true"))
    }

    func testJSONRendererMonitorEventWithNullBundleID() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let event = MonitorEvent(timestamp: Date(timeIntervalSince1970: 1_700_000_200),
                                 eventType: .becameHung,
                                 pid: 321,
                                 name: "FrozenApp",
                                 bundleID: "-")
        let output = captureStdout {
            JSONRenderer.renderMonitorEvent(event, formatter: formatter)
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
}
