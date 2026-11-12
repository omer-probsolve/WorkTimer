import Foundation

/// Versioned local storage and wire format. Only normalized timing metadata leaves the device.
package enum AgentSync {
    package static let version = 1
    package static let maxBody = 8 << 20
    package static let maxBatch = 32
    package static let lease: TimeInterval = 20

    package static func key(_ segment: AgentSegment) -> String { segment.worker.rawValue + ":" + segment.sessionID }

    package static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    package static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }

    /// An atomic replacement is the transaction boundary: history, revisions and outbox move together.
    package static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(value).write(to: url, options: .atomic)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
    }

    package enum Failure: Error { case incompatibleVersion, invalidSnapshot, foreignOrigin, invalidAcknowledgement }
}

package struct AgentSnapshot: Codable, Equatable {
    package var key: String
    package var revision: Int64
    package var segments: [AgentSegment]

    // Session metadata is sent once, so even very long transcripts fit bounded batches.
    private enum CodingKeys: String, CodingKey {
        case key, revision, worker, sessionID, project, source, intervals, open, notWaitingOnYou, waitingOnTask
    }
    package init(key: String, revision: Int64, segments: [AgentSegment]) {
        self.key = key; self.revision = revision; self.segments = segments
    }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        revision = try c.decode(Int64.self, forKey: .revision)
        let worker = try c.decode(Worker.self, forKey: .worker)
        let session = try c.decode(String.self, forKey: .sessionID)
        let project = try c.decode(String.self, forKey: .project)
        let source = try c.decode(String.self, forKey: .source)
        let spans = try c.decode([Span].self, forKey: .intervals)
        let open = try c.decode(Bool.self, forKey: .open)
        let tool = try c.decode(Bool.self, forKey: .notWaitingOnYou)
        let task = try c.decode(Bool.self, forKey: .waitingOnTask)
        segments = spans.enumerated().map { index, span in
            let last = index == spans.count - 1
            return AgentSegment(worker: worker, sessionID: session, project: project, source: source,
                                span: span, open: open && last, notWaitingOnYou: tool && last, waitingOnTask: task && last)
        }
    }
    package func encode(to encoder: Encoder) throws {
        guard let first = segments.first, let last = segments.last else { throw AgentSync.Failure.invalidSnapshot }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key); try c.encode(revision, forKey: .revision)
        try c.encode(first.worker, forKey: .worker); try c.encode(first.sessionID, forKey: .sessionID)
        try c.encode(first.project, forKey: .project); try c.encode(first.source, forKey: .source)
        try c.encode(segments.map(\.span), forKey: .intervals)
        try c.encode(last.open, forKey: .open); try c.encode(last.notWaitingOnYou, forKey: .notWaitingOnYou)
        try c.encode(last.waitingOnTask, forKey: .waitingOnTask)
    }

    package func validate() throws {
        guard revision > 0, !segments.isEmpty, segments.count <= 100_000,
              let first = segments.first, first.worker == .claude || first.worker == .codex,
              UUID(uuidString: first.sessionID) != nil, key == AgentSync.key(first),
              segments.allSatisfy({ AgentSync.key($0) == key && $0.span.start <= $0.span.end
                  && $0.span.start.timeIntervalSince1970.isFinite && $0.span.end.timeIntervalSince1970.isFinite
                  && $0.project.utf8.count <= 4096 && $0.source.utf8.count <= 4096
                  && $0.liveUntil == nil && !$0.imported }) else { throw AgentSync.Failure.invalidSnapshot }
    }
}

package struct SyncRequest: Codable {
    package var version = AgentSync.version
    package var receiverID: String
    package var token: String
    package var originID: String
    package var sentAt: Date
    package var snapshots: [AgentSnapshot]
    package var live: [String]

    package init(receiverID: String, token: String, originID: String, sentAt: Date,
                 snapshots: [AgentSnapshot], live: [String]) {
        self.receiverID = receiverID; self.token = token; self.originID = originID
        self.sentAt = sentAt; self.snapshots = snapshots; self.live = live
    }
}

package struct SyncAcknowledgement: Codable {
    package var version = AgentSync.version
    package var receiverID: String
    package var epoch: String
    package var revisions: [String: Int64]
}

/// Transfer this file explicitly from the Mac. Discovery never changes these trust anchors.
package struct SyncPairing: Codable {
    package var version = AgentSync.version
    package var receiverID: String
    package var host: String
    package var port: UInt16
    package var certificateSHA256: String
    package var token: String

    package init(receiverID: String, host: String, port: UInt16, certificateSHA256: String, token: String) {
        self.receiverID = receiverID; self.host = host; self.port = port
        self.certificateSHA256 = certificateSHA256; self.token = token
    }

    package func validate() throws {
        guard version == AgentSync.version, UUID(uuidString: receiverID) != nil,
              port > 0, !host.isEmpty, host.utf8.count < 256,
              certificateSHA256.count == 64, certificateSHA256.allSatisfy(\.isHexDigit),
              token.count >= 32, token.utf8.count <= 256 else { throw AgentSync.Failure.incompatibleVersion }
    }
}

