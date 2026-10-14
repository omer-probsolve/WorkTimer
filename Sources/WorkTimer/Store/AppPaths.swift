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

    /// The home folder transcripts are read from (`~/.claude`, `~/.codex`), or
    /// `WORKTIMER_HOME` when set — for running a build against demo transcripts.
    static let transcriptsHome: String = {
        if let override = ProcessInfo.processInfo.environment["WORKTIMER_HOME"], !override.isEmpty {
            return override
        }
        return NSHomeDirectory()
    }()
}
