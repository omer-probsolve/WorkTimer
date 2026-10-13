import Foundation

/// Turns an agent's working directory into a project name: the git repository it
/// belongs to, so a worktree counts under its main repo.
package enum ProjectResolver {
    private static var cache: [String: String] = [:]
    private static let lock = NSLock()

    package static func name(for cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "Unknown" }
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[cwd] { return cached }
        let name = resolve(cwd)
        cache[cwd] = name
        return name
    }

    private static func resolve(_ cwd: String) -> String {
        let home = NSHomeDirectory()
        if let root = repositoryRoot(containing: cwd) {
            return (root as NSString).lastPathComponent
        }
        // The folder may be gone (a cleaned-up worktree); fall back to its path.
        for marker in ["/.claude/worktrees/", "/.git/worktrees/"] {
            if let range = cwd.range(of: marker) {
                return (String(cwd[..<range.lowerBound]) as NSString).lastPathComponent
            }
        }
        let codexWorktrees = home + "/.codex/worktrees/"
        if cwd.hasPrefix(codexWorktrees) {
            let parts = cwd.dropFirst(codexWorktrees.count).split(separator: "/")
            if parts.count >= 2 { return String(parts[1]) }
        }
        if cwd.hasPrefix(home + "/Documents/Codex/") { return "Codex chats" }
        if cwd == home { return "Home" }
        return (cwd as NSString).lastPathComponent
    }

    /// The main working tree of the git repository containing `path`, if any.
    private static func repositoryRoot(containing path: String) -> String? {
        let fm = FileManager.default
        var directory = path
        while directory != "/" && !directory.isEmpty {
            let git = directory + "/.git"
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: git, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return directory }
                // A worktree: `.git` is a file saying "gitdir: <repo>/.git/worktrees/<name>".
                if let contents = try? String(contentsOfFile: git, encoding: .utf8),
                   let line = contents.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
                    let gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    if let range = gitdir.range(of: "/.git/") {
                        return String(gitdir[..<range.lowerBound])
                    }
                }
                return directory
            }
            directory = (directory as NSString).deletingLastPathComponent
        }
        return nil
    }
}
