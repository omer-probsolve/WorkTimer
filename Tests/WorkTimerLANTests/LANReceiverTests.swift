import XCTest
import Combine
@testable import WorkTimerKit
@testable import WorkTimerCore

final class LANReceiverTests: XCTestCase {
    func testCreatesTLSIdentityStartsListenerAndExportsPairing() throws {
        // Never touch a developer's actual WorkTimer data or bind a listener unless explicitly isolated.
        guard let folder = ProcessInfo.processInfo.environment["WORKTIMER_DATA_DIR"],
              folder.contains("worktimer-tests") else { throw XCTSkip("Set WORKTIMER_DATA_DIR to an isolated worktimer-tests folder") }
        let receiver = LANSyncReceiver.shared
        let ready = expectation(description: "TLS identity and listener ready")
        var started = false
        let observation = receiver.$enabled.filter { $0 }.prefix(1).sink { _ in started = true; ready.fulfill() }
        receiver.enable()
        wait(for: [ready], timeout: 45)
        withExtendedLifetime(observation) {}
        XCTAssertTrue(started, receiver.status)

        let pairingURL = URL(fileURLWithPath: folder).appendingPathComponent("exported-pairing.json")
        let exported = expectation(description: "Pairing exported")
        let exportObservation = receiver.$status.filter { $0.hasPrefix("Pairing file exported") }.prefix(1).sink { _ in exported.fulfill() }
        receiver.exportPairing(to: pairingURL)
        wait(for: [exported], timeout: 10)
        withExtendedLifetime(exportObservation) {}
        let pairing = try AgentSync.decode(SyncPairing.self, from: Data(contentsOf: pairingURL))
        XCTAssertNoThrow(try pairing.validate())
        XCTAssertEqual(pairing.certificateSHA256.count, 64)
        XCTAssertTrue(pairing.token.count >= 32)
        XCTAssertFalse(String(data: try Data(contentsOf: pairingURL), encoding: .utf8)!.contains("password"))

        let disabled = expectation(description: "Receiver disabled")
        let disabledObservation = receiver.$enabled.filter { !$0 }.prefix(1).sink { _ in disabled.fulfill() }
        receiver.disable()
        wait(for: [disabled], timeout: 10)
        withExtendedLifetime(disabledObservation) {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: folder).appendingPathComponent("lan-sync/receiver.json").path))
    }
}
