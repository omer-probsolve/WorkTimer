import Foundation

/// Every user-visible number, time and date format. Add new ones here rather
/// than creating formatters elsewhere.
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

    /// "3.4×"
    static func multiplier(_ value: Double) -> String {
        String(format: "%.1f×", value)
    }

    /// "9:41" or "9:41 AM", per the user's locale.
    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    /// "Today", "Yesterday", or "Mon 12 Oct".
    static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return dayFormatter.string(from: date)
    }

    /// "Mon"
    static func weekday(_ date: Date) -> String {
        weekdayFormatter.string(from: date)
    }

    /// "Mon 12" — timeline labels for a week.
    static func weekdayAndDay(_ date: Date) -> String {
        weekdayDayFormatter.string(from: date)
    }

    /// "9" or "9 AM" — timeline labels for a day. The day's closing midnight
    /// reads "24" on a 24-hour clock.
    static func hour(_ date: Date, closingMidnight: Bool = false) -> String {
        closingMidnight && uses24HourClock ? "24" : hourFormatter.string(from: date)
    }

    /// "11 – 17 Oct"
    static func dateRange(_ interval: DateInterval) -> String {
        rangeFormatter.string(from: interval.start, to: interval.end.addingTimeInterval(-1))
    }

    /// "2026-10-13" — locale-independent, for file names and CSV.
    static func isoDay(_ date: Date) -> String {
        isoDayFormatter.string(from: date)
    }

    /// "2026-10-13 09:41:00" — locale-independent, for CSV.
    static func isoDateTime(_ date: Date) -> String {
        isoDateTimeFormatter.string(from: date)
    }

    // MARK: - Formatters

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let dayFormatter = template("EEE d MMM")
    private static let weekdayFormatter = template("EEE")
    private static let weekdayDayFormatter = template("EEE d")
    private static let hourFormatter = template("j")

    private static let uses24HourClock =
        !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("a")

    private static let rangeFormatter: DateIntervalFormatter = {
        let f = DateIntervalFormatter()
        f.dateTemplate = "MMMd"
        return f
    }()

    private static let isoDayFormatter = posix("yyyy-MM-dd")
    private static let isoDateTimeFormatter = posix("yyyy-MM-dd HH:mm:ss")

    private static func template(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    private static func posix(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
}
