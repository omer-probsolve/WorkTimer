import SwiftUI

final class DashboardModel: ObservableObject {
    enum Grouping: String, CaseIterable, Identifiable {
        case workers = "Workers", projects = "Projects"
        var id: Self { self }
    }

    enum Period: String, CaseIterable, Identifiable {
        case day = "Day", week = "Week"
        var id: Self { self }
        var component: Calendar.Component { self == .day ? .day : .weekOfYear }
    }

    /// What the session table is narrowed to. Set by clicking a card or a lane.
    enum Filter: Equatable {
        case worker(Worker)
        case project(String)
    }

    @Published var grouping: Grouping = .workers {
        didSet {
            // Project lanes aren't shown in the Workers view; worker filters stay.
            if grouping == .workers, case .project = filter { filter = nil }
        }
    }
    @Published var period: Period = .day
    @Published var anchor = Date()
    /// nil shows everything — the Session card.
    @Published var filter: Filter?
    @Published var showSettings = false

    /// Picks `filter`, or clears it when it's already picked.
    func toggle(_ filter: Filter?) {
        self.filter = self.filter == filter ? nil : filter
    }

    var interval: DateInterval {
        Calendar.current.dateInterval(of: period.component, for: anchor)!
    }

    var isCurrent: Bool { interval.contains(Date()) }

    func step(_ direction: Int) {
        anchor = Calendar.current.date(byAdding: period.component, value: direction, to: anchor)!
        if anchor > Date() { anchor = Date() }
    }

    var title: String {
        switch period {
        case .day:
            return Format.day(anchor)
        case .week:
            let interval = interval
            return Self.rangeFormatter.string(from: interval.start, to: interval.end.addingTimeInterval(-1))
        }
    }

    private static let rangeFormatter: DateIntervalFormatter = {
        let f = DateIntervalFormatter()
        f.dateTemplate = "MMMd"
        return f
    }()
}

/// The detailed window: a timeline grouped by worker or project, totals, and
/// every session in the chosen day or week.
struct DashboardView: View {
    @ObservedObject var log: WorkLog
    @ObservedObject var store: SessionStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: DashboardModel

