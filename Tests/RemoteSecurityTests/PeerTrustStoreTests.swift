import CryptoKit
import Foundation
import Security
@testable import RemoteSecurity
import XCTest

final class PeerTrustStoreTests: XCTestCase {
    private final class MemoryKeyStore: SecureKeyStore {
        var records: [String: Data] = [:]
        var loadError: SecureError?
        var saveError: SecureError?
        var deleteError: SecureError?
        var savedAccounts: [String] = []

        func load(_ account: String) throws -> Data? {
            if let loadError { throw loadError }
            return records[account]
        }

        func save(_ data: Data, account: String) throws {
            savedAccounts.append(account)
            if let saveError { throw saveError }
            records[account] = data
        }

        func delete(_ account: String) throws {
            if let deleteError { throw deleteError }
            records.removeValue(forKey: account)
        }
    }

    private func publicKey() -> Data {
        Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
    }

    func testIdentityPersistsAcrossReloadAndSigns() throws {
        let store = MemoryKeyStore()
        let identity = try PeerTrustStore(store: store).identity()
        let reloaded = try PeerTrustStore(store: store).identity()
        XCTAssertEqual(identity.rawRepresentation, reloaded.rawRepresentation)
        XCTAssertEqual(store.records["identity-v2"], identity.rawRepresentation)
        XCTAssertEqual(store.savedAccounts, ["identity-v2"])
        let message = Data("identity proof".utf8)
        XCTAssertTrue(reloaded.publicKey.isValidSignature(try identity.signature(for: message), for: message))
    }

    func testCorruptIdentityNeverRotates() throws {
        for count in [0, 31, 33] {
            let store = MemoryKeyStore()
            let corrupt = Data(repeating: 1, count: count)
            store.records["identity-v2"] = corrupt
            XCTAssertThrowsError(try PeerTrustStore(store: store).identity()) {
                XCTAssertEqual($0 as? SecureError, .malformedMessage)
            }
            XCTAssertEqual(store.records["identity-v2"], corrupt)
            XCTAssertTrue(store.savedAccounts.isEmpty)
        }
    }

    func testLockedOrFailedIdentityLoadNeverGenerates() throws {
        for error in [SecureError.keychain(errSecInteractionNotAllowed), .keychain(errSecAuthFailed)] {
            let store = MemoryKeyStore()
            let original = Curve25519.Signing.PrivateKey().rawRepresentation
            store.records["identity-v2"] = original
            store.loadError = error
            XCTAssertThrowsError(try PeerTrustStore(store: store).identity()) {
                XCTAssertEqual($0 as? SecureError, error)
            }
            XCTAssertTrue(store.savedAccounts.isEmpty)
            XCTAssertEqual(store.records["identity-v2"], original)
            store.loadError = nil
            XCTAssertEqual(try PeerTrustStore(store: store).identity().rawRepresentation, original)
        }
    }

    func testIdentitySaveFailureThrows() {
        let store = MemoryKeyStore()
        store.saveError = .keychain(errSecNotAvailable)
        XCTAssertThrowsError(try PeerTrustStore(store: store).identity()) {
            XCTAssertEqual($0 as? SecureError, .keychain(errSecNotAvailable))
        }
        XCTAssertNil(store.records["identity-v2"])
    }

    func testMissingIdentityWithExistingTrustNeverRotates() throws {
        let store = MemoryKeyStore()
        let trust = PeerTrustStore(store: store)
        _ = try trust.identity()
        _ = try trust.approve(publicKey: publicKey(), name: "Phone", transportID: UUID())
        store.records.removeValue(forKey: "identity-v2")
        let savedCount = store.savedAccounts.count
        XCTAssertThrowsError(try trust.identity()) {
            XCTAssertEqual($0 as? SecureError, .identityChanged)
        }
        XCTAssertNil(store.records["identity-v2"])
        XCTAssertEqual(store.savedAccounts.count, savedCount)
    }

    func testApprovalsPersistAndLookUpByKeyAndTransport() throws {
        let store = MemoryKeyStore()
        let trust = PeerTrustStore(store: store)
        XCTAssertEqual(try trust.peers(), [])
        XCTAssertNil(try trust.peer(for: UUID()))
        XCTAssertNil(try trust.peer(publicKey: publicKey()))
        let transportID = UUID()
        let first = try trust.approve(publicKey: publicKey(), name: "Phone", transportID: transportID)
        let second = try trust.approve(publicKey: publicKey(), name: "Mac", transportID: nil)
        XCTAssertNotEqual(first.id, second.id)
        let reloaded = PeerTrustStore(store: store)
        XCTAssertEqual(try reloaded.peers(), [first, second])
        XCTAssertEqual(try reloaded.peer(for: transportID), first)
        XCTAssertEqual(try reloaded.peer(publicKey: second.publicKey), second)
        let data = try XCTUnwrap(store.records["peers-v2"])
        XCTAssertEqual(try JSONDecoder().decode([TrustedPeer].self, from: data), [first, second])
    }

