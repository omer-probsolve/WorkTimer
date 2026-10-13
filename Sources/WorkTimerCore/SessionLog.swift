import Foundation

/// Your work log: finished sessions plus the running one, and the rules for
/// changing them. A plain value — the app wraps it to publish changes and save.
package struct SessionLog: Codable, Equatable {
    package private(set) var sessions: [WorkSession] = []
    package private(set) var active: ActiveSession?

    package var isRunning: Bool { active != nil }

    package init() {}

    package struct StopResult {
        package let session: WorkSession
        /// `false` when the session was too short to keep.
        package let logged: Bool
    }

    package enum EditError: LocalizedError, Equatable {
        case endNotAfterStart
        case inFuture
        case overlaps(start: Date, end: Date)

        package var errorDescription: String? {
            switch self {
            case .endNotAfterStart: return "End must be after start."
            case .inFuture: return "Times can't be in the future."
            case let .overlaps(start, end): return "Overlaps the session \(Format.time(start)) – \(Format.time(end))."
            }
        }
    }

    // MARK: - Changes

    package mutating func start(at date: Date, automatic: Bool) {
        guard active == nil else { return }
        active = ActiveSession(start: date, startedAutomatically: automatic, lastSeen: date)
    }

    /// Ends the running session at `date`. Sessions shorter than `minimumDuration`
    /// are dropped rather than logged.
    @discardableResult
    package mutating func stop(at date: Date, reason: WorkSession.EndReason, minimumDuration: TimeInterval = 0) -> StopResult? {
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
        return StopResult(session: session, logged: keep)
    }

    /// Throws away the running session without logging it.
    package mutating func discardActive() {
        active = nil
    }

    package mutating func delete(_ id: UUID) {
        sessions.removeAll { $0.id == id }
    }

    /// Undoes an idle clock-out: the session resumes as if it never stopped, so the
    /// idle gap counts as work. Any session started since is folded into it.
    package mutating func reopen(_ id: UUID, now: Date) {
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
                lastSeen: now
            )
        }
    }

    /// Checks new times for a finished session (`id`), or for the running session
    /// when `id` is nil (its `end` is now).
    package func validateEdit(id: UUID?, start: Date, end: Date, now: Date) -> EditError? {
        guard end > start else { return .endNotAfterStart }
        guard end <= now.addingTimeInterval(1) else { return .inFuture }
        var others = sessions.filter { $0.id != id }.map(\.span)
        if id != nil, let active { others.append(Span(start: active.start, end: now)) }
        if let clash = others.first(where: { start < $0.end && $0.start < end }) {
            return .overlaps(start: clash.start, end: clash.end)
        }
        return nil
    }

    /// Returns false when the change isn't valid.
    @discardableResult
    package mutating func update(_ id: UUID, start: Date, end: Date, now: Date) -> Bool {
        guard let index = sessions.firstIndex(where: { $0.id == id }),
              validateEdit(id: id, start: start, end: end, now: now) == nil else { return false }
        sessions[index].start = start
        sessions[index].end = end
        sessions.sort { $0.start < $1.start }
        return true
    }

    /// Moves the running session's start, e.g. after forgetting to clock in.
    @discardableResult
    package mutating func updateActiveStart(_ start: Date, now: Date) -> Bool {
        guard active != nil, validateEdit(id: nil, start: start, end: now, now: now) == nil else { return false }
        active?.start = start
        return true
    }

    /// Records that the app was still running, so a crash loses little time.
    package mutating func markSeen(_ now: Date) {
        active?.lastSeen = now
    }

    /// Closes a session left running by a crash at the moment it was last seen.
    package mutating func recoverUnfinishedSession() {
        guard let active else { return }
        stop(at: active.lastSeen, reason: .recovered, minimumDuration: 60)
    }

    // MARK: - Queries

    /// Your logged time: finished sessions plus the running one up to `now`.
    package func spans(now: Date) -> [Span] {
        var spans = sessions.map(\.span)
        if let active, now > active.start { spans.append(Span(start: active.start, end: now)) }
        return spans
    }

    package func total(in interval: DateInterval, now: Date) -> TimeInterval {
        spans(now: now).unionLength(in: interval)
    }

    package func sessions(in interval: DateInterval) -> [WorkSession] {
        sessions.filter { $0.overlap(with: interval) > 0 }
    }

    /// Sessions as CSV, in local time. With an `interval`, only sessions that
    /// overlap it are included, clipped to its bounds so the durations add up to
    /// the time worked inside it.
    package func csv(in interval: DateInterval? = nil) -> String {
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

    // MARK: - File

    /// Reads `sessions.json`. An unreadable file is moved aside rather than
    /// overwritten, and an empty log is returned.
    package static func load(from url: URL) -> SessionLog {
        guard let data = try? Data(contentsOf: url) else { return SessionLog() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var log = try? decoder.decode(SessionLog.self, from: data) else {
            let backup = url.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            return SessionLog()
        }
        log.sessions.sort { $0.start < $1.start }
        return log
    }

    package func save(to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
