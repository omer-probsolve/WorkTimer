import AppKit
import Combine
import WorkTimerCore

@main
enum WorkTimerApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu-bar only: no Dock icon, no app switcher entry.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private let notifier = Notifier()
    private var store: SessionStore!
    private var agents: AgentMonitor!
    private var log: WorkLog!
    private var tracker: TimeTracker!
    private var dashboard: DashboardWindowController!
    private var statusItem: StatusItemController!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = SessionStore()
        let trackingStart = agentTrackingStart()
        agents = AgentMonitor(cutoff: WorkMetrics.agentCutoff(log: store.log, trackingStart: trackingStart))
        log = WorkLog(store: store, agents: agents, trackingStart: trackingStart)
        tracker = TimeTracker(store: store, settings: settings, notifier: notifier)
        tracker.runningAgents = { [weak self] in
            guard let self else { return [] }
            return Set(self.log.metrics.running(now: Date()).map(\.worker.name)).sorted()
        }
        dashboard = DashboardWindowController(log: log, store: store, settings: settings)
        statusItem = StatusItemController(log: log, settings: settings, tracker: tracker, dashboard: dashboard)

        // Editing a session onto an earlier day makes that day's agent work count.
        store.$log
            .sink { [weak self] _ in
                guard let self else { return }
                self.agents.extendCutoff(to: WorkMetrics.agentCutoff(log: self.store.log, trackingStart: trackingStart))
            }
            .store(in: &cancellables)
        agents.start()

        notifier.onAction = { [weak self] action, sessionID in
            self?.handleNotificationAction(action, sessionID: sessionID)
        }
        notifier.setUp()

        registerHotKeys()
        observeExternalTrigger()
        tracker.start()
        enableLoginItemOnFirstRun()
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyManager.shared.unregisterAll()
        tracker?.stopForQuit()
    }

    /// Opening the app again from /Applications or Spotlight shows the popover.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem.showPopover()
        return false
    }

    /// Lets other tools (Shortcuts, Raycast, a shell script) open the windows:
    /// post the `…showPanel` or `…showDashboard` distributed notification.
    private func observeExternalTrigger() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            forName: Notification.Name("com.omershaashua.worktimer.showPanel"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.statusItem.showPopover()
        }
        center.addObserver(
            forName: Notification.Name("com.omershaashua.worktimer.showDashboard"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.dashboard.show()
        }
        #if DEBUG
        // Renders the app's own windows to PNGs in the data folder — for checking
        // layout without Screen Recording permission.
        center.addObserver(
            forName: Notification.Name("com.omershaashua.worktimer.debugSnapshot"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            let info = note.userInfo as? [String: String] ?? [:]
            if let appearance = info["appearance"] {
                NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            }
            if info["window"] == "glance" {
                self?.statusItem.showPopover()
            } else {
                self?.dashboard.debugConfigure(grouping: info["grouping"], period: info["period"], step: info["step"], filter: info["filter"])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                for window in NSApp.windows where window.isVisible {
                    let index = (window is NSPanel ? "glance" : "dashboard-\(info["grouping"] ?? "")-\(info["filter"] ?? "")") + "-\(info["appearance"] ?? "light")"
                    guard let view = window.contentView, view.bounds.width > 100,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let url = AppPaths.dataDirectory.appendingPathComponent("snapshot-\(index).png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                }
            }
        }
        #endif
    }

    private func registerHotKeys() {
        settings.$togglePanelShortcut
            .sink { [weak self] combo in
                self?.bind(.togglePanel, combo) { self?.statusItem.togglePopover() }
            }
            .store(in: &cancellables)
        settings.$toggleTimerShortcut
            .sink { [weak self] combo in
                self?.bind(.toggleTimer, combo) { self?.tracker.toggle() }
            }
            .store(in: &cancellables)
    }

    private func bind(_ action: HotKeyManager.Action, _ combo: KeyCombo?, handler: @escaping () -> Void) {
        if HotKeyManager.shared.register(action, combo: combo, handler: handler) {
            settings.conflictingShortcuts.remove(action)
        } else {
            settings.conflictingShortcuts.insert(action)
        }
    }

    private func handleNotificationAction(_ action: Notifier.Action, sessionID: UUID?) {
        switch action {
        case .open:
            statusItem.showPopover()
        case .discard:
            tracker.discardAutoStarted()
        case .disableAutoClockIn:
            tracker.discardAutoStarted()
            settings.autoClockIn = false
        case .countIdleTime:
            if let sessionID { tracker.countIdleTime(sessionID: sessionID) }
        }
    }

    /// The day agent tracking was added. Agent work from before it only shows on
    /// days you logged time yourself.
    private func agentTrackingStart() -> Date {
        let key = "agentTrackingStart"
        if let date = UserDefaults.standard.object(forKey: key) as? Date { return date }
        let today = Calendar.current.startOfDay(for: Date())
        UserDefaults.standard.set(today, forKey: key)
        return today
    }

    /// Auto clock-in only works if the app is running, so register the login item
    /// on first launch. Done once only — if turned off in Settings, it stays off.
    private func enableLoginItemOnFirstRun() {
        let key = "didAttemptInitialLoginItemRegistration"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? LaunchAtLogin.set(true)
    }
}
