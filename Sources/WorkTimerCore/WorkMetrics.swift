import Foundation

/// The numbers the app shows, computed from your sessions and the agents' work.
///
/// * **You** — your clocked sessions (keyboard and mouse activity).
/// * **Claude / Codex** — wall-clock time with at least one session working;
///   parallel sessions count once.
/// * **Agent-hours** — the same, but every session counts: three sessions over
///   the same hour make three hours.
/// * **Session** — time when you *or* an agent were working.
package struct WorkMetrics {
    package let log: SessionLog
    package let segments: [AgentSegment]
    /// Agent days before this aren't shown unless you logged time that day too.
    package let trackingStart: Date

    package init(log: SessionLog, segments: [AgentSegment], trackingStart: Date) {
        self.log = log
        self.segments = segments
        self.trackingStart = trackingStart
    }

    package struct RunningAgent: Identifiable {
        package var id: String { sessionID }
        package let worker: Worker
        package let sessionID: String
        package let project: String
        package let source: String
        package let since: Date
    }

    package struct ProjectTotal: Identifiable {
        package var id: String { name }
        package let name: String
        package let wallClock: TimeInterval
        package let byWorker: [Worker: TimeInterval]
        /// The agent working on it right now, if any.
        package let runningWorker: Worker?
    }

    /// One row of the session table: a clocked session of yours, or one agent
    /// session's work within the range.
    package struct Entry: Identifiable {
        package enum Kind {
            case you(WorkSession)
            case youRunning(ActiveSession)
            case agent(sessionID: String, project: String, source: String)
        }

        package let id: String
        package let worker: Worker
        package let kind: Kind
        package let span: Span
        /// Time actually worked inside `span`.
        package let worked: TimeInterval
        package let running: Bool

        package var project: String? {
            if case let .agent(_, project, _) = kind { return project }
            return nil
        }

        package var source: String {
            switch kind {
            case let .you(session): return session.startedAutomatically ? "Auto" : "Manual"
            case let .youRunning(active): return active.startedAutomatically ? "Auto" : "Manual"
            case let .agent(_, _, source): return source
            }
        }
    }

    /// The earliest moment agent transcripts can matter.
    package static func agentCutoff(log: SessionLog, trackingStart: Date) -> Date {
        let first = log.sessions.first.map { Calendar.current.startOfDay(for: $0.start) } ?? trackingStart
        return min(first, trackingStart)
    }

    // MARK: - Spans

    /// Agent segments on days that count, with live ones running until now.
    package func agentSegments(now: Date) -> [AgentSegment] {
        let calendar = Calendar.current
        let yourDays = Set(log.sessions.map { calendar.startOfDay(for: $0.start) })
            .union(log.active.map { [calendar.startOfDay(for: $0.start)] } ?? [])
        return segments.compactMap { segment in
            let day = calendar.startOfDay(for: segment.span.start)
            guard day >= trackingStart || yourDays.contains(day) else { return nil }
            var segment = segment
            if isLive(segment, now: now) { segment.span.end = now }
            return segment
        }
    }

    private func isLive(_ segment: AgentSegment, now: Date) -> Bool {
        segment.open && now.timeIntervalSince(segment.span.end) <= AgentLogState.maxSilence
    }

    package func yourSpans(now: Date) -> [Span] {
        log.spans(now: now)
    }

    package func spans(for worker: Worker, now: Date, segments: [AgentSegment]? = nil) -> [Span] {
        if worker == .you { return yourSpans(now: now) }
        return (segments ?? agentSegments(now: now)).filter { $0.worker == worker }.map(\.span)
    }

    package func sessionSpans(now: Date) -> [Span] {
        (yourSpans(now: now) + agentSegments(now: now).map(\.span)).merged()
    }

    // MARK: - Totals

    package func total(_ worker: Worker, in interval: DateInterval, now: Date) -> TimeInterval {
        worker == .you ? log.total(in: interval, now: now) : spans(for: worker, now: now).unionLength(in: interval)
    }

    package func agentHours(_ worker: Worker, in interval: DateInterval, now: Date) -> TimeInterval {
        spans(for: worker, now: now).summedLength(in: interval)
    }

    package func sessionTotal(in interval: DateInterval, now: Date) -> TimeInterval {
        sessionSpans(now: now).unionLength(in: interval)
    }

    // MARK: - Multipliers

    /// Everything logged: your time plus every agent session's time.
    package func totalWork(in interval: DateInterval, now: Date) -> TimeInterval {
        total(.you, in: interval, now: now) + Worker.agents.reduce(0) { $0 + agentHours($1, in: interval, now: now) }
    }

    /// Work logged per hour of your own time: 1h of you plus 3 agent-hours is 4×.
    /// nil when you logged no time.
    package func leverage(in interval: DateInterval, now: Date) -> Double? {
        let yours = total(.you, in: interval, now: now)
        guard yours >= 60 else { return nil }
        return totalWork(in: interval, now: now) / yours
    }

    /// How many of an agent's sessions ran at once, on average, while at least one
    /// did: one session is 1×, three in parallel 3×. nil when it didn't run.
    package func parallelism(_ worker: Worker, in interval: DateInterval, now: Date) -> Double? {
        let active = total(worker, in: interval, now: now)
        guard worker != .you, active >= 60 else { return nil }
        return max(1, agentHours(worker, in: interval, now: now) / active)
    }

    /// How many workers were active over time — you count as one, every agent
    /// session as one more — as steps with a constant count.
    package func concurrency(in interval: DateInterval, now: Date) -> [(span: Span, count: Int)] {
        let spans = yourSpans(now: now).merged() + agentSegments(now: now).map(\.span)
        var events: [(time: Date, delta: Int)] = []
        for span in spans.compactMap({ $0.clipped(to: interval) }) {
            events.append((span.start, 1))
            events.append((span.end, -1))
        }
        events.sort { $0.time == $1.time ? $0.delta < $1.delta : $0.time < $1.time }
        var steps: [(span: Span, count: Int)] = []
        var count = 0
        var last: Date?
        for event in events {
            if let last, event.time > last, count > 0 {
                steps.append((Span(start: last, end: event.time), count))
            }
            count += event.delta
            last = event.time
        }
        return steps
    }

    // MARK: - Right now

    package func running(now: Date) -> [RunningAgent] {
        let live = segments.filter { isLive($0, now: now) }
        guard !live.isEmpty else { return [] }
        let bySession = Dictionary(grouping: segments, by: \.sessionID)
        return live.map { segment in
            // Measured from the start of this stretch of work, matching the
            // dashboard's row for the session.
            let spans = (bySession[segment.sessionID] ?? []).map(\.span) + [Span(start: segment.span.start, end: now)]
            let since = spans.merged(bridging: Self.rowBridge).last?.start ?? segment.span.start
            return RunningAgent(
                worker: segment.worker, sessionID: segment.sessionID, project: segment.project,
                source: segment.source, since: since
            )
        }
        .sorted { $0.since > $1.since }
    }

    /// Breaks shorter than this stay inside one row of the session table.
    package static let rowBridge: TimeInterval = 30 * 60

    package var isWorking: Bool { isWorking(now: Date()) }

    /// Who is working right now: you while your timer runs, an agent while any
    /// of its sessions is mid-turn.
    package func liveWorkers(now: Date) -> Set<Worker> {
        var workers = Set(running(now: now).map(\.worker))
        if log.isRunning { workers.insert(.you) }
        return workers
    }

    package func isWorking(now: Date) -> Bool {
        log.isRunning || segments.contains { isLive($0, now: now) }
    }

    /// When the current stretch of work began, if you or an agent is working now.
    package func currentSessionStart(now: Date) -> Date? {
        guard isWorking(now: now) else { return nil }
        return sessionSpans(now: now).last { $0.end >= now.addingTimeInterval(-1) }?.start
    }

    // MARK: - Breakdown

    package func projects(in interval: DateInterval, now: Date) -> [ProjectTotal] {
        let segments = agentSegments(now: now)
        var live: [String: Worker] = [:]
        if interval.contains(now) {
            for segment in segments where isLiveNow(segment, now: now) { live[segment.project] = segment.worker }
        }
        return Dictionary(grouping: segments, by: \.project).compactMap { name, segments in
            let wall = segments.map(\.span).unionLength(in: interval)
            guard wall > 0 else { return nil }
            var byWorker: [Worker: TimeInterval] = [:]
            for worker in Worker.agents {
                byWorker[worker] = segments.filter { $0.worker == worker }.map(\.span).unionLength(in: interval)
            }
            return ProjectTotal(name: name, wallClock: wall, byWorker: byWorker, runningWorker: live[name])
        }
        .sorted { $0.wallClock > $1.wallClock }
    }

    /// After `agentSegments(now:)` has stretched live segments to `now`.
    private func isLiveNow(_ segment: AgentSegment, now: Date) -> Bool {
        segment.open && segment.span.end >= now
    }

    /// Your sessions and agent sessions overlapping `interval`, newest first.
    package func entries(in interval: DateInterval, now: Date) -> [Entry] {
        var entries: [Entry] = []
        for session in log.sessions(in: interval) {
            let span = session.span
            entries.append(Entry(
                id: session.id.uuidString, worker: .you, kind: .you(session),
                span: span, worked: [span].unionLength(in: interval), running: false
            ))
        }
        if let active = log.active, now > active.start {
            let span = Span(start: active.start, end: now)
            if span.clipped(to: interval) != nil {
                entries.append(Entry(
                    id: active.id.uuidString, worker: .you, kind: .youRunning(active),
                    span: span, worked: [span].unionLength(in: interval), running: true
                ))
            }
        }

        // An agent session becomes one row per stretch of work; short breaks
        // stay inside a row.
        let segments = agentSegments(now: now).filter { $0.span.clipped(to: interval) != nil }
        for (sessionID, group) in Dictionary(grouping: segments, by: \.sessionID) {
            guard let first = group.first else { continue }
            for block in group.map(\.span).merged(bridging: Self.rowBridge) {
                let inside = group.map(\.span).filter { $0.start >= block.start && $0.end <= block.end }
                entries.append(Entry(
                    id: "\(sessionID)-\(block.start.timeIntervalSince1970)", worker: first.worker,
                    kind: .agent(sessionID: sessionID, project: first.project, source: first.source),
                    span: block, worked: inside.unionLength(in: interval),
                    running: group.contains { isLiveNow($0, now: now) && $0.span.end == block.end }
                ))
            }
        }
        return entries.sorted { $0.span.start > $1.span.start }
    }
}

/// Tooltips explaining the numbers, shared by every view that shows them.
package enum Explain {
    package static let leverage = "Work logged per hour of your time: you plus every agent session, divided by your time"

    package static func agent(_ worker: Worker) -> String {
        "Agent-hours (parallel sessions each count) · sessions running at once, on average, while \(worker.name) worked"
    }
}

extension WorkMetrics {
    /// An agent card's second line: agent-hours, then the parallelism multiplier.
    /// Compact: "× 1:53 · 1.2×"; regular: "1:53 agent-hours · 1.2×".
    package func agentSummary(_ worker: Worker, in interval: DateInterval, now: Date, compact: Bool) -> String? {
        guard worker != .you else { return nil }
        let clock = Format.clock(agentHours(worker, in: interval, now: now), seconds: false)
        let hours = compact ? "× \(clock)" : "\(clock) agent-hours"
        guard let parallel = parallelism(worker, in: interval, now: now) else { return hours }
        return "\(hours) · \(Format.multiplier(parallel))"
    }
}