    @State private var showExport = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            TimelineView(.periodic(from: .now, by: 5)) { context in
                content(now: context.date)
            }
        }
        .frame(minWidth: 680, minHeight: 540)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Group by", selection: $model.grouping) {
                ForEach(DashboardModel.Grouping.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            Spacer()

            HStack(spacing: 4) {
                Button { model.step(-1) } label: { Image(systemName: "chevron.left") }
                Text(model.title)
                    .font(.headline)
                    .frame(minWidth: 110)
                Button { model.step(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(model.isCurrent)
                if !model.isCurrent {
                    Button("Today") { model.anchor = Date() }
                }
            }
            .buttonStyle(.borderless)

            Picker("Period", selection: $model.period) {
                ForEach(DashboardModel.Period.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            Button { showExport.toggle() } label: { Image(systemName: "square.and.arrow.up") }
                .help("Export CSV")
                .popover(isPresented: $showExport) {
                    ExportBox(store: store, onClose: { showExport = false })
                        .frame(width: 320)
                        .padding(8)
                }
            Button { model.showSettings.toggle() } label: { Image(systemName: "gearshape") }
                .help("Settings")
                .popover(isPresented: $model.showSettings) {
                    SettingsView(settings: settings, store: store)
                        .frame(width: 380, height: 520)
                }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Content

    private struct Lane: Identifiable {
        let id: String
        /// What clicking the lane filters by; nil for the Session lane.
        let filter: DashboardModel.Filter?
        let title: String
        let total: TimeInterval
        let layers: [LaneBar.Layer]
        var color: Color?
        var showOverlap = false
        /// The worker's color when someone is working on this lane right now.
        var liveColor: Color?
    }

    private func content(now: Date) -> some View {
        let interval = model.interval
        let segments = log.agentSegments(now: now)
        let axis = model.period == .day
            ? ChartAxis.day(model.anchor, startMinute: settings.timelineStartMinute, endMinute: settings.timelineEndMinute)
            : ChartAxis.week(interval)
        let live: Set<Worker> = interval.contains(now) ? log.liveWorkers(now: now) : []
        let lanes = lanes(interval: interval, now: now, segments: segments, live: live)

        return VStack(alignment: .leading, spacing: 14) {
            laneChart(lanes, axis: axis, concurrency: log.concurrency(in: interval, now: now))
            cards(interval: interval, now: now, live: live)
            table(interval: interval, now: now)
        }
        .padding(16)
    }

    private func lanes(interval: DateInterval, now: Date, segments: [AgentSegment], live: Set<Worker>) -> [Lane] {
        switch model.grouping {
        case .workers:
            let session = log.sessionSpans(now: now)
            return [Lane(id: "session", filter: nil, title: "Session", total: session.unionLength(in: interval),
                         layers: [.init(spans: session, color: .secondary.opacity(0.55))])]
                + Worker.allCases.map { worker in
                    let spans = log.spans(for: worker, now: now, segments: segments)
                    return Lane(id: worker.rawValue, filter: .worker(worker), title: worker.name,
                                total: spans.unionLength(in: interval),
                                layers: [.init(spans: spans, color: worker.color)],
                                color: worker.color, showOverlap: worker != .you,
                                liveColor: live.contains(worker) ? worker.color : nil)
                }
        case .projects:
            return log.projects(in: interval, now: now).map { project in
                let mine = segments.filter { $0.project == project.name }
                return Lane(
                    id: project.name, filter: .project(project.name), title: project.name, total: project.wallClock,
                    layers: Worker.agents.map { worker in
                        .init(spans: mine.filter { $0.worker == worker }.map(\.span), color: worker.color)
                    },
                    liveColor: project.runningWorker?.color
                )
            }
        }
    }

    private func laneChart(_ lanes: [Lane], axis: ChartAxis, concurrency: [(span: Span, count: Int)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
            if lanes.isEmpty {
                GridRow {
                    Text("No agent work in this \(model.period == .day ? "day" : "week").")
                        .foregroundStyle(.tertiary)
                        .gridCellColumns(3)
                }
            }
            ForEach(lanes) { lane in
                let selected = lane.filter != nil && model.filter == lane.filter
                GridRow {
                    HStack(spacing: 6) {
                        // The slot is kept when idle so lane names line up.
                        if let liveColor = lane.liveColor {
                            BreathingDot(color: liveColor)
                                .help("Working now")
                        } else {
                            Color.clear.frame(width: 6, height: 6)
                        }
                        Text(lane.title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(lane.color ?? .primary)
                            .fontWeight(selected ? .semibold : .regular)
                    }
                    .frame(width: 140, alignment: .leading)
                    LaneBar(layers: lane.layers, axis: axis, height: 14, showOverlap: lane.showOverlap)
                        .opacity(model.filter == nil || selected ? 1 : 0.4)
                    Text(Format.clock(lane.total, seconds: false))
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
                .font(.callout)
                .contentShape(Rectangle())
                .onTapGesture { model.toggle(lane.filter) }
                .help(lane.filter == nil ? "" : "Click to show only this lane's sessions")
            }
            workersLane(concurrency, axis: axis)
            GridRow {
                Color.clear.frame(width: 140, height: 1)
                AxisLabels(axis: axis)
                Color.clear.frame(width: 48, height: 1)
            }
        }
    }

    /// How many workers were active at once: you count as one, every agent
    /// session as one more.
    @ViewBuilder
    private func workersLane(_ steps: [(span: Span, count: Int)], axis: ChartAxis) -> some View {
        let bar = ConcurrencyBar(steps: steps, axis: axis)
        GridRow {
            Divider().gridCellColumns(3)
        }
        GridRow {
            HStack(spacing: 6) {
                Color.clear.frame(width: 6, height: 6)
                Text("Workers").foregroundStyle(.secondary)
            }
            .frame(width: 140, alignment: .leading)
            bar
            Text(bar.peak > 0 ? "max \(bar.peak)" : "—")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
        }
        .font(.callout)
        .help("How many were working at once — you, plus each agent session. Max \(bar.peak) at the same time.")
    }

    /// The cards double as the table filter: Session shows everything.
    private func cards(interval: DateInterval, now: Date, live: Set<Worker>) -> some View {
        HStack(spacing: 10) {
            FilterCard(
                title: "Session", color: .secondary, value: log.sessionTotal(in: interval, now: now),
                badge: .some(log.leverage(in: interval, now: now)),
                subtitle: "\(Format.clock(log.totalWork(in: interval, now: now), seconds: false)) of work",
                subtitleHelp: "Work logged per hour of your time: you plus every agent session, divided by your time",
                live: false, selected: model.filter == nil,
                onSelect: { model.filter = nil }, onClear: nil
            )
            ForEach(Worker.allCases) { worker in
                FilterCard(
                    title: worker.name, color: worker.color, value: log.total(worker, in: interval, now: now),
                    subtitle: agentSubtitle(worker, interval: interval, now: now),
                    subtitleHelp: "Agent-hours (parallel sessions each count) · sessions running at once, on average, while \(worker.name) worked",
                    live: live.contains(worker), selected: model.filter == .worker(worker),
                    onSelect: { model.toggle(.worker(worker)) }, onClear: { model.filter = nil }
                )
            }
        }
    }

    private func agentSubtitle(_ worker: Worker, interval: DateInterval, now: Date) -> String? {
        guard worker != .you else { return nil }
        let hours = "\(Format.clock(log.agentHours(worker, in: interval, now: now), seconds: false)) agent-hours"
        guard let parallel = log.parallelism(worker, in: interval, now: now) else { return hours }
        return "\(hours) · \(Format.multiplier(parallel))"
    }

    // MARK: - Table

    private func table(interval: DateInterval, now: Date) -> some View {
        let entries = log.entries(in: interval, now: now).filter(matchesSelection)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(filterTitle.map { "Sessions · \($0)" } ?? "Sessions")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if model.filter != nil {
                    Button("Show all") { model.filter = nil }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .padding(.bottom, 6)

            EntryRow.header
            Divider()
            if entries.isEmpty {
                Text("Nothing logged.")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            EntryRow(entry: entry, store: store, showDay: model.period == .week, now: now)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var filterTitle: String? {
        switch model.filter {
        case .worker(let worker): return worker.name
        case .project(let name): return name
        case nil: return nil
        }
    }

    private func matchesSelection(_ entry: WorkLog.Entry) -> Bool {
        switch model.filter {
        case .worker(let worker): return entry.worker == worker
        case .project(let name): return entry.project == name
        case nil: return true
        }
    }
}

private struct EntryRow: View {
    let entry: WorkLog.Entry
    let store: SessionStore
    let showDay: Bool
    let now: Date

    @State private var editing = false
    @State private var hovering = false

    static let columns: (time: CGFloat, worker: CGFloat, source: CGFloat, length: CGFloat) = (150, 70, 80, 60)

    static var header: some View {
        HStack(spacing: 8) {
            Text("Time").frame(width: columns.time, alignment: .leading)
            Text("Worker").frame(width: columns.worker, alignment: .leading)
            Text("Project").frame(maxWidth: .infinity, alignment: .leading)
            Text("Source").frame(width: columns.source, alignment: .leading)
            Text("Worked").frame(width: columns.length, alignment: .trailing)
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(timeText)
                .monospacedDigit()
                .frame(width: Self.columns.time, alignment: .leading)
            HStack(spacing: 6) {
                WorkerDot(color: entry.worker.color, live: entry.running)
                Text(entry.worker.name)
            }
            .frame(width: Self.columns.worker, alignment: .leading)
            Text(entry.project ?? "—")
                .lineLimit(1)
                .foregroundStyle(entry.project == nil ? .tertiary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.source)
                .foregroundStyle(.secondary)
                .frame(width: Self.columns.source, alignment: .leading)
            Text(Format.clock(entry.worked, seconds: false))
                .monospacedDigit()
                .frame(width: Self.columns.length, alignment: .trailing)
        }
        .font(.callout)
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 4).fill(hovering && isYours ? Color.primary.opacity(0.05) : .clear))
        .liveEdge(entry.worker.color, live: entry.running)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if isYours { editing = true } }
        .contextMenu {
            switch entry.kind {
            case .you(let session):
                Button("Edit Times…") { editing = true }
                Button("Delete Session", role: .destructive) { store.delete(session.id) }
            case .youRunning:
                Button("Edit Start Time…") { editing = true }
            case .agent:
                EmptyView()
            }
        }
        .popover(isPresented: $editing) {
            if let target = editorTarget {
                SessionEditor(store: store, target: target, onDone: { editing = false })
                    .frame(width: 280)
                    .padding(8)
            }
        }
    }

    private var isYours: Bool { entry.worker == .you }

    private var editorTarget: SessionEditor.Target? {
        switch entry.kind {
        case .you(let session): return .finished(session)
        case .youRunning(let active): return .running(active)
        case .agent: return nil
        }
    }

    private var timeText: String {
        let end = entry.running ? "now" : Format.time(entry.span.end)
        let range = "\(Format.time(entry.span.start)) – \(end)"
        return showDay ? "\(Self.weekday.string(from: entry.span.start)) \(range)" : range
    }

    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f
    }()
}

/// A totals card that filters the session table when clicked. The selected card
/// is raised onto the window surface, like the selected segment of a picker.
private struct FilterCard: View {
    let title: String
    let color: Color
    let value: TimeInterval
    /// `.some(nil)` shows an empty badge ("—"); nil shows none.
    var badge: Double?? = nil
    let subtitle: String?
    let subtitleHelp: String
    let live: Bool
    let selected: Bool
    let onSelect: () -> Void
    /// Shows a clear button while selected; nil for the Session card.
    let onClear: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if live { BreathingDot(color: color) }
                Text(title).font(.caption).foregroundStyle(color)
                Spacer(minLength: 0)
                if selected, let onClear {
                    Button(action: onClear) {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Show all sessions")
                }
            }
            HStack(spacing: 6) {
                Text(Format.clock(value, seconds: false))
                    .font(.title2.weight(.medium))
                    .monospacedDigit()
                if let badge {
                    MultiplierBadge(value: badge)
                }
            }
            Text(subtitle ?? " ")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .lineLimit(1)
                .help(subtitle == nil ? "" : subtitleHelp)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .liveEdge(color, live: live)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(selected ? 0.15 : 0), radius: 2, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
        .help(selected ? "" : "Show only \(title == "Session" ? "all" : title) sessions")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        if selected {
            shape
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
        } else {
            shape.fill(Color.primary.opacity(hovering ? 0.08 : 0.05))
        }
    }
}
