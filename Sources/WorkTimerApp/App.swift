import AppKit
import WorkTimerKit

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
    private let controller = WorkTimerController(hosted: false)

    func applicationDidFinishLaunching(_ notification: Notification) {
        if HostCheck.quitIfHostIsRunning(appName: "Work Timer") { return }
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    /// Opening the app again from /Applications or Spotlight shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.showWindow()
        return false
    }
}
