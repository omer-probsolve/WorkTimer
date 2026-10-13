import SwiftUI
import WorkTimerCore

extension Worker {
    var color: Color {
        switch self {
        case .you: return Color(red: 0.11, green: 0.62, blue: 0.46)
        case .claude: return Color(red: 0.85, green: 0.35, blue: 0.19)
        case .codex: return Color(red: 0.50, green: 0.47, blue: 0.87)
        }
    }
}

/// The time axis a chart is drawn against.
struct ChartAxis {
    let range: DateInterval
    let ticks: [(Date, String)]

    /// The empty track every lane is drawn on; later drawing is clipped to it.
    static func drawTrack(in context: inout GraphicsContext, size: CGSize) {
        let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3)
        context.fill(track, with: .color(.primary.opacity(0.06)))
        context.clip(to: track)
    }

    func x(_ date: Date, width: CGFloat) -> CGFloat {
        CGFloat(date.timeIntervalSince(range.start) / range.duration) * width
    }

    /// The part of `day` set in Settings: `startMinute` up to and including
    /// `endMinute` (minutes after midnight).
    static func day(_ day: Date, startMinute: Int, endMinute: Int) -> ChartAxis {
        let midnight = Calendar.current.startOfDay(for: day)
        let start = midnight.addingTimeInterval(TimeInterval(startMinute * 60))
        let end = midnight.addingTimeInterval(TimeInterval((endMinute + 1) * 60))
        let hours = end.timeIntervalSince(start) / 3600
        let step: TimeInterval = (hours <= 4 ? 1 : hours <= 10 ? 2 : hours <= 16 ? 3 : 4) * 3600
        var ticks: [(Date, String)] = []
        // Labels on whole hours, starting at the first one inside the range.
        var tick = DateInterval.of(.hour, containing: start.addingTimeInterval(-1)).end
        let nextMidnight = midnight.addingTimeInterval(24 * 3600)
        while tick <= end {
            ticks.append((tick, Format.hour(tick, closingMidnight: tick == nextMidnight)))
            tick = tick.addingTimeInterval(step)
        }
        return ChartAxis(range: DateInterval(start: start, end: end), ticks: ticks)
    }

    static func week(_ interval: DateInterval) -> ChartAxis {
        let calendar = Calendar.current
        var ticks: [(Date, String)] = []
        var day = interval.start
        while day < interval.end {
            ticks.append((day, Format.weekdayAndDay(day)))
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return ChartAxis(range: interval, ticks: ticks)
    }
}

/// One horizontal track of colored blocks.
struct LaneBar: View {
    struct Layer {
        let spans: [Span]
        let color: Color

        static func session(_ spans: [Span]) -> Layer { Layer(spans: spans, color: .secondary.opacity(0.55)) }
        static func worker(_ worker: Worker, _ spans: [Span]) -> Layer { Layer(spans: spans, color: worker.color) }
    }

    let layers: [Layer]
    let axis: ChartAxis
    var height: CGFloat = 12
    /// Darker inner marks where two or more spans in a layer overlap — parallel
    /// agent sessions.
    var showOverlap = false

    var body: some View {
        Canvas { context, size in
            ChartAxis.drawTrack(in: &context, size: size)
            for layer in layers {
                for span in layer.spans.merged() {
                    guard let rect = rect(span, size: size) else { continue }
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(layer.color))
                }
                guard showOverlap else { continue }
                for span in Self.overlaps(layer.spans) {
                    guard var rect = rect(span, size: size) else { continue }
                    rect.origin.y = size.height * 0.62
                    rect.size.height = size.height * 0.38
                    context.fill(Path(rect), with: .color(.black.opacity(0.3)))
                }
            }
        }
        .frame(height: height)
    }

    private func rect(_ span: Span, size: CGSize) -> CGRect? {
        guard let clipped = span.clipped(to: axis.range) else { return nil }
        let x0 = axis.x(clipped.start, width: size.width)
        let x1 = axis.x(clipped.end, width: size.width)
        return CGRect(x: x0, y: 0, width: max(1.5, x1 - x0), height: size.height)
    }

    /// Where at least two spans run at once.
    static func overlaps(_ spans: [Span]) -> [Span] {
        var events: [(time: Date, delta: Int)] = []
        for span in spans {
            events.append((span.start, 1))
            events.append((span.end, -1))
        }
        // Ends before starts at the same instant, so touching spans don't overlap.
        events.sort { $0.time == $1.time ? $0.delta < $1.delta : $0.time < $1.time }
        var depth = 0
        var opened: Date?
        var result: [Span] = []
        for (time, delta) in events {
            depth += delta
            if depth >= 2, opened == nil {
                opened = time
            } else if depth < 2, let start = opened {
                if time > start { result.append(Span(start: start, end: time)) }
                opened = nil
            }
        }
        return result
    }
}

/// Tick labels under a lane chart.
struct AxisLabels: View {
    let axis: ChartAxis

    var body: some View {
        GeometryReader { geometry in
            ForEach(Array(axis.ticks.enumerated()), id: \.offset) { index, tick in
                let x = axis.x(tick.0, width: geometry.size.width)
                Text(tick.1)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .position(x: x, y: 6)
                    .offset(x: index == 0 ? 8 : index == axis.ticks.count - 1 ? -8 : 0)
            }
        }
        .frame(height: 12)
    }
}

/// How many workers were active over time, as a step chart scaled to the peak.
struct ConcurrencyBar: View {
    let steps: [(span: Span, count: Int)]
    let axis: ChartAxis
    var height: CGFloat = 24

    var peak: Int { steps.map(\.count).max() ?? 0 }

    var body: some View {
        let peak = max(peak, 1)
        Canvas { context, size in
            ChartAxis.drawTrack(in: &context, size: size)
            // One path, filled once: separately filled steps leave darker seams
            // where their antialiased edges meet.
            var path = Path()
            for step in steps {
                guard let clipped = step.span.clipped(to: axis.range) else { continue }
                let x0 = axis.x(clipped.start, width: size.width)
                let x1 = axis.x(clipped.end, width: size.width)
                let h = size.height * CGFloat(step.count) / CGFloat(peak)
                path.addRect(CGRect(x: x0, y: size.height - h, width: max(1, x1 - x0), height: h))
            }
            context.fill(path, with: .color(.secondary.opacity(0.5)))
        }
        .frame(height: height)
    }
}

/// A small "3.4×" pill.
struct MultiplierBadge: View {
    let value: Double?

    var body: some View {
        Text(value.map(Format.multiplier) ?? "—")
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.cardFill)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
            )
    }
}
