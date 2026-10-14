import CoreServices
import Foundation
import WorkTimerCore

/// Publishes the agents' work to the UI. `TranscriptScanner` does the reading;
/// this runs it on a background queue and rescans when FSEvents reports changes.
final class AgentMonitor: ObservableObject {
    @Published private(set) var segments: [AgentSegment] = []
    /// False until the first scan finishes.
    @Published private(set) var loaded = false

    private let queue = DispatchQueue(label: "WorkTimer.AgentMonitor", qos: .utility)
    private let scanner: TranscriptScanner
    private var stream: FSEventStreamRef?
    private var scanPending = false

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

    /// On the queue: reads new lines and publishes the result if it changed.
    private func scan(force: Bool = false) {
        guard scanner.scan() || force else { return }
        let result = scanner.segments()
        DispatchQueue.main.async { [self] in
            if segments != result { segments = result }
            if !loaded { loaded = true }
        }
    }

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
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, scanner.watchedFolders as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }
}
