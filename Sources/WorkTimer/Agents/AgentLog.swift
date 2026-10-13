import Foundation

enum Worker: String, Codable, CaseIterable, Identifiable {
    case you, claude, codex

    var id: Self { self }

    var name: String {
        switch self {
        case .you: return "You"
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    static let agents: [Worker] = [.claude, .codex]
}

/// What one agent transcript file says about when its agent was working.
///
/// Parsing is incremental: `offset` marks how far the file has been read, and the
/// open-turn fields carry over, so a growing transcript is only read from where it
/// left off.
///
/// A turn runs from the user's prompt to the agent's final answer. Inside a turn,
/// a silence longer than `maxSilence` is treated as the agent waiting on you (a
/// permission prompt, say) and isn't counted.
struct AgentLogState: Codable {
    static let maxSilence: TimeInterval = 5 * 60

    var worker: Worker
    var fileSize: UInt64 = 0
    var modified: Date = .distantPast
    var offset: UInt64 = 0
    /// Subagent transcripts — their time is already covered by the parent session.
    var ignored = false

    var sessionID: String?
    var cwd: String?
    var source: String?

    var turnOpen = false
    /// The agent gave its final answer; the turn ends once the answer finishes
    /// streaming, which the next bookkeeping record marks.
    var turnEnding = false
    var segmentStart: Date?
    var lastActivity: Date?
    var segments: [Span] = []

    init(worker: Worker) {
        self.worker = worker
    }

    /// The turn is still in progress, so the agent may be working right now.
    var isLive: Bool { turnOpen && !turnEnding }

    /// Finished segments plus the open one, which ends at the last activity seen.
    var allSegments: [Span] {
        guard turnOpen, let start = segmentStart, let last = lastActivity else { return segments }
        return segments + [Span(start: start, end: last)]
    }

    // MARK: - Turn bookkeeping

    private mutating func openTurn(at time: Date) {
        if turnEnding, let last = lastActivity {
            // A new prompt after a final answer whose end wasn't recorded.
            closeTurn(at: last)
        }
        if turnOpen {
            activity(at: time)
        } else {
            turnOpen = true
            segmentStart = time
            lastActivity = time
        }
    }

    private mutating func activity(at time: Date) {
        guard turnOpen, let last = lastActivity, let start = segmentStart else { return }
        guard time > last else { return }
        if time.timeIntervalSince(last) > Self.maxSilence {
            if last > start { segments.append(Span(start: start, end: last)) }
            segmentStart = time
        }
        lastActivity = time
    }

    private mutating func closeTurn(at time: Date) {
        guard turnOpen else { return }
        activity(at: time)
        if let start = segmentStart, let last = lastActivity, last > start {
            segments.append(Span(start: start, end: last))
        }
        turnOpen = false
        turnEnding = false
        segmentStart = nil
    }

    // MARK: - Lines

    mutating func consume(line: Data) {
        guard !ignored, !line.isEmpty else { return }
        switch worker {
        case .claude: consumeClaude(line)
        case .codex: consumeCodex(line)
        case .you: break
        }
    }

    /// Claude Code: ~/.claude/projects/<project>/<session>.jsonl
    private mutating func consumeClaude(_ line: Data) {
        // Huge lines are tool results carrying images or file dumps. Decoding them
        // isn't worth it: they only tell us the agent is busy.
        guard line.count < 1_000_000 else {
            if let time = LogScan.lastTimestamp(in: line) { activity(at: time) }
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String,
              let stamp = object["timestamp"] as? String,
              let time = LogScan.date(stamp) else { return }
        guard object["isSidechain"] as? Bool != true else { return }

        if cwd == nil, let value = object["cwd"] as? String { cwd = value }
        if sessionID == nil, let value = object["sessionId"] as? String { sessionID = value }
        if source == nil, let entry = object["entrypoint"] as? String {
            switch entry {
            case "cli": source = "Terminal"
            case "claude-desktop": source = "Desktop"
            default: source = "SDK"
            }
        }

        let message = object["message"] as? [String: Any]
        switch type {
        case "user":
            if object["isMeta"] as? Bool == true { activity(at: time); return }
            switch Self.promptKind(message?["content"]) {
            case .prompt: openTurn(at: time)
            case .interrupt: closeTurn(at: time)
            case .other: activity(at: time)
            }
        case "assistant":
            // A reply without a fresh prompt still means the agent is working,
            // e.g. it picked up a finished background task.
            if turnOpen { activity(at: time) } else { openTurn(at: time) }
            // Lines are stamped when a block starts, so the final answer is still
            // streaming; the stop-hook or turn-duration record marks the end.
            if let stop = message?["stop_reason"] as? String, stop == "end_turn" || stop == "stop_sequence" {
                turnEnding = true
            }
        case "system":
            let subtype = object["subtype"] as? String
            if subtype == "turn_duration" || subtype == "stop_hook_summary" { closeTurn(at: time) }
        default:
            break
        }
    }

    private enum PromptKind { case prompt, interrupt, other }

    private static func promptKind(_ content: Any?) -> PromptKind {
        var text: String?
        if let string = content as? String {
            text = string
        } else if let blocks = content as? [[String: Any]] {
            if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return .other }
            text = blocks.first { $0["type"] as? String == "text" }?["text"] as? String
        }
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return .other }
        if text.hasPrefix("[Request interrupted by user") { return .interrupt }
        // Slash commands like /clear run locally; the model isn't working.
        if text.hasPrefix("<command-name>") || text.hasPrefix("<local-command") { return .other }
        return .prompt
    }

    /// Codex: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl. These files get very
    /// large, so lines are only scanned, not decoded — except the header.
    private mutating func consumeCodex(_ line: Data) {
        guard let time = LogScan.leadingTimestamp(in: line) else { return }
        let head = line.prefix(200)
        if sessionID == nil, head.range(of: LogScan.sessionMeta) != nil {
            readCodexHeader(line)
            return
        }
        if head.range(of: LogScan.taskStarted) != nil {
            openTurn(at: time)
        } else if head.range(of: LogScan.taskComplete) != nil || head.range(of: LogScan.turnAborted) != nil {
            closeTurn(at: time)
        } else {
            activity(at: time)
        }
    }

    private mutating func readCodexHeader(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return }
        sessionID = payload["id"] as? String ?? UUID().uuidString
        cwd = payload["cwd"] as? String
        if let source = payload["source"] as? [String: Any], source["subagent"] != nil {
            ignored = true
        }
        let originator = (payload["originator"] as? String ?? "").lowercased()
        source = originator.contains("desktop") ? "Codex app" : "Terminal"
    }
}

