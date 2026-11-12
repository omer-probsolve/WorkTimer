import XCTest
@testable import WorkTimerCore

final class AgentSyncTests: XCTestCase {
    private let session = "11111111-1111-4111-8111-111111111111"
    private let receiver = "22222222-2222-4222-8222-222222222222"
    private let origin = "33333333-3333-4333-8333-333333333333"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func segment(open: Bool = false) -> AgentSegment {
        AgentSegment(worker: .codex, sessionID: session, project: "WorkTimer", source: "Codex app",
                     span: Span(start: now.addingTimeInterval(-60), end: now), open: open)
    }
    private func request(_ snapshots: [AgentSnapshot] = []) -> SyncRequest {
        SyncRequest(receiverID: receiver, token: "test-only", originID: origin, sentAt: now,
                    snapshots: snapshots, live: [])
    }

    func testOfflineHistorySurvivesSourceDeletionAndRestart() throws {
        var history = CollectorHistory()
        history.collect([segment()], at: now)
        history.collect([], at: now.addingTimeInterval(100))
        let restored = try AgentSync.decode(CollectorHistory.self, from: AgentSync.encode(history))
        XCTAssertEqual(restored.sessions.count, 1)
        XCTAssertEqual(restored.pending.count, 1)
        XCTAssertEqual(restored.originID, history.originID)
    }

    func testUpdateReplacesEarlierSnapshotAndIncrementsRevision() {
        var history = CollectorHistory()
        history.collect([segment(open: true)], at: now)
        history.collect([segment(open: true)], at: now.addingTimeInterval(10))
        XCTAssertEqual(history.sessions.count, 1)
        XCTAssertEqual(history.sessions.values.first?.revision, 2)
        XCTAssertEqual(history.sessions.values.first?.segments.first?.span.duration, 70)
    }

    func testStaleTurnDoesNotKeepGrowing() {
        var history = CollectorHistory()
        history.collect([segment(open: true)], at: now.addingTimeInterval(10000))
        XCTAssertEqual(history.sessions.values.first?.segments.first?.span.duration, 60)
        XCTAssertEqual(history.sessions.values.first?.segments.first?.open, false)
    }

