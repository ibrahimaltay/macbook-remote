import CryptoKit
import Foundation
import RemoteSecurity
import Security
@testable import RemoteServerCore
import XCTest

final class RemoteServerTrustResetTests: XCTestCase {
    private final class MemoryKeyStore: SecureKeyStore {
        var records: [String: Data] = [:]
        var deleteError: SecureError?

        func load(_ account: String) throws -> Data? { records[account] }
        func save(_ data: Data, account: String) throws { records[account] = data }
        func delete(_ account: String) throws {
            if let deleteError { throw deleteError }
            records.removeValue(forKey: account)
        }
    }

    private func seed(_ store: MemoryKeyStore) throws -> Data {
        let trust = PeerTrustStore(store: store)
        let identity = try trust.identity().rawRepresentation
        for name in ["Phone", "Other Phone"] {
            _ = try trust.approve(
                publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
                name: name, transportID: UUID()
            )
        }
        return identity
    }

    private func reset(_ server: RemoteServer, succeeds: Bool) {
        let completed = expectation(description: "Trust reset completes on main queue")
        server.onTrustReset = { result in
            XCTAssertTrue(Thread.isMainThread)
            switch result {
            case .succeeded: XCTAssertTrue(succeeds)
            case .failed(let message):
                XCTAssertFalse(succeeds)
                XCTAssertTrue(message.contains("Retry Forget All Devices"))
            }
            XCTAssertEqual(server.trustResetBlocked, !succeeds)
            completed.fulfill()
        }
        server.forgetAll()
        wait(for: [completed], timeout: 3)
        server.onTrustReset = nil
    }

    func testResetWhileStoppedClearsEveryApprovalAndPreservesIdentity() throws {
        let store = MemoryKeyStore()
        let identity = try seed(store)
        let server = RemoteServer(keyStore: store)
        let snapshot = expectation(description: "Empty device snapshot")
        server.onDevices = { devices in
            XCTAssertTrue(devices.isEmpty)
            snapshot.fulfill()
        }
        reset(server, succeeds: true)
        wait(for: [snapshot], timeout: 3)
        XCTAssertEqual(try PeerTrustStore(store: store).peers(), [])
        XCTAssertEqual(store.records["identity-v2"], identity)
        server.onDevices = nil
        reset(server, succeeds: true)
    }

    func testFailedResetBlocksAccessAcrossStopUntilSuccessfulRetry() throws {
        let store = MemoryKeyStore()
        let identity = try seed(store)
        let original = store.records
        let server = RemoteServer(keyStore: store)
        store.deleteError = .keychain(errSecAuthFailed)
        server.onDevices = { devices in XCTAssertTrue(devices.isEmpty) }
        reset(server, succeeds: false)
        XCTAssertEqual(store.records, original)
        let stopped = expectation(description: "Stopping preserves reset block")
        server.onStatus = { status in
            XCTAssertEqual(status, .stopped)
            XCTAssertTrue(server.trustResetBlocked)
            stopped.fulfill()
        }
        server.approve(UUID())
        server.stop()
        wait(for: [stopped], timeout: 3)
        XCTAssertEqual(store.records, original)
        store.deleteError = nil
        reset(server, succeeds: true)
        XCTAssertEqual(try PeerTrustStore(store: store).peers(), [])
        XCTAssertEqual(store.records["identity-v2"], identity)
        server.onStatus = nil
        server.onDevices = nil
    }

    func testResetWithMissingIdentityFailsWithoutDiscardingTrust() throws {
        let store = MemoryKeyStore()
        _ = try seed(store)
        store.records.removeValue(forKey: "identity-v2")
        let original = store.records
        let server = RemoteServer(keyStore: store)
        reset(server, succeeds: false)
        XCTAssertEqual(store.records, original)
        XCTAssertThrowsError(try PeerTrustStore(store: store).identity())
    }

    func testResetRecoversTrustReadFailureWithoutChangingStoppedState() throws {
        let store = MemoryKeyStore()
        let identity = try seed(store)
        store.records["peers-v2"] = Data("not json".utf8)
        let server = RemoteServer(keyStore: store)
        let failed = expectation(description: "Malformed trust reports failure")
        server.onStatus = { status in
            if case .failed = status { failed.fulfill() }
        }
        server.stop()
        wait(for: [failed], timeout: 3)
        let recovered = expectation(description: "Trust reset restores prior status")
        server.onStatus = { status in
            XCTAssertEqual(status, .stopped)
            recovered.fulfill()
        }
        reset(server, succeeds: true)
        wait(for: [recovered], timeout: 3)
        XCTAssertEqual(store.records["identity-v2"], identity)
        XCTAssertEqual(try PeerTrustStore(store: store).peers(), [])
        server.onStatus = nil
    }
}