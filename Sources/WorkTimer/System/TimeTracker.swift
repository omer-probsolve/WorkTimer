import AppKit

/// Decides when to clock in and out automatically.
///
/// Every few seconds it samples the system idle counter:
///  * Timer running and no input for the idle threshold → clock out, back-dated to
///    the last input, so the idle stretch isn't counted.
///  * The Mac was idle (or asleep) for the threshold, then input resumes and keeps
///    going for `confirmDelay` → clock in, back-dated to when input resumed.
///
/// A manual stop disarms auto clock-in until the next idle period, so pressing
/// Stop while still at the keyboard isn't immediately undone.
final class TimeTracker {
    private let store: SessionStore
    private let settings: AppSettings
    private let notifier: Notifier

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    /// Latest moment we know the user touched the keyboard or mouse.
    private var lastActivity = Date()
    /// True after an idle period; the next sustained activity may auto clock-in.
    /// Starts true so launching at login clocks in once you start working.
    private var armed = true
    /// When the activity that may trigger an auto clock-in began.
    private var pendingStart: Date?
    private var screensAsleep = false

    private static let tickInterval: TimeInterval = 5
    /// Input this recent counts as "the user is active right now".
    private static let freshWindow: TimeInterval = 15
    /// Activity must last this long before auto clock-in — a bumped mouse shouldn't count.
    private static let confirmDelay: TimeInterval = 30
    /// Auto-ended sessions shorter than this are dropped.
    private static let minimumAutoSession: TimeInterval = 60

    init(store: SessionStore, settings: AppSettings, notifier: Notifier) {
        self.store = store
        self.settings = settings
        self.notifier = notifier
    }

    func start() {
        lastActivity = Date().addingTimeInterval(-ActivityMonitor.secondsSinceLastInput())

        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.screensAsleep = true
            },
            center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.screensAsleep = false
                self?.tick()
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.tick()
            },
        ]
        tick()
    }

    // MARK: - Manual control

    func toggle() {
        store.isRunning ? stopManually() : startManually()
    }

    func startManually() {
        store.start(at: Date(), automatic: false)
        pendingStart = nil
    }

    func stopManually() {
        store.stop(at: Date(), reason: .manual)
        armed = false
        pendingStart = nil
    }

    func stopForQuit() {
        store.stop(at: Date(), reason: .quit, minimumDuration: Self.minimumAutoSession)
    }

    // MARK: - Notification actions

    func discardAutoStarted() {
        guard store.active?.startedAutomatically == true else { return }
        store.discardActive()
        armed = false
    }

    func countIdleTime(sessionID: UUID) {
        store.reopen(sessionID)
        armed = false
    }

    // MARK: - Sampling

    private func tick() {
        let now = Date()
        let threshold = settings.idleThreshold
        let latestInput = now.addingTimeInterval(-ActivityMonitor.secondsSinceLastInput())

        // Input resumed after a silence longer than the threshold that we didn't see
        // happen — the Mac was asleep. Close the session where activity stopped.
        if latestInput.timeIntervalSince(lastActivity) >= threshold {
            endIdlePeriod(lastActive: lastActivity)
        }
        lastActivity = max(lastActivity, latestInput)

        let idleFor = now.timeIntervalSince(lastActivity)
        if idleFor >= threshold {
            endIdlePeriod(lastActive: lastActivity)
        } else if idleFor < Self.freshWindow {
            considerAutoStart(now: now)
        } else if idleFor >= Self.confirmDelay {
            pendingStart = nil
        }

        store.heartbeat(now)
    }

    private func endIdlePeriod(lastActive: Date) {
        armed = true
        pendingStart = nil
        guard store.isRunning, settings.autoClockOut else { return }
        guard let result = store.stop(at: lastActive, reason: .idle, minimumDuration: Self.minimumAutoSession) else { return }
        notifyAutoStop(result)
    }

    private func considerAutoStart(now: Date) {
        guard armed, !store.isRunning, settings.autoClockIn,
              !screensAsleep, !ActivityMonitor.isScreenLocked else {
            pendingStart = nil
            return
        }
        guard let began = pendingStart else {
            pendingStart = now
            return
        }
        guard now.timeIntervalSince(began) >= Self.confirmDelay else { return }

        armed = false
        pendingStart = nil
        store.start(at: began, automatic: true)
        notifyAutoStart(at: began)
    }

    // MARK: - Notifications

    private func notifyAutoStart(at date: Date) {
        guard settings.notificationsEnabled else { return }
        notifier.post(
            title: "Clocked in",
            body: "You're active on your Mac, so Work Timer started tracking at \(Format.time(date)).",
            category: .autoStart,
            sessionID: store.active?.id
        )
    }

    private func notifyAutoStop(_ result: SessionStore.StopResult) {
        guard settings.notificationsEnabled else { return }
        let idle = "No activity for \(settings.idleMinutes) min"
        let body: String
        if result.logged {
            let today = store.total(in: Calendar.current.dateInterval(of: .day, for: Date())!, now: Date())
            body = "\(idle). Stopped at \(Format.time(result.session.end)) — logged \(Format.duration(result.session.duration)), \(Format.duration(today)) today."
        } else {
            body = "\(idle). The session was under a minute, so it wasn't logged."
        }
        notifier.post(
            title: "Clocked out",
            body: body,
            category: .autoStop,
            sessionID: result.logged ? result.session.id : nil
        )
    }
}