    func testExistingKeyKeepsIDAndUpdatesNameAndTransport() throws {
        let trust = PeerTrustStore(store: MemoryKeyStore())
        let first = try trust.approve(publicKey: publicKey(), name: "Old", transportID: UUID())
        let newTransport = UUID()
        let updated = try trust.approve(publicKey: first.publicKey, name: "New", transportID: newTransport)
        XCTAssertEqual(updated.id, first.id)
        XCTAssertEqual(updated.name, "New")
        XCTAssertEqual(updated.transportID, newTransport)
        XCTAssertNil(try trust.peer(for: XCTUnwrap(first.transportID)))
        let renamed = try trust.approve(publicKey: first.publicKey, name: "Renamed", transportID: nil)
        XCTAssertEqual(renamed.transportID, newTransport)
        XCTAssertEqual(try trust.peers(), [renamed])
    }

    func testPinnedTransportRejectsDifferentPublicKey() throws {
        let store = MemoryKeyStore()
        let trust = PeerTrustStore(store: store)
        let transportID = UUID()
        let pinned = try trust.approve(publicKey: publicKey(), name: "Phone", transportID: transportID)
        let other = try trust.approve(publicKey: publicKey(), name: "Other", transportID: nil)
        let original = store.records
        for key in [publicKey(), other.publicKey] {
            XCTAssertThrowsError(try trust.approve(publicKey: key, name: "Replacement", transportID: transportID)) {
                XCTAssertEqual($0 as? SecureError, .identityChanged)
            }
        }
        XCTAssertEqual(store.records, original)
        XCTAssertEqual(try trust.peer(for: transportID), pinned)
    }

    func testForgetAllowsFreshApprovalAndPreservesIdentity() throws {
        let store = MemoryKeyStore()
        let trust = PeerTrustStore(store: store)
        let identity = try trust.identity().rawRepresentation
        let transportID = UUID()
        let first = try trust.approve(publicKey: publicKey(), name: "Phone", transportID: transportID)
        let retained = try trust.approve(publicKey: publicKey(), name: "Mac", transportID: nil)
        try trust.forget(first.id)
        XCTAssertEqual(try PeerTrustStore(store: store).peers(), [retained])
        XCTAssertNil(try trust.peer(publicKey: first.publicKey))
        XCTAssertNil(try trust.peer(for: transportID))
        let replacement = try trust.approve(publicKey: publicKey(), name: "Replacement", transportID: transportID)
        XCTAssertNotEqual(replacement.id, first.id)
        try trust.forget(replacement.id)
        let reapproved = try trust.approve(publicKey: first.publicKey, name: "Phone", transportID: transportID)
        XCTAssertNotEqual(reapproved.id, first.id)
        try trust.forget(UUID())
        XCTAssertEqual(try trust.identity().rawRepresentation, identity)
    }

    func testInvalidKeysAndNamesAreRejectedWithoutSaving() throws {
        let store = MemoryKeyStore()
        let trust = PeerTrustStore(store: store)
        for count in [0, 31, 33] {
            let key = Data(repeating: 1, count: count)
            XCTAssertThrowsError(try trust.approve(publicKey: key, name: "Phone", transportID: nil)) {
                XCTAssertEqual($0 as? SecureError, .malformedMessage)
            }
            XCTAssertThrowsError(try trust.peer(publicKey: key)) {
                XCTAssertEqual($0 as? SecureError, .malformedMessage)
            }
        }
        for name in ["", String(repeating: "a", count: 129), String(repeating: "\u{00e9}", count: 65)] {
            XCTAssertThrowsError(try trust.approve(publicKey: publicKey(), name: name, transportID: nil)) {
                XCTAssertEqual($0 as? SecureError, .malformedMessage)
            }
        }
        XCTAssertTrue(store.savedAccounts.isEmpty)
        let asciiName = String(repeating: "a", count: 128)
        let unicodeName = String(repeating: "\u{00e9}", count: 64)
        XCTAssertEqual(try trust.approve(publicKey: publicKey(), name: asciiName, transportID: nil).name, asciiName)
        XCTAssertEqual(try trust.approve(publicKey: publicKey(), name: unicodeName, transportID: nil).name, unicodeName)
    }

