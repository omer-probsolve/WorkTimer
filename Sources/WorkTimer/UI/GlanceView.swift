import SwiftUI

/// The at-a-glance window under the menu bar icon.
struct GlanceView: View {
    @ObservedObject var log: WorkLog
    @ObservedObject var store: SessionStore
    @ObservedObject var settings: AppSettings
    let tracker: TimeTracker
    let openDashboard: (_ settings: Bool) -> Void

    static let size = CGSize(width: 320, height: 470)
    private static let maxRunningRows = 3

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let today = DateInterval.of(.day, containing: now)
            let sessionStart = log.currentSessionStart(now: now)
            let running = log.running(now: now)
            let live = log.liveWorkers(now: now)

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

                Toggle(isOn: $settings.autoClockIn) {
                    Text("Auto clock-in").font(.callout)
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Button { openDashboard(false) } label: {
                    Label("Open Dashboard", systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            .padding(14)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private func header(sessionStart: Date?) -> some View {
        HStack(spacing: 10) {
            Text(sessionStart.map { "Work session · since \(Format.time($0))" } ?? "Not working · today's total")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: tracker.toggle) {
                Image(systemName: store.isRunning ? "stop.fill" : "play.fill")
                    .foregroundStyle(store.isRunning ? .red : .green)
            }
            .buttonStyle(.borderless)
            .help(store.isRunning ? "Stop your timer" : "Start your timer")
            Button { openDashboard(true) } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
    }

    private func clock(sessionStart: Date?, today: DateInterval, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Text(Format.clock(sessionStart.map { now.timeIntervalSince($0) } ?? log.sessionTotal(in: today, now: now)))
                    .font(.system(size: 36, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(sessionStart == nil ? .secondary : .primary)
                MultiplierBadge(value: log.leverage(in: today, now: now))
                    .help(Explain.leverage)
            }
            Text("\(Format.clock(log.totalWork(in: today, now: now), seconds: false)) of work today")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.top, -6)
    }

    /// One slim lane per worker plus the session, like the dashboard's.
    private func lanes(today: DateInterval, now: Date, live: Set<Worker>) -> some View {
        let segments = log.agentSegments(now: now)
        let axis = ChartAxis.day(now, startMinute: settings.timelineStartMinute, endMinute: settings.timelineEndMinute)
        return Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 4) {
            lane("Session", color: .secondary, live: false, axis: axis,
                 layers: [.session(log.sessionSpans(now: now))])
            ForEach(Worker.allCases) { worker in
                lane(worker.name, color: worker.color, live: live.contains(worker), axis: axis,
                     layers: [.worker(worker, log.spans(for: worker, now: now, segments: segments))],
                     showOverlap: worker != .you)
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                AxisLabels(axis: axis)
            }
        }
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
            title: worker.name, color: worker.color, value: log.total(worker, in: today, now: now),
            subtitle: log.agentSummary(worker, in: today, now: now, compact: true),
            subtitleHelp: Explain.agent(worker), live: live, size: .compact
        )
    }

    private func runningList(_ running: [WorkLog.RunningAgent], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(running.isEmpty ? "No agents running" : "Running now · \(running.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            ForEach(running.prefix(Self.maxRunningRows)) { agent in
                Divider()
                HStack(spacing: 7) {
                    BreathingDot(color: agent.worker.color)
                    Text(agent.project).lineLimit(1)
                    Spacer()
                    Text("\(agent.worker.name) · \(Format.duration(now.timeIntervalSince(agent.since)))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.callout)
                .padding(.vertical, 4)
                .padding(.leading, 7)
                .liveEdge(agent.worker.color, live: true)
            }
            if running.count > Self.maxRunningRows {
                Divider()
                Text("+\(running.count - Self.maxRunningRows) more")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
    }
}
