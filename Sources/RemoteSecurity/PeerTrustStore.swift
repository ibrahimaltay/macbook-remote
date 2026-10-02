import CryptoKit
import Foundation
import Security

public protocol SecureKeyStore: AnyObject {
    func load(_ account: String) throws -> Data?
    func save(_ data: Data, account: String) throws
    func delete(_ account: String) throws
}

public final class KeychainSecureKeyStore: SecureKeyStore {
    private let service: String

    public init(service: String) {
        self.service = service
    }

    public func load(_ account: String) throws -> Data? {
        var query = query(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecureError.keychain(status) }
        guard let data = result as? Data else { throw SecureError.malformedMessage }
        return data
    }

    public func save(_ data: Data, account: String) throws {
        let query = query(for: account)
        var attributes: [String: Any] = [kSecValueData as String: data]
        #if os(iOS)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        #endif
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw SecureError.keychain(status) }
        let addStatus = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw SecureError.keychain(addStatus) }
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(query(for: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureError.keychain(status)
        }
    }

    private func query(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

public struct TrustedPeer: Codable, Sendable, Equatable {
    public let id: UUID
    public let publicKey: Data
    public var name: String
    public var transportID: UUID?

    public init(id: UUID, publicKey: Data, name: String, transportID: UUID?) {
        self.id = id
        self.publicKey = publicKey
        self.name = name
        self.transportID = transportID
    }
}

public final class PeerTrustStore {
    private let store: any SecureKeyStore

    public init(store: any SecureKeyStore) {
        self.store = store
    }

    public func identity() throws -> Curve25519.Signing.PrivateKey {
        if let data = try store.load("identity-v2") {
            guard data.count == 32 else { throw SecureError.malformedMessage }
            do {
                return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
            } catch {
                throw SecureError.malformedMessage
            }
        }
        guard try peers().isEmpty else { throw SecureError.identityChanged }
        let identity = Curve25519.Signing.PrivateKey()
        try store.save(identity.rawRepresentation, account: "identity-v2")
        return identity
    }

    public func peers() throws -> [TrustedPeer] {
        guard let data = try store.load("peers-v2") else { return [] }
        let peers: [TrustedPeer]
        do {
            peers = try JSONDecoder().decode([TrustedPeer].self, from: data)
        } catch {
            throw SecureError.malformedMessage
        }
        var ids = Set<UUID>()
        var publicKeys = Set<Data>()
        var transportIDs = Set<UUID>()
        for peer in peers {
            try validate(publicKey: peer.publicKey, name: peer.name)
            guard ids.insert(peer.id).inserted,
                  publicKeys.insert(peer.publicKey).inserted
            else { throw SecureError.malformedMessage }
            if let transportID = peer.transportID {
                guard transportIDs.insert(transportID).inserted else {
                    throw SecureError.malformedMessage
                }
            }
        }
        return peers
    }

    public func peer(for transportID: UUID) throws -> TrustedPeer? {
        try peers().first { $0.transportID == transportID }
    }

    public func peer(publicKey: Data) throws -> TrustedPeer? {
        guard publicKey.count == 32 else { throw SecureError.malformedMessage }
        return try peers().first { $0.publicKey == publicKey }
    }

    public func approve(publicKey: Data, name: String, transportID: UUID?) throws -> TrustedPeer {
        try validate(publicKey: publicKey, name: name)
        var peers = try peers()
        if let transportID,
           let pinned = peers.first(where: { $0.transportID == transportID }),
           pinned.publicKey != publicKey {
            throw SecureError.identityChanged
        }
        let peer: TrustedPeer
        if let index = peers.firstIndex(where: { $0.publicKey == publicKey }) {
            peers[index].name = name
            if let transportID { peers[index].transportID = transportID }
            peer = peers[index]
        } else {
            peer = TrustedPeer(id: UUID(), publicKey: publicKey, name: name, transportID: transportID)
            peers.append(peer)
        }
        try store.save(JSONEncoder().encode(peers), account: "peers-v2")
        return peer
    }

    public func forget(_ id: UUID) throws {
        var peers = try peers()
        peers.removeAll { $0.id == id }
        try store.save(JSONEncoder().encode(peers), account: "peers-v2")
    }

    private func validate(publicKey: Data, name: String) throws {
        guard publicKey.count == 32, !name.isEmpty, name.utf8.count <= 128 else {
            throw SecureError.malformedMessage
        }
    }
}