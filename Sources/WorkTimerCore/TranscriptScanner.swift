import Foundation

/// A stretch of time an agent spent working on one session.
package struct AgentSegment: Equatable, Codable {
    package var worker: Worker
    package var sessionID: String
    package var project: String
    package var source: String
    package var span: Span
    /// The session's turn is still open; if the agent is active, the segment
    /// really runs until now.
    package var open: Bool
    /// The agent is running a tool that didn't ask you anything, so it's still
    /// working through a long silence.
    package var notWaitingOnYou: Bool
    /// The agent's turn ended but it's waiting on a background task that's still
    /// working, so the session stays open (and `notWaitingOnYou`).
    package var waitingOnTask: Bool
    /// Imported activity is live only while its independently refreshed lease lasts.
    package var liveUntil: Date? = nil
    package var imported: Bool = false

    package init(worker: Worker, sessionID: String, project: String, source: String, span: Span, open: Bool,
                 notWaitingOnYou: Bool = false, waitingOnTask: Bool = false) {
        self.worker = worker
        self.sessionID = sessionID
        self.project = project
        self.source = source
        self.span = span
        self.open = open || waitingOnTask
        self.notWaitingOnYou = notWaitingOnYou || waitingOnTask
        self.waitingOnTask = waitingOnTask
    }

    /// How long an open segment can go quiet and still be the agent working.
    package var maxSilence: TimeInterval {
        notWaitingOnYou ? AgentLogState.maxToolRun : AgentLogState.maxSilence
    }
}

/// Finds Claude Code and Codex transcripts and turns them into work segments.
///
/// Reading is incremental and the parse state is cached on disk, so the
/// (multi-gigabyte) logs are only read once. Not thread-safe: call it from one
/// queue. Watching for changes is the platform's job — call `scan()` when the
/// `watchedFolders` change.
package final class TranscriptScanner {
    /// Transcripts last changed before this aren't read.
    package var cutoff: Date

    package let claudeRoot: String
    package let codexRoots: [String]
    package var watchedFolders: [String] { [claudeRoot] + codexRoots }

    private let cacheURL: URL
    private var states: [String: AgentLogState] = [:]

    /// Bumping it re-reads every transcript, so a change to the rules applies to
    /// past days too.
    private static let cacheVersion = 3
    private static let chunkSize = 8 << 20

    package init(home: String = NSHomeDirectory(), cacheURL: URL, cutoff: Date,
                 environment: [String: String] = ProcessInfo.processInfo.environment) {
        let claude = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.claude"
        let codex = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.codex"
        claudeRoot = URL(fileURLWithPath: claude).appendingPathComponent("projects").path
        codexRoots = ["sessions", "archived_sessions"].map { URL(fileURLWithPath: codex).appendingPathComponent($0).path }
        self.cacheURL = cacheURL
        self.cutoff = cutoff
    }

    // MARK: - Scanning

    /// Reads whatever was added to the transcripts since the last scan. Returns
    /// whether anything changed.
    @discardableResult
    package func scan() -> Bool {
        var seen = Set<String>()
        var changed = false
        for (path, worker) in transcriptFiles() {
            seen.insert(path)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  let modified = attributes[.modificationDate] as? Date else { continue }
            if modified < cutoff, states[path] == nil { continue }

            var state = states[path] ?? AgentLogState(worker: worker)
            if state.fileSize == size && state.modified == modified { continue }
            if size < state.offset { state = AgentLogState(worker: worker) }
            read(path, into: &state)
            state.fileSize = size
            state.modified = modified
            states[path] = state
            changed = true
        }
        for path in states.keys where !seen.contains(path) {
            states[path] = nil
            changed = true
        }
        if changed { saveCache() }
        return changed
    }

    /// Background tasks of sessions whose turn ended recently, for the platform
    /// to check on: whether they're still working decides if the agent is.
    package func pendingTasks(now: Date) -> [BackgroundTask] {
        states.values.flatMap { state -> [BackgroundTask] in
            guard !state.ignored, !state.turnOpen, let last = state.lastActivity,
                  now.timeIntervalSince(last) <= AgentLogState.maxToolRun else { return [] }
            return state.backgroundTasks.values.filter { $0.outputFile != nil }
        }
    }

    /// Every agent's work so far, oldest first.
    /// - Parameter taskActivity: what each pending background task is doing, by ID.
    package func segments(taskActivity: [String: TaskActivity] = [:]) -> [AgentSegment] {
        var result: [AgentSegment] = []
        for state in states.values where !state.ignored {
            let waiting = !state.turnOpen && state.backgroundTasks.values.contains { task in
                taskActivity[task.id].map(task.keepsAgentWorking) ?? false
            }
            let project = ProjectResolver.name(for: state.cwd)
            guard let session = state.sessionID else { continue }
            let source = state.source ?? "Unknown"
            let spans = state.allSegments
            for (index, span) in spans.enumerated() {
                let last = index == spans.count - 1
                result.append(AgentSegment(
                    worker: state.worker, sessionID: session, project: project, source: source,
                    span: span, open: state.isLive && last, notWaitingOnYou: state.notWaitingOnYou && last,
                    waitingOnTask: waiting && last
                ))
            }
        }
        return result.sorted { $0.span.start < $1.span.start }
    }

    private func transcriptFiles() -> [(String, Worker)] {
        let fm = FileManager.default
        var files: [(String, Worker)] = []
        // Claude: one level of project folders; deeper files are subagents.
        for project in (try? fm.contentsOfDirectory(atPath: claudeRoot)) ?? [] {
            let directory = claudeRoot + "/" + project
            for name in (try? fm.contentsOfDirectory(atPath: directory)) ?? [] where name.hasSuffix(".jsonl") {
                files.append((directory + "/" + name, .claude))
            }
        }
        for root in codexRoots {
            guard let enumerator = fm.enumerator(atPath: root) else { continue }
            while let relative = enumerator.nextObject() as? String {
                if relative.hasSuffix(".jsonl") { files.append((root + "/" + relative, .codex)) }
            }
        }
        return files
    }

    /// Reads complete lines from the state's offset onward.
    private func read(_ path: String, into state: inout AgentLogState) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: state.offset) } catch { return }

        var pending = Data()
        while !state.ignored {
            let chunk = Self.drainingMemory { (try? handle.read(upToCount: Self.chunkSize)) ?? nil }
            guard let chunk, !chunk.isEmpty else { break }
            pending.append(chunk)
            let consumed = pending.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                var start = 0
                while start < raw.count, let newline = memchr(base + start, 0x0A, raw.count - start) {
                    let end = base.distance(to: UnsafeRawPointer(newline))
                    let line = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + start),
                                    count: end - start, deallocator: .none)
                    state.consume(line: line)
                    start = end + 1
                }
                return start
            }
            state.offset += UInt64(consumed)
            pending.removeFirst(consumed)
        }
    }

    /// Frees temporary objects after each chunk on Apple platforms, where file
    /// reads produce autoreleased buffers.
    private static func drainingMemory<T>(_ body: () -> T) -> T {
        #if canImport(ObjectiveC)
        return autoreleasepool(invoking: body)
        #else
        return body()
        #endif
    }

    // MARK: - Cache

    private struct Cache: Codable {
        var version: Int
        var states: [String: AgentLogState]
    }

    /// Restores the parse state saved by an earlier run.
    package func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let cache = try? decoder.decode(Cache.self, from: data), cache.version == Self.cacheVersion else { return }
        states = cache.states
    }

    private func saveCache() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(Cache(version: Self.cacheVersion, states: states)) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
