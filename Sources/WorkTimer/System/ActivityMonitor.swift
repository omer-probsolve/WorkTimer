import CoreGraphics
import Foundation

/// Reads the system's own input-idle counter. No Accessibility or Input
/// Monitoring permission is needed: this is a count, not the events themselves.
enum ActivityMonitor {
    /// Seconds since the last keyboard, mouse, trackpad or tablet event.
    static func secondsSinceLastInput() -> TimeInterval {
        // kCGAnyInputEventType is ~0.
        guard let anyInput = CGEventType(rawValue: UInt32.max) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    static var isScreenLocked: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (info["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}