package struct CollectorHistory: Codable {
    package var version = AgentSync.version
    package var originID = UUID().uuidString
    package var receiverEpoch: String?
    package var sessions: [String: AgentSnapshot] = [:]
    package var pending: Set<String> = []

    package init() {}

    /// Missing files do not delete history. Only an observed session can replace its earlier snapshot.
    package mutating func collect(_ segments: [AgentSegment], at now: Date) {
        let groups = Dictionary(grouping: segments, by: AgentSync.key)
        for (key, values) in groups {
            let measured = values.map { value -> AgentSegment in
                var value = value
                if value.open && now >= value.span.end && now.timeIntervalSince(value.span.end) <= value.maxSilence {
                    value.span.end = now
                } else { value.open = false; value.waitingOnTask = false }
                return value
            }.sorted { $0.span.start < $1.span.start }
            guard let latest = measured.last else { continue }
            var spans = measured.map(\.span).merged()
            if spans.isEmpty { spans = [latest.span] }
            let normalized = spans.enumerated().map { index, span -> AgentSegment in
                let last = index == spans.count - 1
                return AgentSegment(worker: latest.worker, sessionID: latest.sessionID, project: latest.project,
                                    source: latest.source, span: span, open: latest.open && last,
                                    notWaitingOnYou: latest.notWaitingOnYou && last, waitingOnTask: latest.waitingOnTask && last)
            }
            guard sessions[key]?.segments != normalized else { continue }
            let revision = (sessions[key]?.revision ?? 0) + 1
            sessions[key] = AgentSnapshot(key: key, revision: revision, segments: normalized)
            pending.insert(key)
        }
    }

    package func batch() throws -> [AgentSnapshot] {
        var result: [AgentSnapshot] = []
        var bytes = 0
        for key in pending.sorted() {
            guard let snapshot = sessions[key] else { continue }
            let size = try AgentSync.encode(snapshot).count
            guard size < AgentSync.maxBody - 65536 else { throw AgentSync.Failure.invalidSnapshot }
            if result.count >= AgentSync.maxBatch || bytes + size > AgentSync.maxBody - 65536 { break }
            result.append(snapshot)
            bytes += size
        }
        return result
    }

    package mutating func acknowledge(_ ack: SyncAcknowledgement, sent: [AgentSnapshot], receiverID: String) throws {
        guard ack.version == AgentSync.version, ack.receiverID == receiverID,
              UUID(uuidString: ack.epoch) != nil,
              ack.revisions.count == sent.count,
              sent.allSatisfy({ ack.revisions[$0.key] == $0.revision }) else {
            throw AgentSync.Failure.invalidAcknowledgement
        }
        if receiverEpoch != ack.epoch {
            pending.formUnion(sessions.keys)
            receiverEpoch = ack.epoch
        }
        for snapshot in sent where sessions[snapshot.key]?.revision == snapshot.revision { pending.remove(snapshot.key) }
    }
}

package struct ImportedHistory: Codable {
    package var version = AgentSync.version
    package var epoch = UUID().uuidString
    package var originID: String?
    package var sessions: [String: AgentSnapshot] = [:]

    package init() {}

    /// Mutate a copy, persist it, then publish/acknowledge. Failed commits cannot consume revisions.
    package mutating func accept(_ request: SyncRequest, receiverID: String) throws -> SyncAcknowledgement {
        guard request.version == AgentSync.version, request.receiverID == receiverID,
              UUID(uuidString: request.originID) != nil, request.snapshots.count <= AgentSync.maxBatch,
              request.live.count <= 4096, Set(request.snapshots.map(\.key)).count == request.snapshots.count else {
            throw AgentSync.Failure.invalidSnapshot
        }
        guard originID == nil || originID == request.originID else { throw AgentSync.Failure.foreignOrigin }
        for snapshot in request.snapshots { try snapshot.validate() }
        originID = request.originID
        for snapshot in request.snapshots {
            if let existing = sessions[snapshot.key] {
                if existing.revision == snapshot.revision && existing != snapshot { throw AgentSync.Failure.invalidSnapshot }
                if existing.revision >= snapshot.revision { continue }
            }
            sessions[snapshot.key] = snapshot
        }
        return SyncAcknowledgement(receiverID: receiverID, epoch: epoch,
                                   revisions: Dictionary(uniqueKeysWithValues: request.snapshots.map { ($0.key, $0.revision) }))
    }

    package func segments(leases: [String: Date] = [:]) -> [AgentSegment] {
        sessions.values.flatMap { snapshot in
            snapshot.segments.map { original in
                var value = original
                value.imported = true
                value.liveUntil = leases[snapshot.key] ?? .distantPast
                value.source += " · Windows"
                return value
            }
        }.sorted { $0.span.start < $1.span.start }
    }

    /// Canonical native identities suppress mirrored local transcripts without adding their intervals twice.
    package static func merge(local: [AgentSegment], imported: [AgentSegment]) -> [AgentSegment] {
        let remote = Set(imported.map(AgentSync.key))
        return (local.filter { !remote.contains(AgentSync.key($0)) } + imported).sorted { $0.span.start < $1.span.start }
    }
}
