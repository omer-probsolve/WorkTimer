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

    var span: Span { Span(start: start, end: end) }
    var duration: TimeInterval { span.duration }

    /// The part of this session that falls inside `interval`.
    func overlap(with interval: DateInterval) -> TimeInterval {
        span.clipped(to: interval)?.duration ?? 0
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
