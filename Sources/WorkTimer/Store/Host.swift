import AppKit

/// Whether Work Timer runs as its own app or inside a host such as Toolbelt, and
/// where its preferences live in either case.
enum Host {
    /// The standalone app's bundle identifier. Preferences always live in this
    /// domain, so the standalone app and a host share them.
    static let bundleID = "com.omershaashua.worktimer"

    /// Set by `WorkTimerController` before anything else starts.
    static var isHosted = false

    /// Work Timer's preferences: `.standard` in the standalone app, the standalone
    /// app's domain when hosted (`UserDefaults` refuses a suite named after the
    /// running app's own bundle ID).
    static let defaults: UserDefaults = {
        if Bundle.main.bundleIdentifier == bundleID { return .standard }
        return UserDefaults(suiteName: bundleID) ?? .standard
    }()
}

/// Keeps the standalone app from running next to a host that already runs Work
/// Timer: two copies would both write sessions.json and claim the same shortcuts.
public enum HostCheck {
    /// Toolbelt's bundle identifier.
    public static let toolbeltBundleID = "com.omershaashua.toolbelt"

    /// If Toolbelt is running, says so and quits. Returns true when quitting.
    @discardableResult
    public static func quitIfHostIsRunning(appName: String) -> Bool {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: toolbeltBundleID).isEmpty else {
            return false
        }
        let alert = NSAlert()
        alert.messageText = "\(appName) is already running in Toolbelt"
        alert.informativeText = "Use it from the Toolbelt menu bar icon. Running both would make them overwrite each other's data, so this copy will quit."
        alert.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        NSApp.terminate(nil)
        return true
    }
}
