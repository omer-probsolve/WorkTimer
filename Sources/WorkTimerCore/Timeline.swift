import Foundation

/// A stretch of time, start inclusive, end exclusive.
package struct Span: Codable, Equatable {
    package var start: Date
    package var end: Date

    package init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    package var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    package func clipped(to interval: DateInterval) -> Span? {
        let lower = max(start, interval.start)
        let upper = min(end, interval.end)
        return upper > lower ? Span(start: lower, end: upper) : nil
    }
}

extension Array where Element == Span {
    /// Sorted, non-overlapping spans covering the same time. Spans less than
    /// `bridging` apart are joined, gap included.
    package func merged(bridging gap: TimeInterval = 0) -> [Span] {
        var result: [Span] = []
        for span in sorted(by: { $0.start < $1.start }) where span.end > span.start {
            if let last = result.last, span.start.timeIntervalSince(last.end) <= gap {
                result[result.count - 1].end = Swift.max(last.end, span.end)
            } else {
                result.append(span)
            }
        }
        return result
    }

    /// Wall-clock time covered inside `interval`: overlaps count once.
    package func unionLength(in interval: DateInterval) -> TimeInterval {
        compactMap { $0.clipped(to: interval) }.merged().reduce(0) { $0 + $1.duration }
    }

    /// Plain sum inside `interval`: overlaps count once per span.
    package func summedLength(in interval: DateInterval) -> TimeInterval {
        compactMap { $0.clipped(to: interval) }.reduce(0) { $0 + $1.duration }
    }
}

extension DateInterval {
    /// The calendar day, week, hour… containing `date`, in the user's calendar.
    package static func of(_ component: Calendar.Component, containing date: Date) -> DateInterval {
        Calendar.current.dateInterval(of: component, for: date)!
    }
}

/// Time covered in each hour of the week, added up over every week:
/// `seconds[weekday][hour]`, where weekday 0 is Sunday and hour 0 is midnight.
package struct WeekHeatmap: Equatable {
    package static let levels = 4

    package var seconds = Array(repeating: Array(repeating: TimeInterval(0), count: 24), count: 7)

    package init() {}

    package var peak: TimeInterval { seconds.joined().max() ?? 0 }

    /// 0 for an empty hour, otherwise 1…`levels` relative to the busiest hour.
    package func level(weekday: Int, hour: Int) -> Int {
        let value = seconds[weekday][hour]
        let peak = peak
        guard value > 0, peak > 0 else { return 0 }
        return Swift.min(Self.levels, Swift.max(1, Int((value / peak * Double(Self.levels)).rounded(.up))))
    }
}

extension Array where Element == Span {
    /// When these spans fall across the week; overlaps count once.
    package func weekHeatmap(calendar: Calendar = .current) -> WeekHeatmap {
        var map = WeekHeatmap()
        for span in merged() {
            var start = span.start
            while start < span.end {
                let end = Swift.min(calendar.dateInterval(of: .hour, for: start)!.end, span.end)
                let parts = calendar.dateComponents([.weekday, .hour], from: start)
                map.seconds[parts.weekday! - 1][parts.hour!] += end.timeIntervalSince(start)
                start = end
            }
        }
        return map
    }
}
