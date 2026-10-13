import Foundation

/// Owns the work log and the running session, persisted as JSON in
/// ~/Library/Application Support/WorkTimer/sessions.json.
final class SessionStore: ObservableObject {
    struct StopResult {
        let session: WorkSession
        /// `false` when the session was too short to keep.
        let logged: Bool
    }

    @Published private(set) var sessions: [WorkSession] = []
    @Published private(set) var active: ActiveSession?

    var isRunning: Bool { active != nil }

    private let fileURL: URL
    private var lastHeartbeatSave = Date.distantPast

    private struct Snapshot: Codable {
        var sessions: [WorkSession]
        var active: ActiveSession?
    }

    init() {
        let directory = AppPaths.dataDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("sessions.json")
        load()
        recoverUnfinishedSession()
    }

    var dataFileURL: URL { fileURL }

    // MARK: - Mutations

    func start(at date: Date, automatic: Bool) {
        guard active == nil else { return }
        active = ActiveSession(start: date, startedAutomatically: automatic, lastSeen: date)
        save()
    }

    /// Ends the running session at `date`. Sessions shorter than `minimumDuration`
    /// are dropped rather than logged.
    @discardableResult
    func stop(at date: Date, reason: WorkSession.EndReason, minimumDuration: TimeInterval = 0) -> StopResult? {
        guard let active else { return nil }
        let session = WorkSession(
            id: active.id,
            start: active.start,
            end: max(date, active.start),
            startedAutomatically: active.startedAutomatically,
            endReason: reason
        )
        self.active = nil
        let keep = session.duration >= max(minimumDuration, 1)
        if keep {
            sessions.append(session)
            sessions.sort { $0.start < $1.start }
        }
        save()
        return StopResult(session: session, logged: keep)
    }

    /// Throws away the running session without logging it.
    func discardActive() {
        guard active != nil else { return }
        active = nil
        save()
    }

    func delete(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        save()
    }

    /// Undoes an idle clock-out: the session resumes as if it never stopped, so the
    /// idle gap counts as work. Any session started since is folded into it.
    func reopen(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions.remove(at: index)
        if var current = active {
            current.start = min(current.start, session.start)
            current.startedAutomatically = current.startedAutomatically && session.startedAutomatically
            active = current
        } else {
            active = ActiveSession(
                id: session.id,
                start: session.start,
                startedAutomatically: session.startedAutomatically,
                lastSeen: Date()
            )
        }
        save()
    }

    enum EditError: LocalizedError {
        case endNotAfterStart
        case inFuture
        case overlaps(start: Date, end: Date)

        var errorDescription: String? {
            switch self {
            case .endNotAfterStart: return "End must be after start."
            case .inFuture: return "Times can't be in the future."
            case let .overlaps(start, end): return "Overlaps the session \(Format.time(start)) – \(Format.time(end))."
            }
        }
    }

    /// Checks new times for a finished session (`id`), or for the running session
    /// when `id` is nil (its `end` is now).
    func validateEdit(id: UUID?, start: Date, end: Date, now: Date = Date()) -> EditError? {
        guard end > start else { return .endNotAfterStart }
        guard end <= now.addingTimeInterval(1) else { return .inFuture }
        var others = sessions.filter { $0.id != id }.map { ($0.start, $0.end) }
        if id != nil, let active { others.append((active.start, now)) }
        if let clash = others.first(where: { start < $0.1 && $0.0 < end }) {
            return .overlaps(start: clash.0, end: clash.1)
        }
        return nil
    }

    func update(_ id: UUID, start: Date, end: Date) {
        guard let index = sessions.firstIndex(where: { $0.id == id }),
              validateEdit(id: id, start: start, end: end) == nil else { return }
        sessions[index].start = start
        sessions[index].end = end
        sessions.sort { $0.start < $1.start }
        save()
    }

    /// Moves the running session's start, e.g. after forgetting to clock in.
    func updateActiveStart(_ start: Date) {
        guard active != nil, validateEdit(id: nil, start: start, end: Date()) == nil else { return }
        active?.start = start
        save()
    }

    func heartbeat(_ now: Date) {
        guard active != nil else { return }
        active?.lastSeen = now
        if now.timeIntervalSince(lastHeartbeatSave) >= 60 {
            save()
        }
    }

    // MARK: - Queries

    /// Your logged time: finished sessions plus the running one up to `now`.
    func spans(now: Date) -> [Span] {
        var spans = sessions.map(\.span)
        if let active, now > active.start { spans.append(Span(start: active.start, end: now)) }
        return spans
    }

    func total(in interval: DateInterval, now: Date) -> TimeInterval {
        spans(now: now).unionLength(in: interval)
    }

    func sessions(in interval: DateInterval) -> [WorkSession] {
        sessions.filter { $0.overlap(with: interval) > 0 }
    }

    /// Sessions as CSV, in local time. With an `interval`, only sessions that
    /// overlap it are included, clipped to its bounds so the durations add up to
    /// the time worked inside it.
    func csv(in interval: DateInterval? = nil) -> String {
        var lines = ["date,start,end,duration_minutes,started_automatically,end_reason"]
        for session in sessions {
            var start = session.start, end = session.end
            if let interval {
                guard session.overlap(with: interval) > 0 else { continue }
                start = max(start, interval.start)
                end = min(end, interval.end)
            }
            lines.append([
                Format.isoDay(start),
                Format.isoDateTime(start),
                Format.isoDateTime(end),
                String(format: "%.1f", end.timeIntervalSince(start) / 60),
                session.startedAutomatically ? "true" : "false",
                session.endReason.rawValue,
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Persistence

    private func recoverUnfinishedSession() {
        guard let active else { return }
        stop(at: active.lastSeen, reason: .recovered, minimumDuration: 60)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(Snapshot.self, from: data) else {
            // Keep the unreadable file around rather than overwriting it.
            let backup = fileURL.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            return
        }
        sessions = snapshot.sessions.sorted { $0.start < $1.start }
        active = snapshot.active
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Snapshot(sessions: sessions, active: active)) else { return }
        try? data.write(to: fileURL, options: .atomic)
        lastHeartbeatSave = Date()
    }
}
