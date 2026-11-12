import Foundation
import Combine
import Network
import Security
import CryptoKit
import Darwin
import WorkTimerCore

/// Shared by standalone WorkTimer and Toolbelt through WorkTimerController.
/// All network I/O and commits run on one queue; published segments return to the main queue.
final class LANSyncReceiver: ObservableObject {
    static let shared = LANSyncReceiver()
    @Published private(set) var segments: [AgentSegment] = []
    @Published private(set) var enabled = false
    @Published private(set) var status = "LAN sync is off"

    private struct Configuration: Codable {
        var pairing: SyncPairing
        var password: String
    }
    private let queue = DispatchQueue(label: "WorkTimer.LANSync", qos: .utility)
    private let directory = AppPaths.dataDirectory.appendingPathComponent("lan-sync", isDirectory: true)
    private var configuration: Configuration?
    private var history = ImportedHistory()
    private var leases: [String: Date] = [:]
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var lockFile: Int32 = -1
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        queue.async { [self] in
            do {
                try loadHistory()
                let configURL = directory.appendingPathComponent("receiver.json")
                guard FileManager.default.fileExists(atPath: configURL.path) else { return }
                configuration = try AgentSync.decode(Configuration.self, from: Data(contentsOf: configURL))
                try configuration?.pairing.validate()
                try listen()
            } catch { publish(status: "LAN sync could not start; saved history was retained") }
        }
    }

    func enable() {
        status = "Preparing LAN pairing…"
        queue.async { [self] in
            do {
                if configuration == nil {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                    let password = try randomSecret(), token = try randomSecret()
                    let receiverID = UUID().uuidString
                    let key = directory.appendingPathComponent("key.pem")
                    let cert = directory.appendingPathComponent("certificate.pem")
                    defer { try? FileManager.default.removeItem(at: key); try? FileManager.default.removeItem(at: cert) }
                    try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650",
                                 "-keyout", key.path, "-out", cert.path, "-subj", "/CN=WorkTimer-" + receiverID], password: password)
                    try openssl(["pkcs12", "-export", "-inkey", key.path, "-in", cert.path,
                                 "-out", directory.appendingPathComponent("identity.p12").path,
                                 "-passout", "env:WORKTIMER_CERT_PASSWORD"], password: password)
                    let identity = try importIdentity(password: password)
                    var certificate: SecCertificate?
                    guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { throw ReceiverError.identity }
                    let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
                        .map { String(format: "%02x", $0) }.joined()
                    let pairing = SyncPairing(receiverID: receiverID,
                                              host: ProcessInfo.processInfo.hostName.hasSuffix(".local")
                                                ? ProcessInfo.processInfo.hostName : ProcessInfo.processInfo.hostName + ".local",
                                              port: 48765, certificateSHA256: digest, token: token)
                    let config = Configuration(pairing: pairing, password: password)
                    try AgentSync.save(config, to: directory.appendingPathComponent("receiver.json"))
                    configuration = config
                }
                try loadHistory()
                try listen()
            } catch { publish(status: "Could not enable LAN sync; check certificate and port availability") }
        }
    }

    func exportPairing(to url: URL) {
        queue.async { [self] in
            do {
                guard let configuration else { return }
                try AgentSync.save(configuration.pairing, to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                publish(status: "Pairing file exported. Import it on Windows, then delete the transferred copy.")
            } catch { publish(status: "Could not export the pairing file") }
        }
    }

    func disable() {
        queue.async { [self] in
            listener?.cancel(); listener = nil
            for connection in connections.values { connection.cancel() }
            connections.removeAll(); leases.removeAll()
            if lockFile >= 0 { flock(lockFile, LOCK_UN); close(lockFile); lockFile = -1 }
            // Retain timing history and pairing; the listener is opt-in again on the next launch only if configured.
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("receiver.json"))
            configuration = nil
            publish(status: "LAN sync is off")
        }
    }

    private func loadHistory() throws {
        let url = directory.appendingPathComponent("imported-history.json")
        if FileManager.default.fileExists(atPath: url.path) {
            history = try AgentSync.decode(ImportedHistory.self, from: Data(contentsOf: url))
            guard history.version == AgentSync.version else { throw AgentSync.Failure.incompatibleVersion }
        }
        // A new receiver run also detects restoring an older backup with the same saved epoch.
        history.epoch = UUID().uuidString
        publish()
    }

    private func listen() throws {
        guard listener == nil, let configuration else { return }
        if lockFile < 0 {
            lockFile = open(directory.appendingPathComponent("receiver.lock").path, O_CREAT | O_RDWR, 0o600)
            guard lockFile >= 0, flock(lockFile, LOCK_EX | LOCK_NB) == 0 else {
                if lockFile >= 0 { close(lockFile); lockFile = -1 }
                throw ReceiverError.alreadyRunning
            }
        }
        let identity = try importIdentity(password: configuration.password)
        guard let localIdentity = sec_identity_create(identity) else { throw ReceiverError.identity }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, localIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let parameters = NWParameters(tls: tls)
        parameters.prohibitedInterfaceTypes = [.cellular, .loopback, .other]
        parameters.acceptLocalOnly = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: configuration.pairing.port)!)
        listener.service = NWListener.Service(name: configuration.pairing.receiverID, type: "_worktimer._tcp")
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.publish(status: "Ready for the paired Windows collector")
            case .failed: self?.publish(status: "LAN receiver unavailable; Windows will keep its backlog")
            default: break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 4 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                guard self.isLAN(connection) else { self.finish(connection, id: id); return }
                self.receive(connection, id: id, buffer: Data())
            case .failed, .cancelled: self.finish(connection, id: id)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 15) { [weak self, weak connection] in
            if let self, let connection { self.finish(connection, id: id) }
        }
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard buffer.count <= AgentSync.maxBody + 16384, error == nil else { self.finish(connection, id: id); return }
            do {
                if let body = try self.httpBody(buffer) {
                    guard self.isLAN(connection), let config = self.configuration else { throw ReceiverError.request }
                    let request = try AgentSync.decode(SyncRequest.self, from: body)
                    guard self.constantTimeEqual(request.token, config.pairing.token) else { throw ReceiverError.request }
                    var candidate = self.history
                    let ack = try candidate.accept(request, receiverID: config.pairing.receiverID)
                    try AgentSync.save(candidate, to: self.directory.appendingPathComponent("imported-history.json"))
                    self.history = candidate
                    let now = Date()
                    self.leases = self.leases.filter { $0.value > now }
                    if abs(now.timeIntervalSince(request.sentAt)) <= 30 {
                        for key in request.live where candidate.sessions[key] != nil { self.leases[key] = now.addingTimeInterval(AgentSync.lease) }
                    }
                    let live = Set(request.live)
                    self.leases = self.leases.filter { live.contains($0.key) }
                    self.publish()
                    self.respond(connection, id: id, code: "200 OK", body: try AgentSync.encode(ack))
                } else if complete { self.finish(connection, id: id) }
                else { self.receive(connection, id: id, buffer: buffer) }
            } catch { self.respond(connection, id: id, code: "400 Bad Request", body: Data()) }
        }
    }

    private func httpBody(_ data: Data) throws -> Data? {
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 16384 { throw ReceiverError.request }
            return nil
        }
        guard boundary.lowerBound <= 16384,
              let header = String(data: data[..<boundary.lowerBound], encoding: .utf8) else { throw ReceiverError.request }
        let lines = header.components(separatedBy: "\r\n")
        guard lines.first == "POST /v1/sync HTTP/1.1" else { throw ReceiverError.request }
        var lengths: [Int] = []
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { throw ReceiverError.request }
            if parts[0].lowercased() == "transfer-encoding" { throw ReceiverError.request }
            if parts[0].lowercased() == "content-length" {
                guard let length = Int(parts[1]) else { throw ReceiverError.request }
                lengths.append(length)
            }
        }
        guard lengths.count == 1, let length = lengths.first, length > 0, length <= AgentSync.maxBody else { throw ReceiverError.request }
        let available = data.count - boundary.upperBound
        if available < length { return nil }
        guard available == length else { throw ReceiverError.request }
        return Data(data[boundary.upperBound...])
    }

    private func respond(_ connection: NWConnection, id: UUID, code: String, body: Data) {
        var response = Data("HTTP/1.1 \(code)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in self?.finish(connection, id: id) })
    }

    private func finish(_ connection: NWConnection, id: UUID) {
        connection.stateUpdateHandler = nil
        connection.cancel()
        connections[id] = nil
    }

    /// Require the peer's IPv4 address to be on an active physical LAN subnet.
    private func isLAN(_ connection: NWConnection) -> Bool {
        guard let path = connection.currentPath,
              path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet),
              case let .hostPort(host, _) = connection.endpoint,
              case let .ipv4(address) = host else { return false }
        let raw = address.rawValue
        guard raw.count == 4 else { return false }
        let peer = raw.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard peer >> 24 == 10 || peer >> 20 == 0xac1 || peer >> 16 == 0xc0a8 else { return false }
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return false }
        defer { freeifaddrs(interfaces) }
        var current = interfaces
        let allowedNames = Set(path.availableInterfaces.filter { $0.type == .wifi || $0.type == .wiredEthernet }.map(\.name))
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard allowedNames.contains(String(cString: item.pointee.ifa_name)),
                  item.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  item.pointee.ifa_flags & UInt32(IFF_POINTOPOINT | IFF_LOOPBACK) == 0,
                  let addr = item.pointee.ifa_addr, let mask = item.pointee.ifa_netmask,
                  Int32(addr.pointee.sa_family) == AF_INET else { continue }
            let local = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if netmask != 0 && peer & netmask == local & netmask { return true }
        }
        return false
    }

    private func importIdentity(password: String) throws -> SecIdentity {
        let data = try Data(contentsOf: directory.appendingPathComponent("identity.p12"))
        var items: CFArray?
        guard SecPKCS12Import(data as CFData, [kSecImportExportPassphrase: password] as CFDictionary, &items) == errSecSuccess,
              let array = items as? [[String: Any]], let identity = array.first?[kSecImportItemIdentity as String] else { throw ReceiverError.identity }
        return identity as! SecIdentity
    }

    private func randomSecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ReceiverError.identity }
        return Data(bytes).base64EncodedString()
    }

    private func openssl(_ arguments: [String], password: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.environment = ["WORKTIMER_CERT_PASSWORD": password]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        guard done.wait(timeout: .now() + 30) == .success else { process.terminate(); throw ReceiverError.identity }
        guard process.terminationStatus == 0 else { throw ReceiverError.identity }
    }

    private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func publish(status message: String? = nil) {
        let values = history.segments(leases: leases), isEnabled = listener != nil
        DispatchQueue.main.async { [self] in
            segments = values
            enabled = isEnabled
            if let message { status = message }
        }
    }
    private enum ReceiverError: Error { case identity, request, alreadyRunning }
}
