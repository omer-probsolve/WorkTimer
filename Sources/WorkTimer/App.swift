import AppKit
import Combine

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
    private var tracker: TimeTracker!
    private var statusItem: StatusItemController!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = SessionStore()
        tracker = TimeTracker(store: store, settings: settings, notifier: notifier)
        statusItem = StatusItemController(store: store, settings: settings, tracker: tracker)

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

    /// Lets other tools (Shortcuts, Raycast, a shell script) open the window:
    /// post the `…showPanel` distributed notification.
    private func observeExternalTrigger() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.omershaashua.worktimer.showPanel"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.statusItem.showPopover()
        }
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

    /// Auto clock-in only works if the app is running, so register the login item
    /// on first launch. Done once only — if turned off in Settings, it stays off.
    private func enableLoginItemOnFirstRun() {
        let key = "didAttemptInitialLoginItemRegistration"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? LaunchAtLogin.set(true)
    }
}
