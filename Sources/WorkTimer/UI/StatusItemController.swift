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
    /// What the menu bar item shows. A host draws it in its own item.
    struct Appearance {
        var image: NSImage?
        var title: NSAttributedString
        var toolTip: String
    }

    /// Nil when hosted: the host owns the menu bar item.
    private let statusItem: NSStatusItem?
    /// When hosted, the host's menu bar button, for placing the panel under it.
    private let hostButton: (() -> NSStatusBarButton?)?
    /// When hosted, receives what the menu bar item should show.
    private let onAppearance: ((Appearance) -> Void)?
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

    /// Pass `hostButton` and `onAppearance` to run inside a host that owns the menu
    /// bar item; leave them out to show Work Timer's own item.
    init(
        log: WorkLog,
        settings: AppSettings,
        tracker: TimeTracker,
        dashboard: DashboardWindowController,
        hostButton: (() -> NSStatusBarButton?)? = nil,
        onAppearance: ((Appearance) -> Void)? = nil
    ) {
        self.log = log
        self.store = log.store
        self.settings = settings
        self.tracker = tracker
        self.dashboard = dashboard
        self.hostButton = hostButton
        self.onAppearance = onAppearance
        self.statusItem = onAppearance == nil
            ? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            : nil
        super.init()

        if let button = statusItem?.button {
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
        if let button = menuBarButton, let anchor = onScreenFrame(of: button),
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

    /// The menu bar button the panel hangs from: ours, or the host's.
    private var menuBarButton: NSStatusBarButton? {
        statusItem?.button ?? hostButton?()
    }

    private func refresh() {
        guard let button = menuBarButton else { return }
        let appearance = currentAppearance(button)
        if let onAppearance {
            onAppearance(appearance)
            return
        }
        if button.image?.name() != appearance.image?.name() {
            button.image = appearance.image
        }
        if appearance.title.length > 0 {
            button.attributedTitle = appearance.title
        } else if !button.title.isEmpty {
            button.title = ""
        }
        button.toolTip = appearance.toolTip
    }

    private func currentAppearance(_ button: NSStatusBarButton) -> Appearance {
        let now = Date()
        let metrics = log.metrics
        let sessionStart = metrics.currentSessionStart(now: now)
        let running = sessionStart != nil
        let agentSessions = metrics.running(now: now).count
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
        image?.setName(symbol)

        let clock = sessionStart.map { Format.clock(now.timeIntervalSince($0), seconds: settings.showSecondsInMenuBar) }
        let iconOnly = settings.iconOnlyOnNotchedScreens && menuBarScreenHasNotch(button)
        let title = NSMutableAttributedString()
        if let clock, !iconOnly {
            let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            title.append(NSAttributedString(string: " " + clock, attributes: [.font: font]))
            // Agent sessions running across Claude and Codex, dimmed so it doesn't
            // read as part of the time.
            if agentSessions > 0 {
                title.append(NSAttributedString(string: " · \(agentSessions)", attributes: [
                    .font: font, .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
        }

        let shortcut = settings.togglePanelShortcut.map { " — \($0.displayString)" } ?? ""
        let status = store.isRunning ? "Work Timer: tracking" : running ? "Work Timer: an agent is working" : settings.autoClockIn ? "Work Timer: not tracking" : "Work Timer: auto clock-in off"
        let agents = agentSessions > 0 ? " · \(agentSessions) agent session\(agentSessions == 1 ? "" : "s") running" : ""
        // With the title hidden, the tooltip is where the time can still be read.
        let time = iconOnly ? clock.map { " · \($0)" } ?? "" : ""
        return Appearance(image: image, title: title, toolTip: status + time + agents + shortcut)
    }

    /// Whether the menu bar the item sits in is on a screen with a notch. An item
    /// that didn't fit beside the notch has no screen, so fall back to the screen
    /// under the pointer, which is the one whose menu bar the user is looking at.
    private func menuBarScreenHasNotch(_ button: NSStatusBarButton) -> Bool {
        let screen = button.window?.screen
            ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        return (screen?.safeAreaInsets.top ?? 0) > 0
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
        guard let statusItem else { return }
        let menu = NSMenu()
        menuItems(includeQuit: true).forEach(menu.addItem)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// The quick menu's items, also shown in a host's menu (without Quit).
    func menuItems(includeQuit: Bool) -> [NSMenuItem] {
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

        if includeQuit {
            let quit = NSMenuItem(title: "Quit Work Timer", action: #selector(quit), keyEquivalent: "q")
            quit.target = self
            menu.addItem(quit)
        }

        let items = menu.items
        menu.removeAllItems()
        return items
    }

    @objc private func toggleTimer() { tracker.toggle() }
    @objc private func toggleAutoClockIn() { settings.autoClockIn.toggle() }
    @objc private func openPopover() { showPopover() }
    @objc private func openDashboard() { dashboard.show() }
    @objc private func quit() { NSApp.terminate(nil) }
}
