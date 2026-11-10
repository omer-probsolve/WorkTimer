import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One agent turn in AI World, as its local database records it: when it ran,
/// what happened during it, and when it was waiting on an approval.
///
/// The rules match the ones for transcripts (`AgentLogState`): a silence longer
/// than `maxSilence` isn't counted unless a tool was running, which counts for up
/// to `maxToolRun`. A wait on an approval is never counted — AI World records
/// exactly when it was asked and answered.
package struct AIWorldTurn: Codable, Equatable {
    package struct Event: Codable, Equatable {
        package enum Kind: String, Codable { case activity, toolStarted, toolFinished }
        package var at: Date
        package var kind: Kind
        /// Pairs a tool's start with its finish.
        package var toolCall: String?

        package init(at: Date, kind: Kind, toolCall: String? = nil) {
            self.at = at
            self.kind = kind
            self.toolCall = toolCall
        }
    }

    /// An approval the turn asked for. `end` is nil while it's unanswered.
    package struct Wait: Codable, Equatable {
        package var start: Date
        package var end: Date?

        package init(start: Date, end: Date?) {
            self.start = start
            self.end = end
        }
    }

    package var id: String
    /// The chat the turn belongs to, which plays the part of a session.
    package var chatID: String?
    /// "claude" or "codex": the engine that ran the turn.
    package var engine: String
    package var project: String?
    package var started: Date
    /// Nil while the turn is still running.
    package var finished: Date?
    package var events: [Event]
    package var waits: [Wait]

    package init(id: String, chatID: String?, engine: String, project: String?, started: Date, finished: Date?,
                 events: [Event] = [], waits: [Wait] = []) {
        self.id = id
        self.chatID = chatID
        self.engine = engine
        self.project = project
        self.started = started
        self.finished = finished
        self.events = events
        self.waits = waits
    }

    /// The turn's work segments, oldest first; the last one is open while the
    /// turn is running and not waiting on you.
    package func segments() -> [AgentSegment] {
        enum Step { case activity, toolStarted(String), toolFinished(String), waitStart, waitEnd, finish }
        var steps: [(at: Date, step: Step)] = [(started, .activity)]
        for event in events {
            switch event.kind {
            case .activity: steps.append((event.at, .activity))
            case .toolStarted: steps.append((event.at, event.toolCall.map(Step.toolStarted) ?? .activity))
            case .toolFinished: steps.append((event.at, event.toolCall.map(Step.toolFinished) ?? .activity))
            }
        }
        for wait in waits {
            steps.append((wait.start, .waitStart))
            if let end = wait.end { steps.append((end, .waitEnd)) }
        }
        if let finished { steps.append((finished, .finish)) }
        // Stable, so steps at the same moment keep the order above.
        let ordered = steps.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)

        var spans: [Span] = []
        var start = started
        var last = started
        var tools = Set<String>()
        var waiting = 0
        var done = false

        func close() {
            if last > start { spans.append(Span(start: start, end: last)) }
        }

        for (time, step) in ordered where !done {
            if waiting > 0 {
                // Waiting on you: nothing counts until the last approval is answered.
                switch step {
                case let .toolStarted(id): tools.insert(id)
                case let .toolFinished(id): tools.remove(id)
                case .waitStart: waiting += 1
                case .waitEnd:
                    waiting -= 1
                    if waiting == 0 { start = time; last = time }
                case .finish: done = true
                case .activity: break
                }
                continue
            }
            let allowed = tools.isEmpty ? AgentLogState.maxSilence : AgentLogState.maxToolRun
            if time.timeIntervalSince(last) > allowed {
                close()
                start = time
            }
            last = max(last, time)
            switch step {
            case let .toolStarted(id): tools.insert(id)
            case let .toolFinished(id): tools.remove(id)
            case .waitStart: close(); waiting = 1
            case .finish: close(); done = true
            case .activity, .waitEnd: break
            }
        }
        let open = finished == nil && waiting == 0
        if open { close() }

        let project = project.flatMap { $0.isEmpty ? nil : $0 } ?? Worker.aiWorld.name
        let session = chatID ?? id
        return spans.enumerated().map { index, span in
            let isLast = index == spans.count - 1
            return AgentSegment(
                worker: .aiWorld, sessionID: session, project: project, source: Self.source(engine: engine),
                span: span, open: open && isLast, notWaitingOnYou: open && isLast && !tools.isEmpty
            )
        }
    }

    /// The engine as shown in the source column: "Claude", "Codex".
    package static func source(engine: String) -> String {
        Worker(rawValue: engine).map(\.name) ?? engine.capitalized
    }
}

