import XCTest
@testable import WorkTimerCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

private func stamp(_ seconds: TimeInterval) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: at(seconds))
}

private func parse(_ worker: Worker, _ lines: [String]) -> AgentLogState {
    var state = AgentLogState(worker: worker)
    for line in lines { state.consume(line: Data(line.utf8)) }
    return state
}

private func claude(_ type: String, _ seconds: TimeInterval, _ extra: String = "") -> String {
    #"{"type":"\#(type)","timestamp":"\#(stamp(seconds))","sessionId":"s1","cwd":"/tmp/project","entrypoint":"cli"\#(extra)}"#
}

private func codex(_ seconds: TimeInterval, _ payload: String) -> String {
    #"{"timestamp":"\#(stamp(seconds))","type":"event_msg","payload":\#(payload)}"#
}

final class TimelineTests: XCTestCase {
    func testUnionCountsOverlapOnceAndSumCountsEachSpan() {
        let spans = [Span(start: at(0), end: at(3600)), Span(start: at(1800), end: at(5400))]
        let day = DateInterval(start: at(-1000), end: at(100_000))
        XCTAssertEqual(spans.unionLength(in: day), 5400)
        XCTAssertEqual(spans.summedLength(in: day), 7200)
    }

    func testMergingBridgesShortGaps() {
        let spans = [Span(start: at(0), end: at(60)), Span(start: at(120), end: at(180))]
        XCTAssertEqual(spans.merged().count, 2)
        XCTAssertEqual(spans.merged(bridging: 60), [Span(start: at(0), end: at(180))])
    }

    func testWeekHeatmapSplitsSpansAtHoursAndCountsOverlapOnce() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // Sunday 2026-10-11, 9:30 to 11:15, plus an overlapping span.
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 9, minute: 30))!
        let spans = [
            Span(start: start, end: start.addingTimeInterval(105 * 60)),
            Span(start: start, end: start.addingTimeInterval(10 * 60)),
        ]
        let map = spans.weekHeatmap(calendar: calendar)
        XCTAssertEqual(map.seconds[0][9], 30 * 60)
        XCTAssertEqual(map.seconds[0][10], 60 * 60)
        XCTAssertEqual(map.seconds[0][11], 15 * 60)
        XCTAssertEqual(map.seconds.joined().reduce(0, +), 105 * 60)
        XCTAssertEqual(map.level(weekday: 0, hour: 10), WeekHeatmap.levels)
        XCTAssertEqual(map.level(weekday: 0, hour: 11), 1)
        XCTAssertEqual(map.level(weekday: 1, hour: 10), 0)
    }

    func testTimestampParsing() {
        XCTAssertEqual(LogScan.date("2026-10-12T11:10:28.250Z")?.timeIntervalSince1970 ?? 0, 1_791_803_428.25, accuracy: 0.001)
        XCTAssertNil(LogScan.date("not a date"))
    }
}