    func testLostAcknowledgementAndOutOfOrderDeliveryAreIdempotent() throws {
        var store = ImportedHistory()
        let old = AgentSnapshot(key: AgentSync.key(segment()), revision: 1, segments: [segment()])
        var newer = old; newer.revision = 2; newer.segments[0].span.end = now.addingTimeInterval(20)
        _ = try store.accept(request([newer]), receiverID: receiver)
        _ = try store.accept(request([newer]), receiverID: receiver)
        _ = try store.accept(request([old]), receiverID: receiver)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions[old.key], newer)
    }

    func testConflictingSameRevisionIsRejected() throws {
        var store = ImportedHistory()
        var snapshot = AgentSnapshot(key: AgentSync.key(segment()), revision: 1, segments: [segment()])
        _ = try store.accept(request([snapshot]), receiverID: receiver)
        snapshot.segments[0].span.end = now.addingTimeInterval(10)
        XCTAssertThrowsError(try store.accept(request([snapshot]), receiverID: receiver))
    }

    func testAcknowledgingOldRevisionDoesNotDropNewOutboxEntry() throws {
        var history = CollectorHistory()
        history.collect([segment(open: true)], at: now)
        let sent = try history.batch()
        var imported = ImportedHistory()
        let ack = try imported.accept(request(sent), receiverID: receiver)
        history.collect([segment(open: true)], at: now.addingTimeInterval(10))
        try history.acknowledge(ack, sent: sent, receiverID: receiver)
        XCTAssertEqual(history.pending.count, 1)
    }

    func testReceiverRestartRequestsFullReplayIncludingAcknowledgedHistory() throws {
        var history = CollectorHistory()
        history.collect([segment()], at: now)
        let batch = try history.batch()
        var first = ImportedHistory()
        try history.acknowledge(first.accept(request(batch), receiverID: receiver), sent: batch, receiverID: receiver)
        XCTAssertTrue(history.pending.isEmpty)
        var restoredMac = ImportedHistory()
        let heartbeatAck = try restoredMac.accept(request(), receiverID: receiver)
        try history.acknowledge(heartbeatAck, sent: [], receiverID: receiver)
        XCTAssertEqual(history.pending.count, 1)
    }

    func testForeignDeviceCannotReplaceAuthoritativeOrigin() throws {
        var store = ImportedHistory()
        _ = try store.accept(request(), receiverID: receiver)
        var foreign = request(); foreign.originID = UUID().uuidString
        XCTAssertThrowsError(try store.accept(foreign, receiverID: receiver))
    }

    func testMirroredNativeTranscriptCountsOnce() throws {
        var store = ImportedHistory()
        let snapshot = AgentSnapshot(key: AgentSync.key(segment()), revision: 1, segments: [segment()])
        _ = try store.accept(request([snapshot]), receiverID: receiver)
        XCTAssertEqual(ImportedHistory.merge(local: [segment()], imported: store.segments()).count, 1)
    }

    func testMirroredFilesOnCollectorCountOnce() {
        var history = CollectorHistory()
        history.collect([segment(), segment()], at: now)
        XCTAssertEqual(history.sessions.values.first?.segments.count, 1)
    }

    func testLeaseExpiresWithoutAddingDurableTimeAndOldHistoryIsVisible() throws {
        var store = ImportedHistory()
        let snapshot = AgentSnapshot(key: AgentSync.key(segment()), revision: 1, segments: [segment(open: true)])
        _ = try store.accept(request([snapshot]), receiverID: receiver)
        let values = store.segments(leases: [snapshot.key: now.addingTimeInterval(20)])
        let metrics = WorkMetrics(log: SessionLog(), segments: values, trackingStart: now.addingTimeInterval(100))
        XCTAssertEqual(metrics.running(now: now.addingTimeInterval(10)).count, 1)
        XCTAssertTrue(metrics.running(now: now.addingTimeInterval(21)).isEmpty)
        XCTAssertEqual(metrics.agentSegments(now: now.addingTimeInterval(21)).first?.span.duration, 60)
        let restarted = try AgentSync.decode(ImportedHistory.self, from: AgentSync.encode(store))
        XCTAssertTrue(WorkMetrics(log: SessionLog(), segments: restarted.segments(), trackingStart: now).running(now: now).isEmpty)
    }

    func testInvalidSnapshotsCannotEnterHistory() {
        var snapshot = AgentSnapshot(key: "wrong-key", revision: 1, segments: [segment()])
        XCTAssertThrowsError(try snapshot.validate())
        snapshot.key = AgentSync.key(segment()); snapshot.segments[0].span.end = now.addingTimeInterval(-100)
        XCTAssertThrowsError(try snapshot.validate())
    }

    func testWindowsProjectPathsAndRootDoNotLoop() {
        XCTAssertEqual(ProjectResolver.name(for: "C:\\missing\\MyProject"), "MyProject")
        XCTAssertEqual(ProjectResolver.name(for: "C:\\missing\\Repo\\.claude\\worktrees\\branch"), "Repo")
        XCTAssertFalse(ProjectResolver.name(for: "C:\\").isEmpty)
    }

    func testTranscriptRootsHonorOverrides() {
        let scanner = TranscriptScanner(home: "/unused", cacheURL: URL(fileURLWithPath: "/unused-cache"), cutoff: .distantPast,
                                        environment: ["CLAUDE_CONFIG_DIR": "/custom-claude", "CODEX_HOME": "/custom-codex"])
        XCTAssertTrue(scanner.claudeRoot.replacingOccurrences(of: "\\", with: "/").hasSuffix("/custom-claude/projects"))
        XCTAssertEqual(scanner.codexRoots.count, 2)
        XCTAssertTrue(scanner.codexRoots.last!.hasSuffix("archived_sessions"))
    }

    func testAtomicPersistenceRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.json")
        var history = CollectorHistory(); history.collect([segment()], at: now)
        try AgentSync.save(history, to: file)
        let decoded = try AgentSync.decode(CollectorHistory.self, from: Data(contentsOf: file))
        XCTAssertEqual(decoded.sessions, history.sessions)
    }
}
