import Foundation

enum Format {
    /// "1:02:03", or "1:02" without seconds.
    static func clock(_ interval: TimeInterval, seconds: Bool = true) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return seconds
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", h, m)
    }

    /// "2h 05m", or "45m".
    static func duration(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval)) / 60
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? String(format: "%dh %02dm", h, m) : "\(m)m"
    }

    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return dayFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f
    }()
}

extension Format {
    /// "3.4×"
    static func multiplier(_ value: Double) -> String {
        String(format: "%.1f×", value)
    }
}
