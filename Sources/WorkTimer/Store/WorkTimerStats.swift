import SwiftUI
import WorkTimerCore

/// Today's numbers, ready to display, for a host's glanceable views (Toolbelt's
/// notch island and stats panel). Everything comes from `WorkMetrics` and is
/// formatted with `Format`; hosts only lay it out.
public struct WorkTimerStats {
    public struct WorkerRow: Identifiable {
        public let id: String
        public let name: String
        public let color: Color
        /// Your time, or the agent's agent-hours: the rows add up to `workLogged`.
        public let time: String
        /// This row's share of `workLogged`, 0…1.
        public let share: Double
        public let isLive: Bool
        /// "clocked in", "2 running", "idle".
        public let note: String
    }

    public struct RunningSession: Identifiable {
        public let id: String
        public let worker: String
        public let color: Color
        public let project: String
        /// "working", or "waiting on a task" while a background task it started runs.
        public let state: String
        public let time: String
    }

    /// You or any agent is working right now.
    public let isWorking: Bool
    /// Your own timer is running.
    public let isTracking: Bool
    public let autoClockIn: Bool
    /// Today, when you or any agent worked; parallel work counts once. "5:48"
    public let sessionToday: String
    /// Today, your time plus every agent-hour. "11:20"
    public let workLogged: String
    /// Work logged per hour of yours, "3.4×"; nil until you've logged a minute.
    public let multiplier: String?
    public let workers: [WorkerRow]
    public let running: [RunningSession]

    /// One color per running agent session, for a row of dots.
    public var runningColors: [Color] { running.map(\.color) }

    static func make(_ metrics: WorkMetrics, autoClockIn: Bool, now: Date) -> WorkTimerStats {
        let today = DateInterval.of(.day, containing: now)
        let running = metrics.running(now: now)
        let live = metrics.liveWorkers(now: now)
        let logged = metrics.totalWork(in: today, now: now)

        let workers: [WorkerRow] = Worker.allCases.map { worker in
            let time = worker == .you
                ? metrics.total(.you, in: today, now: now)
                : metrics.agentHours(worker, in: today, now: now)
            let count = running.filter { $0.worker == worker }.count
            let note: String
            if worker == .you {
                note = metrics.log.isRunning ? "clocked in" : autoClockIn ? "not tracking" : "auto clock-in off"
            } else {
                note = count > 0 ? "\(count) running" : "idle"
            }
            return WorkerRow(
                id: worker.rawValue, name: worker.name, color: worker.color,
                time: Format.clock(time, seconds: false),
                share: logged > 0 ? min(1, time / logged) : 0,
                isLive: live.contains(worker), note: note
            )
        }

        let sessions = running.sorted { $0.since < $1.since }.map { agent in
            RunningSession(
                id: agent.sessionID, worker: agent.worker.name, color: agent.worker.color,
                project: agent.project,
                state: agent.waitingOnTask ? "waiting on a task" : "working",
                time: Format.clock(now.timeIntervalSince(agent.since), seconds: false)
            )
        }

        return WorkTimerStats(
            isWorking: metrics.isWorking(now: now),
            isTracking: metrics.log.isRunning,
            autoClockIn: autoClockIn,
            sessionToday: Format.clock(metrics.sessionTotal(in: today, now: now), seconds: false),
            workLogged: Format.clock(logged, seconds: false),
            multiplier: metrics.leverage(in: today, now: now).map(Format.multiplier),
            workers: workers,
            running: sessions
        )
    }
}
