import CoreServices
import Foundation
import WorkTimerCore

/// Publishes the agents' work to the UI. `TranscriptScanner` does the reading;
/// this runs it on a background queue, rescans when FSEvents reports changes, and
/// checks on background tasks the agents are waiting for.
final class AgentMonitor: ObservableObject {
    @Published private(set) var segments: [AgentSegment] = []
    /// False until the first scan finishes.
    @Published private(set) var loaded = false

    private let queue = DispatchQueue(label: "WorkTimer.AgentMonitor", qos: .utility)
    private let scanner: TranscriptScanner
    private var stream: FSEventStreamRef?
    private let probe = TaskProbe()
    private var taskActivity: [String: TaskActivity] = [:]
    private var taskTimer: DispatchSourceTimer?

    /// How often background tasks are checked on, while there are any.
    private static let taskCheckInterval: TimeInterval = 10

    /// - Parameter cutoff: transcripts last changed before this aren't read.
    init(cutoff: Date) {
        scanner = TranscriptScanner(
            home: AppPaths.transcriptsHome,
            cacheURL: AppPaths.dataDirectory.appendingPathComponent("agent-cache.json"),
            cutoff: cutoff
        )
    }

    func start() {
        queue.async { [self] in
            scanner.loadCache()
            scan(force: true)
        }
        startWatching()
        startCheckingTasks()
    }

    /// Read older transcripts too, e.g. after a session was added to an earlier day.
    func extendCutoff(to date: Date) {
        queue.async { [self] in
            guard date < scanner.cutoff else { return }
            scanner.cutoff = date
            scan()
        }
    }

    // MARK: - Scanning

    /// On the queue: reads new lines and publishes the result if it changed.
    private func scan(force: Bool = false) {
        guard scanner.scan() || force else { return }
        publish()
    }

    /// On the queue: publishes the segments as they stand.
    private func publish() {
        let result = scanner.segments(taskActivity: taskActivity)
        DispatchQueue.main.async { [self] in
            if segments != result { segments = result }
            if !loaded { loaded = true }
        }
    }

    // MARK: - Background tasks

    private func startCheckingTasks() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.taskCheckInterval, repeating: Self.taskCheckInterval, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.checkTasks() }
        timer.resume()
        taskTimer = timer
    }

    /// On the queue: asks the probe what pending background tasks are doing, and
    /// republishes when that changes.
    private func checkTasks() {
        let tasks = scanner.pendingTasks(now: Date())
        let activity = tasks.isEmpty && taskActivity.isEmpty ? [:] : probe.activity(of: tasks)
        guard activity != taskActivity else { return }
        taskActivity = activity
        publish()
    }

    // MARK: - File watching

    /// How long FSEvents gathers changes before reporting them. It's the only
    /// batching: agents write constantly, and a scan only stats the transcripts
    /// and reads new lines, so this is short enough that a new agent shows up
    /// almost at once.
    private static let latency: CFTimeInterval = 0.5

    private func startWatching() {
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            // The stream runs on `queue`, so scans never overlap.
            Unmanaged<AgentMonitor>.fromOpaque(info).takeUnretainedValue().scan()
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, scanner.watchedFolders as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }
}
