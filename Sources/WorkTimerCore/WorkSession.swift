import Foundation

/// A finished block of work time.
package struct WorkSession: Codable, Identifiable, Equatable {
    package enum EndReason: String, Codable {
        case manual
        case idle
        case quit
        /// The app didn't shut down cleanly; the session was closed at its last heartbeat.
        case recovered
    }

    package var id = UUID()
    package var start: Date
    package var end: Date
    package var startedAutomatically: Bool
    package var endReason: EndReason

    package var span: Span { Span(start: start, end: end) }
    package var duration: TimeInterval { span.duration }

    /// The part of this session that falls inside `interval`.
    package func overlap(with interval: DateInterval) -> TimeInterval {
        span.clipped(to: interval)?.duration ?? 0
    }
}

/// The session currently being timed.
package struct ActiveSession: Codable, Equatable {
    package var id = UUID()
    package var start: Date
    package var startedAutomatically: Bool
    /// Refreshed periodically so a crash loses at most a minute of time.
    package var lastSeen: Date
}
