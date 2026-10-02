import CryptoKit
import Foundation

public enum SecureError: Error, Equatable {
    case malformedMessage
    case unsupportedVersion
    case identityChanged
    case invalidSignature
    case wrongPhase
    case replay
    case sequenceExhausted
    case oversizedMessage
    case authenticationFailed
    case expired
    case keychain(Int32)
}

public enum SecureLane: UInt8, Sendable, CaseIterable {
    case clientControl = 1
    case serverControl = 2
    case clientInput = 3
}

public enum SecureRole: Sendable {
    case client
    case server
}

public struct SecureSession {
    private let role: SecureRole
    private let binding: Data
    private let keys: [SecureLane: SymmetricKey]
    private let prefixes: [SecureLane: Data]
    private var sent: [SecureLane: UInt64] = [:]
    private var received: [SecureLane: UInt64] = [:]

    public init(sharedSecret: SharedSecret, transcript: Data, role: SecureRole) {
        self.role = role
        binding = Data(SHA256.hash(data: transcript))
        var keys: [SecureLane: SymmetricKey] = [:]
        var prefixes: [SecureLane: Data] = [:]
        for lane in SecureLane.allCases {
            let material = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: binding,
                sharedInfo: Data("LazyRemote/v2/lane/\(lane.rawValue)".utf8),
                outputByteCount: 36
            ).withUnsafeBytes { Data($0) }
            keys[lane] = SymmetricKey(data: material.prefix(32))
            prefixes[lane] = Data(material.suffix(4))
        }
        self.keys = keys
        self.prefixes = prefixes
    }

    public mutating func seal(_ plaintext: Data, lane: SecureLane) throws -> Data {
        guard maySend(lane) else { throw SecureError.wrongPhase }
        guard !plaintext.isEmpty, plaintext.count <= 8192 - 28 else { throw SecureError.oversizedMessage }
        let sequence = sent[lane] ?? 0
        guard sequence < UInt64.max else { throw SecureError.sequenceExhausted }
        let header = Data([2, lane.rawValue]) + sequence.wireBytes
            + UInt16(plaintext.count + 16).wireBytes
        guard let key = keys[lane], let prefix = prefixes[lane] else { throw SecureError.wrongPhase }
        sent[lane] = sequence + 1
        let nonce = try AES.GCM.Nonce(data: prefix + sequence.wireBytes)
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: binding + header)
        return header + sealed.ciphertext + sealed.tag
    }

    public mutating func open(_ record: Data, lane: SecureLane) throws -> Data {
        guard !maySend(lane) else { throw SecureError.wrongPhase }
        let bytes = [UInt8](record)
        guard bytes.count >= 29, bytes.count <= 8192 else { throw SecureError.malformedMessage }
        guard bytes[0] == 2 else { throw SecureError.unsupportedVersion }
        guard bytes[1] == lane.rawValue,
              Int(UInt16(wireBytes: bytes[10..<12])) == bytes.count - 12
        else { throw SecureError.malformedMessage }
        let sequence = UInt64(wireBytes: bytes[2..<10])
        guard sequence < UInt64.max else { throw SecureError.sequenceExhausted }
        if let previous = received[lane], sequence <= previous { throw SecureError.replay }
        if lane != .clientInput, sequence != (received[lane].map { $0 + 1 } ?? 0) {
            throw SecureError.replay
        }
        guard let key = keys[lane], let prefix = prefixes[lane] else { throw SecureError.wrongPhase }
        do {
            let sealed = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: prefix + sequence.wireBytes),
                ciphertext: Data(bytes[12..<(bytes.count - 16)]),
                tag: Data(bytes.suffix(16))
            )
            let plaintext = try AES.GCM.open(sealed, using: key, authenticating: binding + Data(bytes.prefix(12)))
            received[lane] = sequence
            return plaintext
        } catch {
            throw SecureError.authenticationFailed
        }
    }

    private func maySend(_ lane: SecureLane) -> Bool {
        switch role {
        case .client: lane != .serverControl
        case .server: lane == .serverControl
        }
    }
}

extension FixedWidthInteger {
    var wireBytes: Data {
        withUnsafeBytes(of: bigEndian) { Data($0) }
    }

    init(wireBytes: some Collection<UInt8>) {
        self = wireBytes.reduce(0) { ($0 << 8) | Self($1) }
    }
}