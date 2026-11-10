import SwiftUI
import WorkTimerCore

/// The at-a-glance window under the menu bar icon.
struct GlanceView: View {
    @ObservedObject var log: WorkLog
    @ObservedObject var store: SessionStore
    @ObservedObject var settings: AppSettings
    let tracker: TimeTracker
    let openDashboard: (_ settings: Bool) -> Void

    static let size = CGSize(width: 380, height: 470)
    static let cornerRadius = IslandTheme.Radius.panel
    private static let maxRunningRows = 3

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let today = DateInterval.of(.day, containing: now)
            let sessionStart = log.metrics.currentSessionStart(now: now)
            let running = log.metrics.running(now: now)
            let live = log.metrics.liveWorkers(now: now)

            VStack(alignment: .leading, spacing: 10) {
                header(sessionStart: sessionStart)

                clock(sessionStart: sessionStart, today: today, now: now)

                lanes(today: today, now: now, live: live)

                HStack(spacing: 6) {
                    ForEach(Worker.allCases) { worker in
                        card(worker, today: today, now: now, live: live.contains(worker))
                    }
                }

                runningList(running, now: now)

                Spacer(minLength: 0)

                IslandToggleRow("Auto clock-in", isOn: $settings.autoClockIn)

                Button { openDashboard(false) } label: {
                    Label("Open Dashboard", systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(IslandButtonStyle(primary: true, height: 32))
            }
            .padding(14)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        // Always dark, like the notch island, whatever the system appearance.
        .islandInk(radius: Self.cornerRadius)
    }

    private func header(sessionStart: Date?) -> some View {
        HStack(spacing: 10) {
            IslandLabel(sessionStart.map { "Work session · since \(Format.time($0))" } ?? "Not working · today's total")
            Spacer()
            Button(action: tracker.toggle) {
                Image(systemName: store.isRunning ? "stop.fill" : "play.fill")
                    .foregroundStyle(store.isRunning ? Color.red : IslandTheme.accent)
            }
            .help(store.isRunning ? "Stop your timer" : "Start your timer")
            Button { openDashboard(true) } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
        }
        .buttonStyle(IslandIconButtonStyle(size: 26))
    }

    private func clock(sessionStart: Date?, today: DateInterval, now: Date) -> some View {
        let clock = Format.clock(sessionStart.map { now.timeIntervalSince($0) } ?? log.metrics.sessionTotal(in: today, now: now))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Text(clock)
                    .islandNumber(size: 36, weight: .medium, value: clock)
                    .foregroundStyle(sessionStart == nil ? IslandTheme.secondary : Color.primary)
                MultiplierBadge(value: log.metrics.leverage(in: today, now: now))
                    .help(Explain.leverage)
            }
            Text("\(Format.clock(log.metrics.totalWork(in: today, now: now), seconds: false)) of work today")
                .font(.caption)
                .foregroundStyle(IslandTheme.secondary)
                .monospacedDigit()
        }
        .padding(.top, -4)
    }

    /// One slim lane per worker plus the session, like the dashboard's.
    private func lanes(today: DateInterval, now: Date, live: Set<Worker>) -> some View {
        let segments = log.metrics.agentSegments(now: now)
        let axis = ChartAxis.day(now, startMinute: settings.timelineStartMinute, endMinute: settings.timelineEndMinute)
        return Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 4) {
            lane("Session", color: IslandTheme.secondary, live: false, axis: axis,
                 layers: [.session(log.metrics.sessionSpans(now: now))])
            ForEach(Worker.allCases) { worker in
                lane(worker.name, color: worker.color, live: live.contains(worker), axis: axis,
                     layers: [.worker(worker, log.metrics.spans(for: worker, now: now, segments: segments))],
                     showOverlap: worker != .you)
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                AxisLabels(axis: axis)
            }
        }
        .islandSoftCard(padding: 10)
    }

    private func lane(_ title: String, color: Color, live: Bool, axis: ChartAxis,
                      layers: [LaneBar.Layer], showOverlap: Bool = false) -> some View {
        GridRow {
            HStack(spacing: 5) {
                LiveDot(color: color, live: live)
                Text(title).font(.caption).foregroundStyle(color)
            }
            .frame(width: 62, alignment: .leading)
            LaneBar(layers: layers, axis: axis, height: 8, showOverlap: showOverlap)
        }
    }

    private func card(_ worker: Worker, today: DateInterval, now: Date, live: Bool) -> some View {
        StatCard(
            title: worker.name, color: worker.color, value: log.metrics.total(worker, in: today, now: now),
            subtitle: log.metrics.agentSummary(worker, in: today, now: now, compact: true),
            subtitleHelp: Explain.agent(worker), live: live, size: .compact
        )
    }

    private func runningList(_ running: [WorkMetrics.RunningAgent], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            IslandLabel(running.isEmpty ? "No agents running" : "Running now · \(running.count)")
                .padding(.bottom, 2)
            ForEach(running.prefix(Self.maxRunningRows)) { agent in
                HStack(spacing: 7) {
                    BreathingDot(color: agent.worker.color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(agent.project).lineLimit(1)
                        if agent.waitingOnTask {
                            Text("Waiting on a background task")
                                .font(.caption)
                                .foregroundStyle(IslandTheme.secondary)
                        }
                    }
                    Spacer()
                    Text("\(agent.worker.name) · \(Format.duration(now.timeIntervalSince(agent.since)))")
                        .foregroundStyle(IslandTheme.secondary)
                        .monospacedDigit()
                }
                .font(.callout)
                .padding(.vertical, 4)
                .padding(.horizontal, 9)
                .islandRow()
                .liveEdge(agent.worker.color, live: true)
                .clipShape(RoundedRectangle(cornerRadius: IslandTheme.Radius.row, style: .continuous))
                .transition(.islandAppear)
            }
            if running.count > Self.maxRunningRows {
                Text("+\(running.count - Self.maxRunningRows) more")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                    .padding(.leading, 9)
            }
        }
        // Keyed to which agents are listed, so the one-second refresh (same
        // rows, new durations) animates nothing.
        .animation(IslandTheme.spring(), value: running.prefix(Self.maxRunningRows).map(\.id))
    }
}
