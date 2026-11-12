import AppKit
import Combine
import SwiftUI
import WorkTimerCore

/// Runs Work Timer: the stores, agent monitors, auto clock-in/out, shortcuts and
/// windows. The standalone app creates one with its own menu bar item; a host such
/// as Toolbelt creates one with `hosted: true` and shows Work Timer in its own item.
public final class WorkTimerController {
    /// What Work Timer's menu bar item would show: the symbol, the running clock and
    /// a tooltip. A host draws it in its own item.
    public struct MenuBarAppearance {
        public let image: NSImage?
        public let title: NSAttributedString
        public let toolTip: String
    }

    private let hosted: Bool
    private let settings: AppSettings
    private let notifier = Notifier()
    private var store: SessionStore!
    private var agents: AgentMonitor!
    private var aiWorld: AIWorldMonitor!
    private var log: WorkLog!
    private var tracker: TimeTracker!
    private var dashboard: DashboardWindowController!
    private var statusItem: StatusItemController!
    private var cancellables = Set<AnyCancellable>()

    /// When hosted: the host's menu bar button, so the window opens under it.
    public var hostButton: (() -> NSStatusBarButton?)?
    /// When hosted: called whenever the menu bar item should change (every second
    /// while the clock runs).
    public var onMenuBarChange: ((MenuBarAppearance) -> Void)?

    public init(hosted: Bool) {
        self.hosted = hosted
        Host.isHosted = hosted
        settings = AppSettings()
        aiWorld = AIWorldMonitor { [settings] in
            settings.aiWorldFolder.isEmpty ? nil : URL(fileURLWithPath: settings.aiWorldFolder)
        }
    }

    /// The where your sessions are saved: ~/Library/Application Support/WorkTimer.
    public static var dataDirectory: URL { AppPaths.dataDirectory }

    /// The number of sessions saved, plus one when a session is running. A host
    /// compares it with the data file to confirm nothing was lost.
    public var sessionCount: Int {
        guard let store else { return 0 }
        return store.log.sessions.count + (store.log.active == nil ? 0 : 1)
    }

    public var isTracking: Bool { store?.isRunning ?? false }

    public func start() {
        store = SessionStore()
        let trackingStart = agentTrackingStart()
        agents = AgentMonitor(cutoff: WorkMetrics.agentCutoff(log: store.log, trackingStart: trackingStart))
        log = WorkLog(store: store, agents: agents, aiWorld: aiWorld, trackingStart: trackingStart)
        tracker = TimeTracker(store: store, settings: settings, notifier: notifier)
        tracker.runningAgents = { [weak self] in
            guard let self else { return [] }
            return Set(self.log.metrics.running(now: Date()).map(\.worker.name)).sorted()
        }
        dashboard = DashboardWindowController(log: log, store: store, settings: settings)
        if hosted {
            statusItem = StatusItemController(
                log: log, settings: settings, tracker: tracker, dashboard: dashboard,
                hostButton: { [weak self] in self?.hostButton?() },
                onAppearance: { [weak self] appearance in
                    self?.onMenuBarChange?(MenuBarAppearance(
                        image: appearance.image, title: appearance.title, toolTip: appearance.toolTip
                    ))
                }
            )
        } else {
            statusItem = StatusItemController(log: log, settings: settings, tracker: tracker, dashboard: dashboard)
        }

        // Editing a session onto an earlier day makes that day's agent work count.
        store.$log
            .sink { [weak self] _ in
                guard let self else { return }
                self.agents.extendCutoff(to: WorkMetrics.agentCutoff(log: self.store.log, trackingStart: trackingStart))
            }
            .store(in: &cancellables)
        agents.start()
        LANSyncReceiver.shared.start()
        settings.$countAIWorld
            .removeDuplicates()
            .sink { [weak self] enabled in self?.aiWorld.setEnabled(enabled) }
            .store(in: &cancellables)

        notifier.onAction = { [weak self] action, sessionID in
            self?.handleNotificationAction(action, sessionID: sessionID)
        }
        notifier.setUp()

        registerHotKeys()
        observeExternalTrigger()
        tracker.start()
        if !hosted { enableLoginItemOnFirstRun() }
    }

    /// Ends a running session cleanly; call when the app quits.
    public func stop() {
        HotKeyManager.shared.unregisterAll()
        tracker?.stopForQuit()
    }

    // MARK: - For hosts

    /// The quick menu's items (start/stop, auto clock-in, windows), for a host's menu.
    public func menuItems() -> [NSMenuItem] {
        statusItem?.menuItems(includeQuit: false) ?? []
    }

    /// The menu bar window (today at a glance).
    public func showWindow() { statusItem?.showPopover() }

    public func toggleWindow() { statusItem?.togglePopover() }

    public func showDashboard() { dashboard?.show() }

    public func toggleTimer() { tracker?.toggle() }

    /// Clock in automatically when you're active.
    public var autoClockIn: Bool {
        get { settings.autoClockIn }
        set { settings.autoClockIn = newValue }
    }

    /// Today's numbers, ready to display.
    public func stats(now: Date = Date()) -> WorkTimerStats? {
        guard let log else { return nil }
        return WorkTimerStats.make(log.metrics, autoClockIn: settings.autoClockIn, now: now)
    }

    /// Work Timer's settings form, for a host's settings page.
    public func makeSettingsView() -> AnyView {
        AnyView(SettingsView(settings: settings, store: store))
    }

    // MARK: -

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
                self?.dashboard.debugConfigure(grouping: info["grouping"], period: info["period"], step: info["step"], filter: info["filter"], hover: info["hover"])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                for window in NSApp.windows where window.isVisible {
                    let index = (window is NSPanel ? "glance" : "dashboard-\(info["grouping"] ?? "")-\(info["filter"] ?? "")") + "-\(info["appearance"] ?? "light")"
                    guard let view = window.contentView, view.bounds.width > 100,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    // The window, not the content view, draws the background; add it
                    // so the PNG isn't transparent.
                    let image = NSImage(size: view.bounds.size, flipped: false) { rect in
                        window.effectiveAppearance.performAsCurrentDrawingAppearance {
                            window.backgroundColor.setFill()
                            rect.fill()
                        }
                        rep.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
                        return true
                    }
                    guard let tiff = image.tiffRepresentation, let flat = NSBitmapImageRep(data: tiff) else { continue }
                    let url = AppPaths.dataDirectory.appendingPathComponent("snapshot-\(index).png")
                    try? flat.representation(using: .png, properties: [:])?.write(to: url)
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
        if let date = Host.defaults.object(forKey: key) as? Date { return date }
        let today = Calendar.current.startOfDay(for: Date())
        Host.defaults.set(today, forKey: key)
        return today
    }

    /// Auto clock-in only works if the app is running, so register the login item
    /// on first launch. Done once only — if turned off in Settings, it stays off.
    private func enableLoginItemOnFirstRun() {
        let key = "didAttemptInitialLoginItemRegistration"
        guard !Host.defaults.bool(forKey: key) else { return }
        Host.defaults.set(true, forKey: key)
        try? LaunchAtLogin.set(true)
    }
}
