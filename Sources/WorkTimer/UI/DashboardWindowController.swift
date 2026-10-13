import AppKit
import SwiftUI

/// The dashboard window. While it's open the app shows in the Dock and the app
/// switcher, so the window can't get lost behind others.
final class DashboardWindowController: NSObject, NSWindowDelegate {
    private let model = DashboardModel()
    private let makeView: (DashboardModel) -> DashboardView
    private var window: NSWindow?

    init(log: WorkLog, store: SessionStore, settings: AppSettings) {
        makeView = { DashboardView(log: log, store: store, settings: settings, model: $0) }
    }

    func show(settings showSettings: Bool = false) {
        let window = window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if showSettings {
            // Present once the window is on screen so the popover has an anchor.
            DispatchQueue.main.async { self.model.showSettings = true }
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Work Timer"
        window.contentViewController = NSHostingController(rootView: makeView(model))
        window.setContentSize(NSSize(width: 780, height: 640))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("Dashboard")
        if !window.setFrameUsingName("Dashboard") { window.center() }
        return window
    }

    #if DEBUG
    func debugConfigure(grouping: String?, period: String?, step: String?, filter: String?) {
        show()
        if let filter { model.filter = Worker(rawValue: filter).map { .worker($0) } ?? .project(filter) }
        if let grouping, let value = DashboardModel.Grouping(rawValue: grouping) { model.grouping = value }
        if let period, let value = DashboardModel.Period(rawValue: period) { model.period = value }
        if let step, let value = Int(step) { model.step(value) }
    }
    #endif

    func windowWillClose(_ notification: Notification) {
        model.showSettings = false
        NSApp.setActivationPolicy(.accessory)
    }
}
