import Foundation

/// A finished block of work time.
struct WorkSession: Codable, Identifiable, Equatable {
    enum EndReason: String, Codable {
        case manual
        case idle
        case quit
        /// The app didn't shut down cleanly; the session was closed at its last heartbeat.
        case recovered
    }

    var id = UUID()
    var start: Date
    var end: Date
    var startedAutomatically: Bool
    var endReason: EndReason

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    /// The part of this session that falls inside `interval`.
    func overlap(with interval: DateInterval) -> TimeInterval {
        let lower = max(start, interval.start)
        let upper = min(end, interval.end)
        return max(0, upper.timeIntervalSince(lower))
    }
}

/// The session currently being timed.
struct ActiveSession: Codable, Equatable {
    var id = UUID()
    var start: Date
    var startedAutomatically: Bool
    /// Refreshed periodically so a crash loses at most a minute of time.
    var lastSeen: Date
}
