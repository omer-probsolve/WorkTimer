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

extension Color {
    /// The empty background of lanes and heat-map cells.
    static let trackFill = Color.primary.opacity(0.06)
}

/// The time axis a chart is drawn against.
struct ChartAxis {
    let range: DateInterval
    let ticks: [(Date, String)]

    /// The empty track every lane is drawn on; later drawing is clipped to it.
    static func drawTrack(in context: inout GraphicsContext, size: CGSize) {
        let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3)
        context.fill(track, with: .color(.trackFill))
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

/// The union of a chart's track frames, so a hover line can cross every lane.
struct TrackFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .null
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = value.union(nextValue()) }
}

extension View {
    /// Reports this track's frame in the named coordinate space to `TrackFrameKey`.
    func reportsTrackFrame(in space: String) -> some View {
        background(GeometryReader { Color.clear.preference(key: TrackFrameKey.self, value: $0.frame(in: .named(space))) })
    }
}

/// A vertical line through every track at `x`, with `card` beside it — on the
/// right, or on the left when it would run past the edge.
struct HoverLine<Card: View>: View {
    let x: CGFloat
    let tracks: CGRect
    @ViewBuilder let card: Card

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.primary)
                    .frame(width: 1, height: tracks.height + 8)
                    .offset(x: x, y: tracks.minY - 4)
                card
                    .fixedSize()
                    .alignmentGuide(.leading) { card in
                        x + 12 + card.width > geometry.size.width ? -(x - 12 - card.width) : -(x + 12)
                    }
                    .alignmentGuide(.top) { _ in -(tracks.minY - 4) }
            }
        }
        .allowsHitTesting(false)
    }
}

/// The hover card: the time, what each lane was doing, and how many were working.
struct MomentCard: View {
    struct Row: Identifiable {
        let id: String
        let title: String
        let color: Color
        /// nil when the lane was idle.
        let text: String?
    }

    let title: String
    let rows: [Row]
    let workers: Int

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
            GridRow {
                Text(title).fontWeight(.semibold).gridCellColumns(2)
            }
            .padding(.bottom, 3)
            ForEach(rows) { row in
                line(row.title, value: row.text ?? "idle", dot: row.text == nil ? .trackFill : row.color)
                    .foregroundStyle(row.text == nil ? .tertiary : .primary)
            }
            Divider().padding(.vertical, 2)
            line("Workers", value: "\(workers)", dot: .secondary)
                .fontWeight(.semibold)
        }
        .font(.caption)
        .monospacedDigit()
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        )
    }

    private func line(_ title: String, value: String, dot: Color) -> some View {
        GridRow {
            HStack(spacing: 6) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(title).lineLimit(1)
            }
            Text(value).lineLimit(1).gridColumnAlignment(.trailing)
        }
    }
}

/// When work happens across the week: a row per day, Sunday first, and a
/// column per hour. Each cell has a stripe per worker, shaded by how much of
/// that worker's time falls in it.
struct WeekHeatmapView: View {
    typealias Layer = (worker: Worker, map: WeekHeatmap)

    let layers: [Layer]

    var body: some View {
        // Taller cells when there are stripes to tell apart.
        let cellHeight: CGFloat = layers.count > 1 ? 18 : 14
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            ForEach(0..<7, id: \.self) { weekday in
                GridRow {
                    Text(Format.weekdaySymbol(weekday))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .gridColumnAlignment(.leading)
                        .padding(.trailing, 4)
                    ForEach(0..<24, id: \.self) { hour in
                        Stripes(colors: layers.map {
                            Self.fill($0.map.level(weekday: weekday, hour: hour), color: $0.worker.color)
                        }, cornerRadius: 3)
                        .frame(minWidth: 8, maxWidth: .infinity, minHeight: cellHeight, maxHeight: cellHeight)
                        .help(help(weekday: weekday, hour: hour))
                    }
                }
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                ForEach(0..<24, id: \.self) { hour in
                    // Overlaid so a label wider than its cell doesn't widen the column.
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 12, maxHeight: 12)
                        .overlay(alignment: .leading) {
                            if hour % 3 == 0 {
                                Text(Format.hour(ofDay: hour))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .fixedSize()
                            }
                        }
                }
            }
        }
    }

    private func help(weekday: Int, hour: Int) -> String {
        let range = "\(Format.weekdaySymbol(weekday)) \(Format.hour(ofDay: hour)) – \(Format.hour(ofDay: (hour + 1) % 24))"
        let times = layers.map { layer in
            let time = Format.clock(layer.map.seconds[weekday][hour], seconds: false)
            return layers.count > 1 ? "\(layer.worker.name) \(time)" : time
        }
        return ([range] + times).joined(separator: " · ")
    }

    /// Empty for level 0, otherwise `color` at one of four strengths.
    static func fill(_ level: Int, color: Color) -> Color {
        level == 0 ? .clear : color.opacity([0.3, 0.5, 0.75, 1][min(level, WeekHeatmap.levels) - 1])
    }

    /// Equal horizontal bands, top to bottom, on the empty track.
    private struct Stripes: View {
        let colors: [Color]
        let cornerRadius: CGFloat

        var body: some View {
            VStack(spacing: 0) {
                ForEach(colors.indices, id: \.self) { colors[$0] }
            }
            .background(Color.trackFill)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    /// Who each stripe is, then "Less ▢▢▢▢▢ More" in the same stripes.
    struct Legend: View {
        let workers: [Worker]

        var body: some View {
            HStack(spacing: 3) {
                if workers.count > 1 {
                    ForEach(workers) { worker in
                        HStack(spacing: 4) {
                            Circle().fill(worker.color).frame(width: 6, height: 6)
                            Text(worker.name).foregroundStyle(worker.color)
                        }
                        .padding(.trailing, 6)
                    }
                }
                Text("Less").padding(.trailing, 2)
                ForEach(0...WeekHeatmap.levels, id: \.self) { level in
                    Stripes(colors: workers.map { WeekHeatmapView.fill(level, color: $0.color) }, cornerRadius: 2)
                        .frame(width: 10, height: 10)
                }
                Text("More").padding(.leading, 2)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
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
