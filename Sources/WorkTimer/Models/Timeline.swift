import Foundation

/// A stretch of time, start inclusive, end exclusive.
struct Span: Codable, Equatable {
    var start: Date
    var end: Date

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    func clipped(to interval: DateInterval) -> Span? {
        let lower = max(start, interval.start)
        let upper = min(end, interval.end)
        return upper > lower ? Span(start: lower, end: upper) : nil
    }
}

extension Array where Element == Span {
    /// Sorted, non-overlapping spans covering the same time. Spans less than
    /// `bridging` apart are joined, gap included.
    func merged(bridging gap: TimeInterval = 0) -> [Span] {
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
    func unionLength(in interval: DateInterval) -> TimeInterval {
        compactMap { $0.clipped(to: interval) }.merged().reduce(0) { $0 + $1.duration }
    }

    /// Plain sum inside `interval`: overlaps count once per span.
    func summedLength(in interval: DateInterval) -> TimeInterval {
        compactMap { $0.clipped(to: interval) }.reduce(0) { $0 + $1.duration }
    }
}

extension DateInterval {
    /// The calendar day, week, hour… containing `date`, in the user's calendar.
    static func of(_ component: Calendar.Component, containing date: Date) -> DateInterval {
        Calendar.current.dateInterval(of: component, for: date)!
    }
}
