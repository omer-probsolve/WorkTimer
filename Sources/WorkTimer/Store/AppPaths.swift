import Foundation

enum AppPaths {
    /// ~/Library/Application Support/WorkTimer, or `WORKTIMER_DATA_DIR` when set —
    /// handy for running a development build next to the installed app.
    static let dataDirectory: URL = {
        if let override = ProcessInfo.processInfo.environment["WORKTIMER_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("WorkTimer", isDirectory: true)
    }()
}