final class AgentLogTests: XCTestCase {
    func testClaudeTurnRunsUntilTheStopRecord() {
        let state = parse(.claude, [
            claude("user", 0, #","message":{"role":"user","content":"Fix the bug"}"#),
            claude("assistant", 10, #","message":{"stop_reason":"tool_use"}"#),
            claude("user", 20, #","message":{"content":[{"type":"tool_result"}]}"#),
            claude("assistant", 30, #","message":{"stop_reason":"end_turn"}"#),
            claude("system", 90, #","subtype":"stop_hook_summary""#),
        ])
        XCTAssertEqual(state.allSegments, [Span(start: at(0), end: at(90))])
        XCTAssertFalse(state.isLive)
        XCTAssertEqual(state.source, "Terminal")
        XCTAssertEqual(state.cwd, "/tmp/project")
    }

    func testLongSilenceInsideATurnIsNotCounted() {
        let state = parse(.claude, [
            claude("user", 0, #","message":{"content":"Go"}"#),
            claude("assistant", 60, #","message":{"stop_reason":"tool_use"}"#),
            claude("assistant", 60 + 600, #","message":{"stop_reason":"tool_use"}"#),
            claude("assistant", 60 + 660, #","message":{"stop_reason":"tool_use"}"#),
        ])
        XCTAssertEqual(state.allSegments, [Span(start: at(0), end: at(60)), Span(start: at(660), end: at(720))])
        XCTAssertTrue(state.isLive)
    }

    private func toolUse(_ id: String, _ name: String = "Bash") -> String {
        #","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)"}]}"#
    }

    private func toolResult(_ id: String, source: String = "config", extra: String = "") -> String {
        #","permissionDecision":{"decision":"accept","source":"\#(source)"}\#(extra),"message":{"content":[{"type":"tool_result","tool_use_id":"\#(id)"}]}"#
    }

    func testSilenceWhileAToolRunsWithoutAskingIsCounted() {
        let state = parse(.claude, [
            claude("user", 0, #","permissionMode":"default","message":{"content":"Run the tests"}"#),
            claude("assistant", 60, toolUse("t1")),
            claude("user", 60 + 1200, toolResult("t1")),
        ])
        XCTAssertEqual(state.allSegments, [Span(start: at(0), end: at(1260))])
    }

    func testSilenceBeforeAToolYouApprovedIsNotCounted() {
        let state = parse(.claude, [
            claude("user", 0, #","message":{"content":"Deploy"}"#),
            claude("assistant", 60, toolUse("t1")),
            claude("user", 60 + 1200, toolResult("t1", source: "user_temporary")),
        ])
        XCTAssertEqual(state.segments, [Span(start: at(0), end: at(60))])
    }

    func testToolsThatWaitOnYourAnswerAreNotCounted() {
        let state = parse(.claude, [
            claude("user", 0, #","permissionMode":"auto","message":{"content":"Plan it"}"#),
            claude("assistant", 60, toolUse("q1", "AskUserQuestion")),
        ])
        XCTAssertFalse(state.notWaitingOnYou)
    }

    func testARunningToolInAutoModeIsLiveThroughSilence() {
        let state = parse(.claude, [
            claude("user", 0, #","permissionMode":"auto","message":{"content":"Run the tests"}"#),
            claude("assistant", 60, toolUse("t1")),
        ])
        XCTAssertTrue(state.notWaitingOnYou)
        let segment = AgentSegment(worker: .claude, sessionID: "s1", project: "p", source: "Terminal",
                                   span: Span(start: at(0), end: at(60)), open: true, notWaitingOnYou: true)
        XCTAssertEqual(segment.maxSilence, AgentLogState.maxToolRun)
    }

    func testABackgroundTaskThatWakesTheAgentCountsTheWait() {
        let state = parse(.claude, [
            claude("user", 0, #","message":{"content":"Run the suite"}"#),
            claude("assistant", 10, toolUse("t1")),
            claude("user", 20, toolResult("t1", extra: #","toolUseResult":{"backgroundTaskId":"b1"}"#)),
            claude("assistant", 30, #","message":{"stop_reason":"end_turn"}"#),
            claude("system", 40, #","subtype":"stop_hook_summary""#),
            claude("user", 40 + 900, #","message":{"content":"<task-notification>\n<task-id>b1</task-id>\n</task-notification>"}"#),
            claude("assistant", 40 + 960, #","message":{"stop_reason":"end_turn"}"#),
            claude("system", 40 + 970, #","subtype":"stop_hook_summary""#),
        ])
        XCTAssertEqual(state.allSegments, [Span(start: at(0), end: at(1010))])
    }

    func testABackgroundTaskThatNeverReportsBackDoesNotCount() {
        let state = parse(.claude, [
            claude("user", 0, #","message":{"content":"Start the dev server"}"#),
            claude("assistant", 10, toolUse("t1")),
            claude("user", 20, toolResult("t1", extra: #","toolUseResult":{"backgroundTaskId":"b1"}"#)),
            claude("system", 40, #","subtype":"stop_hook_summary""#),
            claude("user", 2000, #","message":{"content":"Now fix the header"}"#),
            claude("system", 2100, #","subtype":"stop_hook_summary""#),
        ])
        XCTAssertEqual(state.allSegments, [Span(start: at(0), end: at(40)), Span(start: at(2000), end: at(2100))])
    }

    private static let backgroundResult = #","toolUseResult":{"backgroundTaskId":"b1"},"message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"Command running in background with ID: b1. Output is being written to: /tmp/s1/tasks/b1.output. You will be notified when it completes."}]}"#

    private static let serverSession = [
        claude("user", 0, #","message":{"content":"Start the server and run the tests"}"#),
        claude("assistant", 10, #","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1","name":"Bash"}]}"#),
        claude("user", 20, backgroundResult),
        claude("system", 40, #","subtype":"stop_hook_summary""#),
    ]

    func testBackgroundTasksRecordWhereTheirOutputGoes() {
        let state = parse(.claude, Self.serverSession)
        XCTAssertEqual(state.backgroundTasks["b1"],
                       BackgroundTask(id: "b1", outputFile: "/tmp/s1/tasks/b1.output", movedByTimeout: false))
    }

    func testOnlyBusyTasksOrOnesTheAgentMeantToWaitForKeepItWorking() {
        let started = BackgroundTask(id: "b1", outputFile: nil, movedByTimeout: false)
        let timedOut = BackgroundTask(id: "b2", outputFile: nil, movedByTimeout: true)
        XCTAssertTrue(started.keepsAgentWorking(.busy))
        XCTAssertFalse(started.keepsAgentWorking(.idle))
        XCTAssertTrue(timedOut.keepsAgentWorking(.idle))
        XCTAssertFalse(timedOut.keepsAgentWorking(.gone))
    }

    func testABusyBackgroundTaskKeepsTheSessionLive() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appendingPathComponent(".claude/projects/p")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try (Self.serverSession.joined(separator: "\n") + "\n")
            .write(to: folder.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
        let scanner = TranscriptScanner(home: home.path, cacheURL: home.appendingPathComponent("cache.json"),
                                        cutoff: .distantPast)
        scanner.scan()

        XCTAssertEqual(scanner.pendingTasks(now: at(60)).map(\.id), ["b1"])
        XCTAssertTrue(scanner.pendingTasks(now: at(40 + AgentLogState.maxToolRun + 1)).isEmpty)
        XCTAssertEqual(scanner.segments(taskActivity: ["b1": .idle]).last?.open, false)
        let busy = try XCTUnwrap(scanner.segments(taskActivity: ["b1": .busy]).last)
        XCTAssertTrue(busy.open && busy.waitingOnTask)
        XCTAssertEqual(busy.maxSilence, AgentLogState.maxToolRun)
    }

    func testATaskIsBusyOnlyOnceItKeepsWorking() {
        var tracker = TaskActivityTracker()
        // A server's startup burst: two checks of work, then quiet.
        XCTAssertEqual(tracker.update("server", worked: true, at: at(0)), .idle)
        XCTAssertEqual(tracker.update("server", worked: true, at: at(10)), .idle)
        XCTAssertEqual(tracker.update("server", worked: false, at: at(20)), .idle)
        XCTAssertEqual(tracker.update("server", worked: false, at: at(600)), .idle)
        // A test run: busy once it has kept going, through a quiet stretch, until it ends.
        for second in stride(from: 0.0, to: 30, by: 10) {
            XCTAssertEqual(tracker.update("tests", worked: true, at: at(second)), .idle)
        }
        XCTAssertEqual(tracker.update("tests", worked: true, at: at(30)), .busy)
        XCTAssertEqual(tracker.update("tests", worked: false, at: at(30 + 110)), .busy)
        XCTAssertEqual(tracker.update("tests", worked: false, at: at(30 + 130)), .idle)
        XCTAssertEqual(tracker.update("tests", worked: nil, at: at(200)), .gone)
    }

    func testCodexThatNeverAsksCountsLongSilences() {
        let state = parse(.codex, [
            codex(0, #"{"type":"thread_settings_applied","approval_policy":"never"}"#),
            codex(5, #"{"type":"task_started"}"#),
            codex(5 + 1200, #"{"type":"item_completed"}"#),
            codex(5 + 1300, #"{"type":"task_complete"}"#),
        ])
        XCTAssertEqual(state.allSegments, [Span(start: at(5), end: at(1305))])
    }

    func testSubagentLinesAndSlashCommandsAreIgnored() {
        let state = parse(.claude, [
            claude("user", 0, #","isSidechain":true,"message":{"content":"sub"}"#),
            claude("user", 10, #","message":{"content":"<command-name>/clear</command-name>"}"#),
        ])
        XCTAssertTrue(state.allSegments.isEmpty)
        XCTAssertFalse(state.turnOpen)
    }

    func testCodexTurn() {
        let state = parse(.codex, [
            #"{"timestamp":"\#(stamp(0))","type":"session_meta","payload":{"id":"c1","cwd":"/tmp/repo","originator":"Codex Desktop","source":"vscode"}}"#,
            codex(5, #"{"type":"task_started"}"#),
            codex(100, #"{"type":"item_completed"}"#),
            codex(200, #"{"type":"task_complete"}"#),
        ])
        XCTAssertEqual(state.allSegments, [Span(start: at(5), end: at(200))])
        XCTAssertEqual(state.source, "Codex app")
        XCTAssertEqual(state.sessionID, "c1")
    }

    func testCodexSubagentSessionsAreIgnored() {
        let state = parse(.codex, [
            #"{"timestamp":"\#(stamp(0))","type":"session_meta","payload":{"id":"g1","source":{"subagent":{"other":"guardian"}}}}"#,
            codex(5, #"{"type":"task_started"}"#),
            codex(200, #"{"type":"task_complete"}"#),
        ])
        XCTAssertTrue(state.ignored)
        XCTAssertTrue(state.allSegments.isEmpty)
    }
}

final class SessionLogTests: XCTestCase {
    func testShortSessionsAreDropped() {
        var log = SessionLog()
        log.start(at: at(0), automatic: true)
        XCTAssertEqual(log.stop(at: at(30), reason: .idle, minimumDuration: 60)?.logged, false)
        XCTAssertTrue(log.sessions.isEmpty)
    }

    func testEditsCannotOverlapAnotherSession() {
        var log = SessionLog()
        log.start(at: at(0), automatic: false)
        log.stop(at: at(3600), reason: .manual)
        log.start(at: at(7200), automatic: false)
        log.stop(at: at(9000), reason: .manual)
        let second = log.sessions[1].id
        XCTAssertEqual(log.validateEdit(id: second, start: at(3000), end: at(9000), now: at(10_000)),
                       .overlaps(start: at(0), end: at(3600)))
        XCTAssertFalse(log.update(second, start: at(3000), end: at(9000), now: at(10_000)))
        XCTAssertTrue(log.update(second, start: at(4000), end: at(9000), now: at(10_000)))
    }
}

final class WorkMetricsTests: XCTestCase {
    private func segment(_ session: String, _ start: TimeInterval, _ end: TimeInterval, _ worker: Worker = .claude) -> AgentSegment {
        AgentSegment(worker: worker, sessionID: session, project: "p", source: "Terminal",
                     span: Span(start: at(start), end: at(end)), open: false)
    }

    func testMultipliers() {
        var log = SessionLog()
        log.start(at: at(0), automatic: false)
        log.stop(at: at(3600), reason: .manual)
        // Three Claude sessions in parallel for the same hour; one Codex session.
        let metrics = WorkMetrics(
            log: log,
            segments: [segment("a", 0, 3600), segment("b", 0, 3600), segment("c", 0, 3600), segment("x", 0, 1800, .codex)],
            trackingStart: at(-86_400)
        )
        let range = DateInterval(start: at(-100), end: at(10_000))
        let now = at(10_000)
        XCTAssertEqual(metrics.total(.claude, in: range, now: now), 3600)
        XCTAssertEqual(metrics.agentHours(.claude, in: range, now: now), 3 * 3600)
        XCTAssertEqual(metrics.parallelism(.claude, in: range, now: now), 3)
        XCTAssertEqual(metrics.parallelism(.codex, in: range, now: now), 1)
        // (1h you + 3h Claude + 0.5h Codex) / 1h you
        XCTAssertEqual(metrics.leverage(in: range, now: now) ?? 0, 4.5, accuracy: 0.001)
        XCTAssertEqual(metrics.concurrency(in: range, now: now).map(\.count).max(), 5)
    }

    func testWeekHeatmapsHaveOneMapPerWorkerWithParallelSessionsCountedOnce() {
        let metrics = WorkMetrics(
            log: SessionLog(),
            segments: [segment("a", 0, 3600), segment("b", 0, 3600), segment("x", 0, 1800, .codex)],
            trackingStart: at(-86_400)
        )
        let now = at(10_000)
        let total = { (map: WeekHeatmap) in map.seconds.joined().reduce(0, +) }
        let everyone = metrics.weekHeatmaps(now: now)
        XCTAssertEqual(everyone.map(\.worker), Worker.allCases)
        XCTAssertEqual(everyone.map { total($0.map) }, [0, 3600, 1800, 0])
        XCTAssertEqual(metrics.weekHeatmaps(project: "p", now: now).map(\.worker), Worker.agents)
        XCTAssertEqual(metrics.weekHeatmaps(project: "other", now: now).map { total($0.map) }, [0, 0, 0])
        XCTAssertEqual(metrics.weekHeatmaps(worker: .codex, now: now).map(\.worker), [.codex])
    }

    func testMomentMatchesConcurrencyAndMeasuresFromTheRowStart() {
        var log = SessionLog()
        log.start(at: at(0), automatic: false)
        log.stop(at: at(3600), reason: .manual)
        // Session "a" pauses for 10 minutes — inside one table row.
        let metrics = WorkMetrics(
            log: log,
            segments: [segment("a", 0, 1200), segment("a", 1800, 3600), segment("b", 600, 3600), segment("x", 0, 1800, .codex)],
            trackingStart: at(-86_400)
        )
        let now = at(10_000)
        let moment = metrics.moment(at: at(2400), now: now)
        let step = metrics.concurrency(in: DateInterval(start: at(0), end: now), now: now)
            .first { $0.span.start <= at(2400) && at(2400) < $0.span.end }
        XCTAssertEqual(moment.workers, step?.count)
        XCTAssertEqual(moment.workers, 3)
        XCTAssertEqual(moment.text(for: .you), "0:40")
        XCTAssertEqual(moment.text(for: .claude), "p · 2 sessions")
        XCTAssertNil(moment.text(for: .codex))
        XCTAssertEqual(metrics.moment(at: at(1500), now: now).text(for: .codex), "p · 0:25")
        XCTAssertEqual(metrics.moment(at: at(2400), now: now).text(forProject: "p"), "Claude · 2 sessions")
        XCTAssertEqual(moment.sessionText, "0:40")
        let idle = metrics.moment(at: at(5000), now: now)
        XCTAssertEqual(idle.workers, 0)
        XCTAssertNil(idle.sessionText)
    }

    func testLeverageNeedsYourTime() {
        let metrics = WorkMetrics(log: SessionLog(), segments: [segment("a", 0, 3600)], trackingStart: at(-86_400))
        XCTAssertNil(metrics.leverage(in: DateInterval(start: at(-100), end: at(10_000)), now: at(10_000)))
    }
}

final class AIWorldTests: XCTestCase {
    private func turn(_ events: [AIWorldTurn.Event], waits: [AIWorldTurn.Wait] = [], finished: TimeInterval? = 600) -> AIWorldTurn {
        AIWorldTurn(id: "t1", chatID: "c1", engine: "claude", project: "Flowboard", started: at(0),
                    finished: finished.map(at), events: events, waits: waits)
    }

    private func activity(_ seconds: TimeInterval) -> AIWorldTurn.Event { .init(at: at(seconds), kind: .activity) }

    func testATurnCountsFromStartToFinish() {
        let segments = turn([activity(120), activity(400)]).segments()
        XCTAssertEqual(segments.map(\.span), [Span(start: at(0), end: at(600))])
        XCTAssertEqual(segments.first?.worker, .aiWorld)
        XCTAssertEqual(segments.first?.sessionID, "c1")
        XCTAssertEqual(segments.first?.source, "Claude")
        XCTAssertEqual(segments.first?.project, "Flowboard")
        XCTAssertEqual(segments.first?.open, false)
    }

    func testApprovalWaitsAreNotCounted() {
        let segments = turn([activity(100), activity(900)], waits: [.init(start: at(200), end: at(800))], finished: 1000).segments()
        XCTAssertEqual(segments.map(\.span), [Span(start: at(0), end: at(200)), Span(start: at(800), end: at(1000))])
    }

    func testLongSilenceIsCutUnlessAToolIsRunning() {
        let silent = turn([activity(100), activity(1000)], finished: 1100).segments()
        XCTAssertEqual(silent.map(\.span), [Span(start: at(0), end: at(100)), Span(start: at(1000), end: at(1100))])

        let tool = turn([.init(at: at(100), kind: .toolStarted, toolCall: "x"),
                         .init(at: at(1000), kind: .toolFinished, toolCall: "x")], finished: 1100).segments()
        XCTAssertEqual(tool.map(\.span), [Span(start: at(0), end: at(1100))])
    }

    func testARunningTurnIsOpenUnlessWaitingOnYou() {
        let running = turn([activity(100)], finished: nil).segments()
        XCTAssertEqual(running.map(\.span), [Span(start: at(0), end: at(100))])
        XCTAssertEqual(running.last?.open, true)

        let waiting = turn([activity(100)], waits: [.init(start: at(150), end: nil)], finished: nil).segments()
        XCTAssertEqual(waiting.map(\.span), [Span(start: at(0), end: at(150))])
        XCTAssertEqual(waiting.last?.open, false)
    }

    func testParallelTurnsAddAgentHoursButCountOnceAsWallClock() {
        let segments = ["a", "b"].flatMap { id in
            AIWorldTurn(id: id, chatID: id, engine: "codex", project: nil, started: at(0), finished: at(600),
                        events: [activity(300)]).segments()
        }
        let metrics = WorkMetrics(log: SessionLog(), segments: segments, trackingStart: at(-86_400))
        let day = DateInterval(start: at(-100), end: at(10_000))
        XCTAssertEqual(metrics.total(.aiWorld, in: day, now: at(10_000)), 600)
        XCTAssertEqual(metrics.agentHours(.aiWorld, in: day, now: at(10_000)), 1200)
        XCTAssertEqual(segments.first?.project, "AI World")
    }

    func testDecodesTheEndpointAnswer() {
        let json = #"""
        [{"result":{"now":1800001000.5,"turns":[{"id":"t1","chat":null,"engine":"codex","project":null,
          "started":1800000000,"finished":null,
          "events":[[1800000010,"tool_started","call1"],[1800000020,"agent_status",null]],
          "waits":[[1800000030,null]]}]}}]
        """#
        let result = AIWorldScanner.decode(Data(json.utf8))
        XCTAssertEqual(result?.now, at(1000.5))
        let turn = result?.turns.first
        XCTAssertEqual(turn?.events, [.init(at: at(10), kind: .toolStarted, toolCall: "call1"), .init(at: at(20), kind: .activity)])
        XCTAssertEqual(turn?.waits, [.init(start: at(30), end: nil)])
        XCTAssertNil(turn?.finished)
        XCTAssertNil(turn?.chatID)
    }
}