/// Byte-level helpers for reading JSONL without decoding every line.
enum LogScan {
    private static let leadingPrefix = Array("{\"timestamp\":\"".utf8)
    private static let timestampKey = Data("\"timestamp\":\"".utf8)

    static let sessionMeta = Data("\"type\":\"session_meta\"".utf8)
    static let taskStarted = Data("\"type\":\"task_started\"".utf8)
    static let taskComplete = Data("\"type\":\"task_complete\"".utf8)
    static let turnAborted = Data("\"type\":\"turn_aborted\"".utf8)

    /// Codex lines start with `{"timestamp":"2026-10-12T11:10:28.253Z"`.
    static func leadingTimestamp(in line: Data) -> Date? {
        guard line.count > leadingPrefix.count + 20, line.starts(with: leadingPrefix) else { return nil }
        let start = line.startIndex + leadingPrefix.count
        return date(line[start ..< min(start + 30, line.endIndex)])
    }

    /// The last `"timestamp":"…"` in a line, which for Claude transcripts is the
    /// top-level one: it follows the (possibly huge) message.
    static func lastTimestamp(in line: Data) -> Date? {
        guard let range = line.range(of: timestampKey, options: .backwards) else { return nil }
        return date(line[range.upperBound ..< min(range.upperBound + 30, line.endIndex)])
    }

    static func date(_ string: String) -> Date? {
        date(Data(string.utf8))
    }

    /// Parses `YYYY-MM-DDTHH:MM:SS(.fff)Z` (UTC) — much faster than a formatter,
    /// which matters for millions of lines.
    static func date(_ bytes: Data) -> Date? {
        let b = Array(bytes.prefix(30))
        guard b.count >= 20 else { return nil }
        func number(_ from: Int, _ count: Int) -> Int? {
            var value = 0
            for i in from ..< from + count {
                let digit = Int(b[i]) - 48
                guard (0...9).contains(digit) else { return nil }
                value = value * 10 + digit
            }
            return value
        }
        guard b[4] == 45, b[7] == 45, b[10] == 84, b[13] == 58, b[16] == 58,
              let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2) else { return nil }
        var fraction = 0.0
        var i = 19
        if i < b.count, b[i] == 46 {
            var scale = 0.1
            i += 1
            while i < b.count, let digit = Optional(Int(b[i]) - 48), (0...9).contains(digit) {
                fraction += Double(digit) * scale
                scale /= 10
                i += 1
            }
        }
        var parts = tm()
        parts.tm_year = Int32(year - 1900)
        parts.tm_mon = Int32(month - 1)
        parts.tm_mday = Int32(day)
        parts.tm_hour = Int32(hour)
        parts.tm_min = Int32(minute)
        parts.tm_sec = Int32(second)
        let seconds = timegm(&parts)
        guard seconds != -1 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds) + fraction)
    }
}