/// Reads AI World's agent turns from its local Supabase stack and turns them into
/// work segments.
///
/// Read-only, and nothing in AI World is changed: it queries the database through
/// the stack's own SQL endpoint. Turns are kept in a cache on disk, so work
/// already counted survives AI World's database being reset. The first run only
/// reads turns from that day on. Not thread-safe: call it from one queue.
package final class AIWorldScanner {
    /// Where AI World's local Supabase API listens; nil when that isn't known.
    private let endpoint: () -> URL?
    /// Looks up the stack's key. It may run a command, so it's only asked once the
    /// stack answers, and again when the key stops working.
    private let lookUpKey: () -> String?
    private var key: String?
    private var lastKeyLookup: Date?
    private let cacheURL: URL
    private var log: Log

    private struct Log: Codable {
        static let version = 1
        var version = Log.version
        /// Turns that started before this aren't read.
        var countFrom: Date
        /// The database's clock at the last successful read, so the next one only
        /// asks for turns that finished since.
        var syncedUntil: Date?
        var turns: [String: AIWorldTurn] = [:]
    }

    /// Allows for turns committed a little after the database's clock was read.
    private static let overlap: TimeInterval = 60
    private static let timeout: TimeInterval = 10
    /// A failed key lookup isn't retried sooner than this.
    private static let keyRetry: TimeInterval = 60

    package init(endpoint: @escaping () -> URL?, key: @escaping () -> String?, cacheURL: URL, now: Date = Date()) {
        self.endpoint = endpoint
        lookUpKey = key
        self.cacheURL = cacheURL
        log = Log(countFrom: Calendar.current.startOfDay(for: now))
    }

    /// Restores the turns saved by an earlier run. Without a cache, counting starts
    /// at the start of today.
    package func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let saved = try? Self.decoder.decode(Log.self, from: data), saved.version == Log.version else {
            saveCache()
            return
        }
        log = saved
    }

    /// Every AI World segment so far, oldest first.
    package func segments() -> [AgentSegment] {
        log.turns.values.flatMap { $0.segments() }.sorted { $0.span.start < $1.span.start }
    }

    /// Reads turns that are running or finished since the last read. Returns
    /// whether anything changed; false too when AI World isn't running.
    @discardableResult
    package func refresh() -> Bool {
        let since = log.syncedUntil.map { $0.addingTimeInterval(-Self.overlap) } ?? log.countFrom
        guard let data = post(query: Self.query(countFrom: log.countFrom, since: since)),
              let result = Self.decode(data) else { return false }
        var changed = false
        for turn in result.turns where log.turns[turn.id] != turn {
            log.turns[turn.id] = turn
            changed = true
        }
        log.syncedUntil = result.now
        // Saved with the turns only: re-reading a little more after a relaunch is harmless.
        if changed { saveCache() }
        return changed
    }

    // MARK: - Query

    /// Turns that started since `countFrom` and are running or finished since
    /// `since`, with their events and approvals. Times are epoch seconds, so no
    /// date parsing is needed.
    package static func query(countFrom: Date, since: Date) -> String {
        """
        select json_build_object(
          'now', extract(epoch from now())::float8,
          'turns', coalesce((
            select json_agg(json_build_object(
              'id', t.id, 'chat', t.chat_id, 'engine', t.engine, 'project', p.name,
              'started', extract(epoch from t.started_at)::float8,
              'finished', extract(epoch from t.finished_at)::float8,
              'events', (select coalesce(json_agg(json_build_array(
                  extract(epoch from e.at)::float8, e.type, e.payload->>'toolCallId') order by e.at), '[]'::json)
                from events e where e.turn_id = t.id),
              'waits', (select coalesce(json_agg(json_build_array(
                  extract(epoch from a.created_at)::float8,
                  extract(epoch from coalesce(a.decided_at, a.detached_at))::float8)), '[]'::json)
                from approvals a where a.turn_id = t.id)
            ))
            from turns t
            left join projects p on p.id = t.project_id
            where t.started_at >= to_timestamp(\(countFrom.timeIntervalSince1970))
              and (t.finished_at is null or t.finished_at >= to_timestamp(\(since.timeIntervalSince1970)))
          ), '[]'::json)
        ) as result
        """
    }

    /// Parses the endpoint's answer to `query`.
    package static func decode(_ data: Data) -> (now: Date, turns: [AIWorldTurn])? {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let result = rows.first?["result"] as? [String: Any],
              let now = date(result["now"]) else { return nil }
        let turns = (result["turns"] as? [[String: Any]] ?? []).compactMap { row -> AIWorldTurn? in
            guard let id = row["id"] as? String, let started = date(row["started"]) else { return nil }
            let events = (row["events"] as? [[Any]] ?? []).compactMap { item -> AIWorldTurn.Event? in
                guard item.count >= 2, let at = date(item[0]), let type = item[1] as? String else { return nil }
                let kind: AIWorldTurn.Event.Kind
                switch type {
                case "tool_started": kind = .toolStarted
                case "tool_finished": kind = .toolFinished
                default: kind = .activity
                }
                return AIWorldTurn.Event(at: at, kind: kind, toolCall: item.count > 2 ? item[2] as? String : nil)
            }
            let waits = (row["waits"] as? [[Any]] ?? []).compactMap { item -> AIWorldTurn.Wait? in
                guard let start = item.first.flatMap(date) else { return nil }
                return AIWorldTurn.Wait(start: start, end: item.count > 1 ? date(item[1]) : nil)
            }
            return AIWorldTurn(
                id: id, chatID: row["chat"] as? String, engine: row["engine"] as? String ?? "",
                project: row["project"] as? String, started: started, finished: date(row["finished"]),
                events: events, waits: waits
            )
        }
        return (now, turns)
    }

    private static func date(_ value: Any?) -> Date? {
        (value as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    }

    // MARK: - Network

    /// Runs a query on the stack's SQL endpoint, waiting for the answer. Nil when
    /// AI World isn't running or its key can't be found.
    private func post(query: String) -> Data? {
        guard let endpoint = endpoint() else { return nil }
        if key == nil {
            // Without a key the stack still answers (401), which shows it's running.
            guard send(query, to: endpoint, key: nil).status != nil, refreshKey() else { return nil }
        }
        var answer = send(query, to: endpoint, key: key)
        if answer.status == 401 || answer.status == 403 {
            // The stack was set up again with a new key.
            key = nil
            guard refreshKey() else { return nil }
            answer = send(query, to: endpoint, key: key)
        }
        return answer.status == 200 ? answer.data : nil
    }

    /// Looks the key up, at most once a minute. Returns whether there is one.
    private func refreshKey() -> Bool {
        if let last = lastKeyLookup, Date().timeIntervalSince(last) < Self.keyRetry { return key != nil }
        lastKeyLookup = Date()
        key = lookUpKey()
        return key != nil
    }

    private func send(_ query: String, to endpoint: URL, key: String?) -> (status: Int?, data: Data?) {
        var request = URLRequest(url: endpoint.appendingPathComponent("pg/query"), timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key {
            request.setValue(key, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query])

        var result: (Int?, Data?) = (nil, nil)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            result = ((response as? HTTPURLResponse)?.statusCode, data)
            done.signal()
        }.resume()
        done.wait()
        return result
    }

    // MARK: - Cache

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    private func saveCache() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(log) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
