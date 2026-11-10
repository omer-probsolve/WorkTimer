import Foundation

package enum Worker: String, Codable, CaseIterable, Identifiable {
    case you, claude, codex, aiWorld

    package var id: Self { self }

    package var name: String {
        switch self {
        case .you: return "You"
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .aiWorld: return "AI World"
        }
    }

    package static let agents: [Worker] = [.claude, .codex, .aiWorld]
}

/// What one agent transcript file says about when its agent was working.
///
/// Parsing is incremental: `offset` marks how far the file has been read, and the
/// open-turn fields carry over, so a growing transcript is only read from where it
/// left off.
///
/// A turn runs from the user's prompt to the agent's final answer. Inside a turn,
/// a silence longer than `maxSilence` is treated as the agent waiting on you (a
/// permission prompt, say) and isn't counted — unless the agent was waiting on a
/// tool that didn't ask you anything (a long test run), which counts for up to
/// `maxToolRun`. A background task that wakes the agent after its turn ended
/// counts the same way.
package struct AgentLogState: Codable {
    package static let maxSilence: TimeInterval = 5 * 60
    /// The longest silence counted as the agent waiting on a tool. Caps the damage
    /// when a session is killed mid-tool.
    package static let maxToolRun: TimeInterval = 60 * 60

    package var worker: Worker
    package var fileSize: UInt64 = 0
    package var modified: Date = .distantPast
    package var offset: UInt64 = 0
    /// Subagent transcripts — their time is already covered by the parent session.
    package var ignored = false

    package var sessionID: String?
    package var cwd: String?
    package var source: String?

    package var turnOpen = false
    /// The agent gave its final answer; the turn ends once the answer finishes
    /// streaming, which the next bookkeeping record marks.
    package var turnEnding = false
    package var segmentStart: Date?
    package var lastActivity: Date?
    package var segments: [Span] = []

    /// Claude Code tool calls still waiting for their result.
    package var runningTools: Set<String> = []
    /// Claude Code background tasks that haven't reported back yet, by ID.
    package var backgroundTasks: [String: BackgroundTask] = [:]
    /// The agent may stop to ask you for permission, so a silence may be it
    /// waiting on you. From Claude Code's permission mode, Codex's approval policy.
    package var mayAsk = true

    package init(worker: Worker) {
        self.worker = worker
    }

    /// The turn is still in progress, so the agent may be working right now.
    package var isLive: Bool { turnOpen && !turnEnding }

    /// The agent can't be waiting on you right now — it's running a tool without
    /// a permission prompt, or it never asks — so silence is still work.
    package var notWaitingOnYou: Bool {
        guard turnOpen, !mayAsk else { return false }
        return worker == .codex || !runningTools.isEmpty
    }

    /// Finished segments plus the open one, which ends at the last activity seen.
    package var allSegments: [Span] {
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

    /// - Parameter toolRan: the silence before `time` was a tool running, not a
    ///   wait on you; defaults to what's known while the silence lasts.
    private mutating func activity(at time: Date, toolRan: Bool? = nil) {
        guard turnOpen, let last = lastActivity, let start = segmentStart else { return }
        guard time > last else { return }
        let silence = time.timeIntervalSince(last)
        let counted = (toolRan ?? notWaitingOnYou) ? Self.maxToolRun : Self.maxSilence
        if silence > counted {
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
        runningTools = []
    }

    /// A background task the agent started reported back: the agent was waiting
    /// on it since its turn ended, so the turn carries on.
    private mutating func resumeTurn(at time: Date) {
        guard !turnOpen, let last = lastActivity, time.timeIntervalSince(last) <= Self.maxToolRun,
              let previous = segments.last, previous.end == last else { return openTurn(at: time) }
        segments.removeLast()
        turnOpen = true
        segmentStart = previous.start
        activity(at: time, toolRan: true)
    }

    // MARK: - Lines

    package mutating func consume(line: Data) {
        guard !ignored, !line.isEmpty else { return }
        switch worker {
        case .claude: consumeClaude(line)
        case .codex: consumeCodex(line)
        case .you, .aiWorld: break
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
            if let mode = object["permissionMode"] as? String {
                mayAsk = mode != "auto" && mode != "bypassPermissions"
            }
            if object["isMeta"] as? Bool == true { activity(at: time); return }
            switch Self.promptKind(message?["content"]) {
            case .prompt: openTurn(at: time)
            case .interrupt: closeTurn(at: time)
            case let .toolResults(ids):
                let waited = !runningTools.isDisjoint(with: ids)
                runningTools.subtract(ids)
                if let result = object["toolUseResult"] as? [String: Any],
                   let id = result["backgroundTaskId"] as? String {
                    backgroundTasks[id] = BackgroundTask(
                        id: id, outputFile: Self.outputFile(in: message?["content"]),
                        movedByTimeout: result["timedOutAfterMs"] != nil
                    )
                }
                activity(at: time, toolRan: waited && !Self.askedYou(object["permissionDecision"]))
            case let .taskNotification(task):
                if backgroundTasks.removeValue(forKey: task) != nil, !turnOpen {
                    resumeTurn(at: time)
                } else {
                    openTurn(at: time)
                }
            case .other: activity(at: time)
            }
        case "assistant":
            // A reply without a fresh prompt still means the agent is working,
            // e.g. it picked up a finished background task.
            if turnOpen { activity(at: time) } else { openTurn(at: time) }
            if let blocks = message?["content"] as? [[String: Any]] {
                for block in blocks where block["type"] as? String == "tool_use" {
                    guard let id = block["id"] as? String, let name = block["name"] as? String,
                          !Self.toolsThatAskYou.contains(name) else { continue }
                    runningTools.insert(id)
                }
            }
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

    /// Claude Code tells the agent where a background task's output goes:
    /// "Output is being written to: /…/tasks/<id>.output".
    private static func outputFile(in content: Any?) -> String? {
        let blocks = content as? [[String: Any]] ?? []
        for block in blocks {
            var texts: [String] = []
            if let text = block["content"] as? String { texts.append(text) }
            if let parts = block["content"] as? [[String: Any]] { texts += parts.compactMap { $0["text"] as? String } }
            for text in texts {
                guard let start = text.range(of: "Output is being written to: "),
                      let end = text.range(of: ".output", range: start.upperBound ..< text.endIndex) else { continue }
                return String(text[start.upperBound ..< end.upperBound])
            }
        }
        return nil
    }

    /// Tools that wait on your answer, so time spent in them isn't the agent working.
    private static let toolsThatAskYou: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    /// Claude Code records how each tool call was allowed; a `user…` source means
    /// you were asked.
    private static func askedYou(_ decision: Any?) -> Bool {
        guard let source = (decision as? [String: Any])?["source"] as? String else { return false }
        return source.hasPrefix("user")
    }

    private enum PromptKind {
        case prompt, interrupt, other
        case toolResults([String])
        /// A background task finished; its ID.
        case taskNotification(String)
    }

    private static func promptKind(_ content: Any?) -> PromptKind {
        var text: String?
        if let string = content as? String {
            text = string
        } else if let blocks = content as? [[String: Any]] {
            let results = blocks.filter { $0["type"] as? String == "tool_result" }
            if !results.isEmpty { return .toolResults(results.compactMap { $0["tool_use_id"] as? String }) }
            text = blocks.first { $0["type"] as? String == "text" }?["text"] as? String
        }
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return .other }
        if text.hasPrefix("[Request interrupted by user") { return .interrupt }
        if text.hasPrefix("<task-notification>") {
            guard let start = text.range(of: "<task-id>"),
                  let end = text.range(of: "</task-id>", range: start.upperBound ..< text.endIndex) else { return .prompt }
            return .taskNotification(String(text[start.upperBound ..< end.lowerBound]))
        }
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
        if head.range(of: LogScan.threadSettings) != nil || head.range(of: LogScan.turnContext) != nil,
           line.range(of: LogScan.approvalPolicy) != nil {
            mayAsk = line.range(of: LogScan.approvalNever) == nil
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

/// A command the agent left running in the background (Claude Code). Whether it
/// keeps the agent working once its turn ends depends on what the process is
/// doing, which only the platform can see.
package struct BackgroundTask: Codable, Equatable {
    package var id: String
    /// Where the task's output goes; the task's processes hold it open.
    package var outputFile: String?
    /// The command outran its time limit in the foreground, so the agent meant to
    /// wait for it. Explicit background commands may be servers left running.
    package var movedByTimeout: Bool

    package init(id: String, outputFile: String?, movedByTimeout: Bool) {
        self.id = id
        self.outputFile = outputFile
        self.movedByTimeout = movedByTimeout
    }

    /// The agent is waiting on this task: it's busy (a test run, a build — an
    /// idle server isn't), or it's still alive and the agent meant to wait for it.
    package func keepsAgentWorking(_ activity: TaskActivity) -> Bool {
        switch activity {
        case .busy: return true
        case .idle: return movedByTimeout
        case .gone: return false
        }
    }
}

/// What a background task's processes are doing, as seen by the platform.
package enum TaskActivity: Equatable {
    /// Using the CPU or writing output, wherever the work itself runs.
    case busy
    /// Running but quiet, like a server waiting for requests.
    case idle
    /// No process holds the task's output any more.
    case gone
}

/// Turns what the platform sees of each background task at every check into
/// `TaskActivity`. A task is busy once it has kept working — using the CPU or
/// writing output — for `sustained`: a server's burst of startup work is over
/// sooner, a test run or build keeps going. It stays busy through quiet
/// stretches up to `quietAllowance`.
package struct TaskActivityTracker {
    package static let sustained: TimeInterval = 30
    package static let quietAllowance: TimeInterval = 2 * 60

    /// When each task's current stretch of work was first and last seen.
    private var working: [String: (first: Date, last: Date)] = [:]

    package init() {}

    /// - Parameter worked: whether the task worked since the previous check;
    ///   nil when its processes are gone.
    package mutating func update(_ id: String, worked: Bool?, at now: Date) -> TaskActivity {
        guard let worked else {
            working[id] = nil
            return .gone
        }
        if let stretch = working[id], now.timeIntervalSince(stretch.last) > Self.quietAllowance {
            working[id] = nil
        }
        if worked { working[id] = (working[id]?.first ?? now, now) }
        guard let stretch = working[id] else { return .idle }
        return stretch.last.timeIntervalSince(stretch.first) >= Self.sustained ? .busy : .idle
    }

    /// Drops tasks no longer being checked.
    package mutating func keep(only ids: Set<String>) {
        working = working.filter { ids.contains($0.key) }
    }
}

/// Byte-level helpers for reading JSONL without decoding every line.
package enum LogScan {
    private static let leadingPrefix = Array("{\"timestamp\":\"".utf8)
    private static let timestampKey = Data("\"timestamp\":\"".utf8)

    package static let sessionMeta = Data("\"type\":\"session_meta\"".utf8)
    package static let taskStarted = Data("\"type\":\"task_started\"".utf8)
    package static let taskComplete = Data("\"type\":\"task_complete\"".utf8)
    package static let turnAborted = Data("\"type\":\"turn_aborted\"".utf8)
    package static let threadSettings = Data("\"type\":\"thread_settings_applied\"".utf8)
    package static let turnContext = Data("\"type\":\"turn_context\"".utf8)
    package static let approvalPolicy = Data("\"approval_policy\":".utf8)
    package static let approvalNever = Data("\"approval_policy\":\"never\"".utf8)

    /// Codex lines start with `{"timestamp":"2026-10-12T11:10:28.253Z"`.
    package static func leadingTimestamp(in line: Data) -> Date? {
        guard line.count > leadingPrefix.count + 20, line.starts(with: leadingPrefix) else { return nil }
        let start = line.startIndex + leadingPrefix.count
        return date(line[start ..< min(start + 30, line.endIndex)])
    }

    /// The last `"timestamp":"…"` in a line, which for Claude transcripts is the
    /// top-level one: it follows the (possibly huge) message.
    package static func lastTimestamp(in line: Data) -> Date? {
        guard let range = line.range(of: timestampKey, options: .backwards) else { return nil }
        return date(line[range.upperBound ..< min(range.upperBound + 30, line.endIndex)])
    }

    package static func date(_ string: String) -> Date? {
        date(Data(string.utf8))
    }

    /// Parses `YYYY-MM-DDTHH:MM:SS(.fff)Z` (UTC) — much faster than a formatter,
    /// which matters for millions of lines.
    package static func date(_ bytes: Data) -> Date? {
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
        #if os(Windows)
        let seconds = _mkgmtime(&parts)
        #else
        let seconds = timegm(&parts)
        #endif
        guard seconds != -1 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds) + fraction)
    }
}
