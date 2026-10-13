import Foundation
import WorkTimerCore

/// Publishes your `SessionLog` to the UI and keeps it saved in
/// ~/Library/Application Support/WorkTimer/sessions.json. The rules live in
/// `SessionLog`; this only applies them, publishes and saves.
final class SessionStore: ObservableObject {
    @Published private(set) var log: SessionLog

    var sessions: [WorkSession] { log.sessions }
    var active: ActiveSession? { log.active }
    var isRunning: Bool { log.isRunning }

    let dataFileURL: URL
    private var lastHeartbeatSave = Date.distantPast

    init() {
        let directory = AppPaths.dataDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        dataFileURL = directory.appendingPathComponent("sessions.json")
        var log = SessionLog.load(from: dataFileURL)
        log.recoverUnfinishedSession()
        self.log = log
        save()
    }

    // MARK: - Changes

    func start(at date: Date, automatic: Bool) {
        change { $0.start(at: date, automatic: automatic) }
    }

    @discardableResult
    func stop(at date: Date, reason: WorkSession.EndReason, minimumDuration: TimeInterval = 0) -> SessionLog.StopResult? {
        change { $0.stop(at: date, reason: reason, minimumDuration: minimumDuration) }
    }

    func discardActive() { change { $0.discardActive() } }
    func delete(_ id: UUID) { change { $0.delete(id) } }
    func reopen(_ id: UUID) { change { $0.reopen(id, now: Date()) } }
    func update(_ id: UUID, start: Date, end: Date) { change { $0.update(id, start: start, end: end, now: Date()) } }
    func updateActiveStart(_ start: Date) { change { $0.updateActiveStart(start, now: Date()) } }

    func validateEdit(id: UUID?, start: Date, end: Date, now: Date = Date()) -> SessionLog.EditError? {
        log.validateEdit(id: id, start: start, end: end, now: now)
    }

    /// Notes that the app is alive; saved at most once a minute.
    func heartbeat(_ now: Date) {
        guard log.isRunning else { return }
        log.markSeen(now)
        if now.timeIntervalSince(lastHeartbeatSave) >= 60 { save() }
    }

    // MARK: - Queries

    func spans(now: Date) -> [Span] { log.spans(now: now) }
    func total(in interval: DateInterval, now: Date) -> TimeInterval { log.total(in: interval, now: now) }
    func sessions(in interval: DateInterval) -> [WorkSession] { log.sessions(in: interval) }
    func csv(in interval: DateInterval? = nil) -> String { log.csv(in: interval) }

    // MARK: - Saving

    @discardableResult
    private func change<T>(_ body: (inout SessionLog) -> T) -> T {
        let result = body(&log)
        save()
        return result
    }

    private func save() {
        log.save(to: dataFileURL)
        lastHeartbeatSave = Date()
    }
}
