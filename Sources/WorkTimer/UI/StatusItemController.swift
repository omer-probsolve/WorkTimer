import AppKit
import Combine
import SwiftUI
import WorkTimerCore

/// The menu bar item: shows the running timer, opens the window on click and a
/// quick menu on right-click.
///
/// The window is a floating panel rather than an NSPopover: SwiftUI content in a
/// popover gets clipped at the top, and a popover can't be shown at all when the
/// menu bar is hidden by a full-screen app.
final class StatusItemController: NSObject, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private lazy var panel: NSPanel = makePanel()
    /// When the panel last hid itself because focus moved away.
    private var lastAutoHide = Date.distantPast
    private let log: WorkLog
    private let store: SessionStore
    private let settings: AppSettings
    private let tracker: TimeTracker
    private let dashboard: DashboardWindowController
    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(log: WorkLog, settings: AppSettings, tracker: TimeTracker, dashboard: DashboardWindowController) {
        self.log = log
        self.store = log.store
        self.settings = settings
        self.tracker = tracker
        self.dashboard = dashboard
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }

        // Defer to the next runloop pass: objectWillChange fires before the value changes.
        Publishers.Merge(log.objectWillChange, settings.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &cancellables)

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        refresh()
    }

    // MARK: - Window

    func togglePopover() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else if Date().timeIntervalSince(lastAutoHide) > 0.3 {
            // Clicking the menu bar icon while open first hides the panel (focus
            // moves away); don't immediately reopen it.
            showPopover()
        }
    }

    func showPopover() {
        NSApp.activate(ignoringOtherApps: true)
        position(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Just under the menu bar icon when it's visible, otherwise top-centre of the
    /// screen the mouse is on.
    private func position(_ panel: NSPanel) {
        let size = panel.frame.size
        if let button = statusItem.button, let anchor = onScreenFrame(of: button),
           let visible = button.window?.screen?.visibleFrame {
            let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
            panel.setFrameOrigin(NSPoint(x: x, y: visible.maxY - size.height - 6))
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 12))
        }
    }

    private func onScreenFrame(of button: NSStatusBarButton) -> NSRect? {
        guard let window = button.window, window.isVisible,
              window.occlusionState.contains(.visible),
              let screen = window.screen else { return nil }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        return screen.frame.contains(frame) ? frame : nil
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingController(
            rootView: GlanceView(log: log, store: store, settings: settings, tracker: tracker) { [weak self] showSettings in
                self?.panel.orderOut(nil)
                self?.dashboard.show(settings: showSettings)
            }
        )
        let panel = NSPanel(contentViewController: hosting)
        panel.setContentSize(GlanceView.size)
        panel.styleMask = [.titled, .closable, .fullSizeContentView]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        // Show over full-screen apps, on whichever Space is active.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        return panel
    }

    // Behave like a menu bar popover: clicking elsewhere dismisses it.
    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSPanel === panel,
              panel.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        // Focus may be moving to our own dialog (e.g. the CSV save panel); check
        // once the new key window is in place.
        DispatchQueue.main.async { [self] in
            guard NSApp.modalWindow == nil, !(NSApp.keyWindow is NSSavePanel), !panel.isKeyWindow else { return }
            panel.orderOut(nil)
            lastAutoHide = Date()
        }
    }

    // MARK: - Menu bar rendering

    private func refresh() {
        guard let button = statusItem.button else { return }
        let now = Date()
        let sessionStart = log.metrics.currentSessionStart(now: now)
        let running = sessionStart != nil
        let symbol: String
        if store.isRunning {
            symbol = "timer"
        } else if running {
            // Only agents are working.
            symbol = "sparkles"
        } else if settings.autoClockIn {
            symbol = "clock"
        } else {
            symbol = "moon.zzz"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Work Timer")
        image?.isTemplate = true
        if button.image?.name() != symbol {
            image?.setName(symbol)
            button.image = image
        }

        if let sessionStart {
            let text = " " + Format.clock(now.timeIntervalSince(sessionStart), seconds: settings.showSecondsInMenuBar)
            button.attributedTitle = NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            ])
        } else if !button.title.isEmpty {
            button.title = ""
        }

        let shortcut = settings.togglePanelShortcut.map { " — \($0.displayString)" } ?? ""
        button.toolTip = (store.isRunning ? "Work Timer: tracking" : running ? "Work Timer: an agent is working" : settings.autoClockIn ? "Work Timer: not tracking" : "Work Timer: auto clock-in off") + shortcut
    }

    // MARK: - Clicks

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showQuickMenu()
        } else {
            togglePopover()
        }
    }

    private func showQuickMenu() {
        let menu = NSMenu()

        let toggle = NSMenuItem(
            title: store.isRunning ? "Stop Working" : "Start Working",
            action: #selector(toggleTimer),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        let auto = NSMenuItem(title: "Auto Clock-In", action: #selector(toggleAutoClockIn), keyEquivalent: "")
        auto.target = self
        auto.state = settings.autoClockIn ? .on : .off
        menu.addItem(auto)

        menu.addItem(.separator())

        let open = NSMenuItem(title: "Open Work Timer", action: #selector(openPopover), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let dashboardItem = NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "")
        dashboardItem.target = self
        menu.addItem(dashboardItem)

        let quit = NSMenuItem(title: "Quit Work Timer", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleTimer() { tracker.toggle() }
    @objc private func toggleAutoClockIn() { settings.autoClockIn.toggle() }
    @objc private func openPopover() { showPopover() }
    @objc private func openDashboard() { dashboard.show() }
    @objc private func quit() { NSApp.terminate(nil) }
}