    func testCorruptPeerRecordsFailClosedForEveryOperation() throws {
        let valid = TrustedPeer(id: UUID(), publicKey: publicKey(), name: "Phone", transportID: UUID())
        let sameID = TrustedPeer(id: valid.id, publicKey: publicKey(), name: "Other", transportID: nil)
        let sameKey = TrustedPeer(id: UUID(), publicKey: valid.publicKey, name: "Other", transportID: nil)
        let sameTransport = TrustedPeer(id: UUID(), publicKey: publicKey(), name: "Other", transportID: valid.transportID)
        let invalidKey = TrustedPeer(id: UUID(), publicKey: Data(), name: "Phone", transportID: nil)
        let emptyName = TrustedPeer(id: UUID(), publicKey: publicKey(), name: "", transportID: nil)
        let longName = TrustedPeer(id: UUID(), publicKey: publicKey(), name: String(repeating: "\u{00e9}", count: 65), transportID: nil)
        let arrays = [[valid, sameID], [valid, sameKey], [valid, sameTransport], [invalidKey], [emptyName], [longName]]
        let records = try arrays.map { try JSONEncoder().encode($0) }
            + [Data(), Data("not json".utf8), Data("{}".utf8), Data("[{}]".utf8)]
        for record in records {
            let store = MemoryKeyStore()
            store.records["peers-v2"] = record
            let trust = PeerTrustStore(store: store)
            XCTAssertThrowsError(try trust.peers()) { XCTAssertEqual($0 as? SecureError, .malformedMessage) }
            XCTAssertThrowsError(try trust.peer(for: UUID())) { XCTAssertEqual($0 as? SecureError, .malformedMessage) }
            XCTAssertThrowsError(try trust.peer(publicKey: valid.publicKey)) { XCTAssertEqual($0 as? SecureError, .malformedMessage) }
            XCTAssertThrowsError(try trust.approve(publicKey: publicKey(), name: "New", transportID: nil)) {
                XCTAssertEqual($0 as? SecureError, .malformedMessage)
            }
            XCTAssertThrowsError(try trust.forget(valid.id)) { XCTAssertEqual($0 as? SecureError, .malformedMessage) }
            XCTAssertEqual(store.records["peers-v2"], record)
            XCTAssertTrue(store.savedAccounts.isEmpty)
        }
    }

    func testPeerLoadAndSaveFailuresDoNotChangeTrust() throws {
        let store = MemoryKeyStore()
        let trust = PeerTrustStore(store: store)
        let original = try trust.approve(publicKey: publicKey(), name: "Phone", transportID: UUID())
        let records = store.records
        store.loadError = .keychain(errSecInteractionNotAllowed)
        XCTAssertThrowsError(try trust.peers()) { XCTAssertEqual($0 as? SecureError, store.loadError) }
        XCTAssertThrowsError(try trust.approve(publicKey: publicKey(), name: "New", transportID: nil)) {
            XCTAssertEqual($0 as? SecureError, store.loadError)
        }
        XCTAssertThrowsError(try trust.forget(original.id)) { XCTAssertEqual($0 as? SecureError, store.loadError) }
        store.loadError = nil
        store.saveError = .keychain(errSecNotAvailable)
        XCTAssertThrowsError(try trust.approve(publicKey: publicKey(), name: "New", transportID: nil)) {
            XCTAssertEqual($0 as? SecureError, store.saveError)
        }
        XCTAssertThrowsError(try trust.approve(publicKey: original.publicKey, name: "Rename", transportID: nil)) {
            XCTAssertEqual($0 as? SecureError, store.saveError)
        }
        XCTAssertThrowsError(try trust.forget(original.id)) { XCTAssertEqual($0 as? SecureError, store.saveError) }
        XCTAssertEqual(store.records, records)
        XCTAssertEqual(try PeerTrustStore(store: store).peers(), [original])
    }

    func testLegacyAccountsAreNotMigrated() throws {
        let store = MemoryKeyStore()
        store.records["identity"] = Curve25519.Signing.PrivateKey().rawRepresentation
        store.records["peers"] = try JSONEncoder().encode([
            TrustedPeer(id: UUID(), publicKey: publicKey(), name: "Legacy", transportID: UUID())
        ])
        let trust = PeerTrustStore(store: store)
        XCTAssertEqual(try trust.peers(), [])
        XCTAssertNotEqual(try trust.identity().rawRepresentation, store.records["identity"])
        XCTAssertNil(store.records["peers-v2"])
    }
}