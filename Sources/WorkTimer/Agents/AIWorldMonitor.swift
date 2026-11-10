import Foundation
import WorkTimerCore

/// Publishes AI World's agent work to the UI. `AIWorldScanner` does the reading;
/// this polls it on a background queue while counting AI World is turned on.
/// There are no files to watch: AI World keeps its turns in a database.
final class AIWorldMonitor: ObservableObject {
    @Published private(set) var segments: [AgentSegment] = []

    private let queue = DispatchQueue(label: "WorkTimer.AIWorldMonitor", qos: .utility)
    private let scanner: AIWorldScanner
    private var timer: DispatchSourceTimer?
    private var cacheLoaded = false

    /// How often the database is read. A new turn shows up within this long.
    private static let interval: TimeInterval = 15

    /// `folder` is AI World's project folder, the one holding `supabase/config.toml`.
    init(folder: @escaping () -> URL?) {
        scanner = AIWorldScanner(
            endpoint: { folder().flatMap(AIWorldStack.endpoint) },
            key: { folder().flatMap(AIWorldStack.key) },
            cacheURL: AppPaths.dataDirectory.appendingPathComponent("aiworld-cache.json")
        )
    }

    /// Starts or stops reading AI World. Stopping hides its work; turning it back
    /// on shows it again, with whatever ran in between.
    func setEnabled(_ enabled: Bool) {
        timer?.cancel()
        timer = nil
        guard enabled else {
            segments = []
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.interval, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        self.timer = timer
    }

    /// On the queue: reads new turns and publishes the result if it changed.
    private func refresh() {
        let first = !cacheLoaded
        if first {
            scanner.loadCache()
            cacheLoaded = true
        }
        guard scanner.refresh() || first else { return }
        let result = scanner.segments()
        DispatchQueue.main.async { [self] in
            guard timer != nil, segments != result else { return }
            segments = result
        }
    }
}

/// Finds AI World's local Supabase stack from its project folder: the API port in
/// `supabase/config.toml`, and the key from the Supabase CLI (`supabase status`),
/// so no key is kept in Work Timer.
enum AIWorldStack {
    /// `http://127.0.0.1:<[api] port>`.
    static func endpoint(folder: URL) -> URL? {
        guard let config = try? String(contentsOf: folder.appendingPathComponent("supabase/config.toml"), encoding: .utf8) else { return nil }
        var inAPI = false
        for line in config.split(separator: "\n") {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inAPI = line == "[api]"
            } else if inAPI, line.hasPrefix("port"), let port = line.split(separator: "=").last.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
                return URL(string: "http://127.0.0.1:\(port)")
            }
        }
        return nil
    }

    /// The stack's secret key (or service-role key on older CLIs), from
    /// `supabase status -o env`. Nil when the CLI isn't installed or the stack is down.
    static func key(folder: URL) -> String? {
        guard let cli = cliPath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["status", "-o", "env", "--workdir", folder.path]
        // Apps don't get the shell's PATH; the CLI needs to find Docker.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (searchPaths + [environment["PATH"] ?? ""]).joined(separator: ":")
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timeout = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0 else { return nil }

        var values: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            values[String(parts[0])] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return [values["SECRET_KEY"], values["SERVICE_ROLE_KEY"]].compactMap { $0 }.first { !$0.isEmpty }
    }

    private static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]

    private static var cliPath: String? {
        searchPaths.map { $0 + "/supabase" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
