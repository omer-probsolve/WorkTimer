import Combine
import Foundation

/// Combines your own sessions with the agents' work into the numbers the UI
/// shows.
///
/// * **You** — your clocked sessions (keyboard and mouse activity).
/// * **Claude / Codex** — wall-clock time with at least one session working;
///   parallel sessions count once.
/// * **Agent-hours** — the same, but every session counts: three sessions over
///   the same hour make three hours.
/// * **Session** — time when you *or* an agent were working.
final class WorkLog: ObservableObject {
    let store: SessionStore
    let agents: AgentMonitor

    struct RunningAgent: Identifiable {
        var id: String { sessionID }
        let worker: Worker
        let sessionID: String
        let project: String
        let source: String
        let since: Date
    }

    struct ProjectTotal: Identifiable {
        var id: String { name }
        let name: String
        let wallClock: TimeInterval
        let byWorker: [Worker: TimeInterval]
        /// The agent working on it right now, if any.
        let runningWorker: Worker?
    }

    /// One row of the session table: a clocked session of yours, or one agent
    /// session's work within the range.
    struct Entry: Identifiable {
        enum Kind {
            case you(WorkSession)
            case youRunning(ActiveSession)
            case agent(sessionID: String, project: String, source: String)
        }

        let id: String
        let worker: Worker
        let kind: Kind
        let span: Span
        /// Time actually worked inside `span`.
        let worked: TimeInterval
        let running: Bool

        var project: String? {
            if case let .agent(_, project, _) = kind { return project }
            return nil
        }

        var source: String {
            switch kind {
            case let .you(session): return session.startedAutomatically ? "Auto" : "Manual"
            case let .youRunning(active): return active.startedAutomatically ? "Auto" : "Manual"
            case let .agent(_, _, source): return source
            }
        }
    }

    /// Agent days before this aren't shown unless you logged time that day too.
    private let trackingStart: Date
    private var cancellables = Set<AnyCancellable>()

    init(store: SessionStore, agents: AgentMonitor, trackingStart: Date) {
        self.store = store
        self.agents = agents
        self.trackingStart = trackingStart
        Publishers.Merge(store.objectWillChange, agents.objectWillChange)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// The earliest moment agent transcripts can matter.
    static func agentCutoff(store: SessionStore, trackingStart: Date) -> Date {
        let first = store.sessions.first.map { Calendar.current.startOfDay(for: $0.start) } ?? trackingStart
        return min(first, trackingStart)
    }

    // MARK: - Spans

    /// Agent segments on days that count, with live ones running until now.
    func agentSegments(now: Date) -> [AgentSegment] {
        let calendar = Calendar.current
        let yourDays = Set(store.sessions.map { calendar.startOfDay(for: $0.start) })
            .union(store.active.map { [calendar.startOfDay(for: $0.start)] } ?? [])
        return agents.segments.compactMap { segment in
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

    func yourSpans(now: Date) -> [Span] {
        store.spans(now: now)
    }

    func spans(for worker: Worker, now: Date, segments: [AgentSegment]? = nil) -> [Span] {
        if worker == .you { return yourSpans(now: now) }
        return (segments ?? agentSegments(now: now)).filter { $0.worker == worker }.map(\.span)
    }

    func sessionSpans(now: Date) -> [Span] {
        (yourSpans(now: now) + agentSegments(now: now).map(\.span)).merged()
    }

    // MARK: - Totals

    func total(_ worker: Worker, in interval: DateInterval, now: Date) -> TimeInterval {
        worker == .you ? store.total(in: interval, now: now) : spans(for: worker, now: now).unionLength(in: interval)
    }

    func agentHours(_ worker: Worker, in interval: DateInterval, now: Date) -> TimeInterval {
        spans(for: worker, now: now).summedLength(in: interval)
    }

    func sessionTotal(in interval: DateInterval, now: Date) -> TimeInterval {
        sessionSpans(now: now).unionLength(in: interval)
    }

    // MARK: - Multipliers

    /// Everything logged: your time plus every agent session's time.
    func totalWork(in interval: DateInterval, now: Date) -> TimeInterval {
        total(.you, in: interval, now: now) + Worker.agents.reduce(0) { $0 + agentHours($1, in: interval, now: now) }
    }

    /// Work logged per hour of your own time: 1h of you plus 3 agent-hours is 4×.
    /// nil when you logged no time.
    func leverage(in interval: DateInterval, now: Date) -> Double? {
        let yours = total(.you, in: interval, now: now)
        guard yours >= 60 else { return nil }
        return totalWork(in: interval, now: now) / yours
    }

    /// How many of an agent's sessions ran at once, on average, while at least one
    /// did: one session is 1×, three in parallel 3×. nil when it didn't run.
    func parallelism(_ worker: Worker, in interval: DateInterval, now: Date) -> Double? {
        let active = total(worker, in: interval, now: now)
        guard worker != .you, active >= 60 else { return nil }
        return max(1, agentHours(worker, in: interval, now: now) / active)
    }

    /// How many workers were active over time — you count as one, every agent
    /// session as one more — as steps with a constant count.
    func concurrency(in interval: DateInterval, now: Date) -> [(span: Span, count: Int)] {
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

    func running(now: Date) -> [RunningAgent] {
        let live = agents.segments.filter { isLive($0, now: now) }
        guard !live.isEmpty else { return [] }
        let bySession = Dictionary(grouping: agents.segments, by: \.sessionID)
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
    static let rowBridge: TimeInterval = 30 * 60

    var isWorking: Bool { isWorking(now: Date()) }

    /// Who is working right now: you while your timer runs, an agent while any
    /// of its sessions is mid-turn.
    func liveWorkers(now: Date) -> Set<Worker> {
        var workers = Set(running(now: now).map(\.worker))
        if store.isRunning { workers.insert(.you) }
        return workers
    }

    func isWorking(now: Date) -> Bool {
        store.isRunning || agents.segments.contains { isLive($0, now: now) }
    }

    /// When the current stretch of work began, if you or an agent is working now.
    func currentSessionStart(now: Date) -> Date? {
        guard isWorking(now: now) else { return nil }
        return sessionSpans(now: now).last { $0.end >= now.addingTimeInterval(-1) }?.start
    }

    // MARK: - Breakdown

    func projects(in interval: DateInterval, now: Date) -> [ProjectTotal] {
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
    func entries(in interval: DateInterval, now: Date) -> [Entry] {
        var entries: [Entry] = []
        for session in store.sessions(in: interval) {
            let span = session.span
            entries.append(Entry(
                id: session.id.uuidString, worker: .you, kind: .you(session),
                span: span, worked: [span].unionLength(in: interval), running: false
            ))
        }
        if let active = store.active, now > active.start {
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
