import CoreServices
import Foundation

/// A stretch of time an agent spent working on one session.
struct AgentSegment: Equatable {
    var worker: Worker
    var sessionID: String
    var project: String
    var source: String
    var span: Span
    /// The session's turn is still open; if the agent is active, the segment
    /// really runs until now.
    var open: Bool
}

/// Watches Claude Code and Codex transcripts and turns them into work segments.
///
/// Transcripts are read incrementally on a background queue and the parse state
/// is cached on disk, so the (multi-gigabyte) logs are only read once.
final class AgentMonitor: ObservableObject {
    @Published private(set) var segments: [AgentSegment] = []
    /// False until the first scan finishes.
    @Published private(set) var loaded = false

    private let queue = DispatchQueue(label: "WorkTimer.AgentMonitor", qos: .utility)
    private var states: [String: AgentLogState] = [:]
    private var cutoff: Date
    private var stream: FSEventStreamRef?
    private var scanPending = false
    private let cacheURL: URL

    private static let cacheVersion = 1
    private static let chunkSize = 8 << 20

    private let claudeRoot = NSHomeDirectory() + "/.claude/projects"
    private let codexRoots = [NSHomeDirectory() + "/.codex/sessions", NSHomeDirectory() + "/.codex/archived_sessions"]

    /// - Parameter cutoff: transcripts last changed before this aren't read.
    init(cutoff: Date) {
        self.cutoff = cutoff
        cacheURL = AppPaths.dataDirectory.appendingPathComponent("agent-cache.json")
    }

    func start() {
        queue.async { [self] in
            loadCache()
            scan()
        }
        startWatching()
    }

    /// Read older transcripts too, e.g. after a session was added to an earlier day.
    func extendCutoff(to date: Date) {
        queue.async { [self] in
            guard date < cutoff else { return }
            cutoff = date
            scan()
        }
    }

    // MARK: - Scanning

    private func scheduleScan() {
        queue.async { [self] in
            guard !scanPending else { return }
            scanPending = true
            queue.asyncAfter(deadline: .now() + 1) { [self] in
                scanPending = false
                scan()
            }
        }
    }

    private func scan() {
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
        publish(changed: changed)
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
            let chunk = autoreleasepool { (try? handle.read(upToCount: Self.chunkSize)) ?? nil }
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

    private func publish(changed: Bool) {
        guard changed || !loadedOnQueue else { return }
        loadedOnQueue = true
        var result: [AgentSegment] = []
        for state in states.values where !state.ignored {
            let project = ProjectResolver.name(for: state.cwd)
            let session = state.sessionID ?? UUID().uuidString
            let source = state.source ?? "Unknown"
            let spans = state.allSegments
            for (index, span) in spans.enumerated() {
                result.append(AgentSegment(
                    worker: state.worker, sessionID: session, project: project, source: source,
                    span: span, open: state.isLive && index == spans.count - 1
                ))
            }
        }
        result.sort { $0.span.start < $1.span.start }
        DispatchQueue.main.async { [self] in
            if segments != result { segments = result }
            if !loaded { loaded = true }
        }
    }

    private var loadedOnQueue = false

    // MARK: - File watching

    private func startWatching() {
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<AgentMonitor>.fromOpaque(info).takeUnretainedValue().scheduleScan()
        }
        let paths = ([claudeRoot] + codexRoots) as CFArray
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    // MARK: - Cache

    private struct Cache: Codable {
        var version: Int
        var states: [String: AgentLogState]
    }

    private func loadCache() {
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
