import Foundation
import WorkTimerCore
import WorkTimerWindows

enum CollectorError: Error { case usage, alreadyRunning, network, unsupported }

/// A slow DNS/TLS exchange must never hold up local collection.
final class Delivery {
    private let lock = NSLock()
    private var result: (Result<SyncAcknowledgement, Error>, [AgentSnapshot])?
    private(set) var busy = false
    func start(_ request: SyncRequest, pairing: SyncPairing) {
        busy = true
        DispatchQueue.global(qos: .utility).async { [self] in
            let value = Result { try deliver(request, pairing: pairing) }
            lock.lock(); result = (value, request.snapshots); lock.unlock()
        }
    }
    func take() -> (Result<SyncAcknowledgement, Error>, [AgentSnapshot])? {
        lock.lock(); defer { lock.unlock() }
        guard let value = result else { return nil }
        result = nil; busy = false
        return value
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

func run() throws {
    #if !os(Windows)
    throw CollectorError.unsupported
    #endif
    if arguments.contains("--help") {
        print("WorkTimerCollector [--once | --status | --pair <Mac pairing file>] [--data-dir <folder>] [--home <folder>]")
        return
    }
    let environment = ProcessInfo.processInfo.environment
    let base = option("--data-dir") ?? environment["WORKTIMER_DATA_DIR"]
        ?? URL(fileURLWithPath: environment["LOCALAPPDATA"] ?? NSHomeDirectory()).appendingPathComponent("WorkTimer").path
    let directory = URL(fileURLWithPath: base, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let historyURL = directory.appendingPathComponent("collector-history.json")
    let pairingURL = directory.appendingPathComponent("pairing.json")
    var history = FileManager.default.fileExists(atPath: historyURL.path)
        ? try AgentSync.decode(CollectorHistory.self, from: Data(contentsOf: historyURL)) : CollectorHistory()
    guard history.version == AgentSync.version else { throw AgentSync.Failure.incompatibleVersion }
    if arguments.contains("--status") {
        print("Local history: \(history.sessions.count) sessions; \(history.pending.count) awaiting delivery. Paired: \(FileManager.default.fileExists(atPath: pairingURL.path)).")
        return
    }
    guard wt_lock(directory.appendingPathComponent("collector.lock").path) != 0 else { throw CollectorError.alreadyRunning }
    if let path = option("--pair") {
        var pairing = try AgentSync.decode(SyncPairing.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        if let host = option("--host") { pairing.host = host }
        try pairing.validate()
        try AgentSync.save(pairing, to: pairingURL)
        history.receiverEpoch = nil
        history.pending.formUnion(history.sessions.keys)
        try AgentSync.save(history, to: historyURL)
        print("Paired. Local history will be replayed when the Mac is reachable on the LAN.")
        return
    }
    let scanner = TranscriptScanner(home: option("--home") ?? environment["WORKTIMER_HOME"] ?? NSHomeDirectory(),
                                    cacheURL: directory.appendingPathComponent("collector-cache.json"), cutoff: .distantPast)
    scanner.loadCache()
    var watched = Set<String>()
    var pairing: SyncPairing?
    if FileManager.default.fileExists(atPath: pairingURL.path) {
        pairing = try AgentSync.decode(SyncPairing.self, from: Data(contentsOf: pairingURL))
        try pairing?.validate()
        wt_discovery_start(pairing!.receiverID)
    }
    var nextScan = Date.distantPast, nextDelivery = Date.distantPast
    var failures = 0
    let delivery = Delivery()
    var taskTracker = TaskActivityTracker()
    var taskWrites: [String: Date] = [:]
    repeat {
        let now = Date()
        if wt_take_changes() != 0 || now >= nextScan {
            scanner.scan()
            nextScan = now.addingTimeInterval(5)
        }
        for root in scanner.watchedFolders {
            let parent = URL(fileURLWithPath: root).deletingLastPathComponent().path
            if !watched.contains(parent), wt_watch(parent) != 0 { watched.insert(parent) }
        }
        // File writes are positive evidence; file existence alone cannot prove a Windows task is alive.
        var taskActivity: [String: TaskActivity] = [:]
        let tasks = scanner.pendingTasks(now: now)
        taskTracker.keep(only: Set(tasks.map(\.id)))
        for task in tasks {
            if let path = task.outputFile,
               let attributes = try? FileManager.default.attributesOfItem(atPath: path),
               let modified = attributes[.modificationDate] as? Date {
                let changed = taskWrites[task.id].map { modified > $0 } ?? false
                taskWrites[task.id] = modified
                let activity = taskTracker.update(task.id, worked: changed, at: now)
                taskActivity[task.id] = activity == .busy ? .busy : .gone
            } else { taskActivity[task.id] = taskTracker.update(task.id, worked: nil, at: now) }
        }
        let segments = scanner.segments(taskActivity: taskActivity)
        let previous = history.sessions
        history.collect(segments, at: now)
        if previous != history.sessions || !FileManager.default.fileExists(atPath: historyURL.path) {
            try AgentSync.save(history, to: historyURL)
        }
        if let pairing, let (result, sent) = delivery.take() {
            do {
                let ack = try result.get()
                try history.acknowledge(ack, sent: sent, receiverID: pairing.receiverID)
                try AgentSync.save(history, to: historyURL)
                failures = 0
                nextDelivery = now.addingTimeInterval(history.pending.isEmpty ? 5 : 0.2)
            } catch {
                failures = min(failures + 1, 7)
                nextDelivery = now.addingTimeInterval(min(60, pow(2, Double(failures))) + Double.random(in: 0...1))
                if failures == 1 { print("Mac unavailable or pairing could not be verified; activity remains saved locally.") }
            }
        }
        if let pairing, !delivery.busy, now >= nextDelivery {
            do {
                let batch = try history.batch()
                let live = Array(Set(segments.filter {
                    $0.open && now >= $0.span.end && now.timeIntervalSince($0.span.end) <= $0.maxSilence
                }.map(AgentSync.key)))
                let request = SyncRequest(receiverID: pairing.receiverID, token: pairing.token,
                                          originID: history.originID, sentAt: now, snapshots: batch, live: live)
                delivery.start(request, pairing: pairing)
            } catch {
                failures = min(failures + 1, 7)
                nextDelivery = now.addingTimeInterval(min(60, pow(2, Double(failures))) + Double.random(in: 0...1))
                if failures == 1 { print("Mac unavailable or pairing could not be verified; activity remains saved locally.") }
            }
        }
        if arguments.contains("--once") { break }
        Thread.sleep(forTimeInterval: 1)
    } while true
    print("Saved \(history.sessions.count) sessions locally; \(history.pending.count) awaiting delivery.")
}

func deliver(_ request: SyncRequest, pairing: SyncPairing) throws -> SyncAcknowledgement {
    var host = [CChar](repeating: 0, count: 256), discoveredPort: UInt16 = 0
    let discovered = wt_discovery_endpoint(&host, host.count, &discoveredPort) != 0
    var endpoints: [(String, UInt16)] = []
    if discovered { endpoints.append((String(cString: host), discoveredPort)) }
    endpoints.append((pairing.host, pairing.port))
    let body = try AgentSync.encode(request)
    guard body.count <= AgentSync.maxBody else { throw AgentSync.Failure.invalidSnapshot }
    for (hostname, port) in endpoints {
        var address = [CChar](repeating: 0, count: 64)
        guard wt_resolve_lan(hostname, &address, address.count) != 0 else { continue }
        var response = [UInt8](repeating: 0, count: 65536), count: UInt32 = 0
        let success = body.withUnsafeBytes { raw in
            wt_post(address, port, pairing.certificateSHA256,
                    raw.bindMemory(to: UInt8.self).baseAddress, UInt32(body.count), &response, UInt32(response.count), &count)
        }
        if success != 0 {
            return try AgentSync.decode(SyncAcknowledgement.self, from: Data(response.prefix(Int(count))))
        }
    }
    throw CollectorError.network
}

do { try run() }
catch {
    // Never print a request, token, transcript record, or an arbitrary parser error containing input.
    fputs("WorkTimerCollector stopped (\(type(of: error))). Local history was retained.\n", stderr)
    exit(1)
}
