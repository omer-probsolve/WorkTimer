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
        XCTAssertEqual(everyone.map { total($0.map) }, [0, 3600, 1800])
        XCTAssertEqual(metrics.weekHeatmaps(project: "p", now: now).map(\.worker), Worker.agents)
        XCTAssertEqual(metrics.weekHeatmaps(project: "other", now: now).map { total($0.map) }, [0, 0])
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
