import CryptoKit
import Foundation
import RemoteProtocol

public final class SecureHandshake {
    private enum Phase {
        case fresh, clientHello, serverHello, clientFinish, ready, failed, consumed
    }

    public private(set) var peerPublicKey: Data?
    private let identity: Curve25519.Signing.PrivateKey
    private let agreement = Curve25519.KeyAgreement.PrivateKey()
    private let nonce = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    private let role: SecureRole
    private let pinnedPeer: Data?
    private var phase: Phase = .fresh
    private var clientHello = Data()
    private var transcript = Data()
    private var session: SecureSession?

    public init(identity: Curve25519.Signing.PrivateKey, role: SecureRole, pinnedPeer: Data? = nil) {
        self.identity = identity
        self.role = role
        self.pinnedPeer = pinnedPeer
    }

    public func start() throws -> Data {
        guard role == .client, phase == .fresh else { throw SecureError.wrongPhase }
        clientHello = hello(roleByte: 1)
        phase = .clientHello
        return clientHello
    }

    public func receiveClientHello(_ message: Data) throws -> Data {
        guard role == .server, phase == .fresh else { throw SecureError.wrongPhase }
        phase = .failed
        let peer = try parseHello(message, roleByte: 1)
        try checkPin(peer.identity)
        let serverHello = hello(roleByte: 2)
        transcript = Data("LazyRemote/handshake/v2".utf8) + message + serverHello
        let secret = try agreement.sharedSecretFromKeyAgreement(with: peer.agreement)
        session = SecureSession(sharedSecret: secret, transcript: transcript, role: .server)
        peerPublicKey = peer.identity
        phase = .serverHello
        return serverHello + (try identity.signature(for: transcript + Data("server".utf8)))
    }

    public func receiveServerHello(_ message: Data) throws -> Data {
        guard role == .client, phase == .clientHello else { throw SecureError.wrongPhase }
        phase = .failed
        guard message.count == 162 else { throw SecureError.malformedMessage }
        let unsigned = Data(message.prefix(98))
        let peer = try parseHello(unsigned, roleByte: 2)
        try checkPin(peer.identity)
        transcript = Data("LazyRemote/handshake/v2".utf8) + clientHello + unsigned
        let verifyingKey = try Curve25519.Signing.PublicKey(rawRepresentation: peer.identity)
        guard verifyingKey.isValidSignature(message.suffix(64), for: transcript + Data("server".utf8)) else {
            throw SecureError.invalidSignature
        }
        let secret = try agreement.sharedSecretFromKeyAgreement(with: peer.agreement)
        var session = SecureSession(sharedSecret: secret, transcript: transcript, role: .client)
        let confirmation = try session.seal(SecureMessage.finish.encoded(), lane: .clientControl)
        let signature = try identity.signature(for: transcript + Data("client".utf8))
        self.session = session
        peerPublicKey = peer.identity
        phase = .clientFinish
        return Data([2, 3]) + signature + confirmation
    }

    public func receiveClientFinish(_ message: Data) throws -> Data {
        guard role == .server, phase == .serverHello else { throw SecureError.wrongPhase }
        phase = .failed
        let bytes = [UInt8](message)
        guard bytes.count == 95, bytes[0] == 2, bytes[1] == 3,
              let peerPublicKey, var session
        else { throw SecureError.malformedMessage }
        let verifyingKey = try Curve25519.Signing.PublicKey(rawRepresentation: peerPublicKey)
        guard verifyingKey.isValidSignature(Data(bytes[2..<66]), for: transcript + Data("client".utf8)) else {
            throw SecureError.invalidSignature
        }
        let plaintext = try session.open(Data(bytes.dropFirst(66)), lane: .clientControl)
        guard try SecureMessage(wire: plaintext) == .finish else { throw SecureError.malformedMessage }
        let reply = try session.seal(SecureMessage.finish.encoded(), lane: .serverControl)
        self.session = session
        phase = .ready
        return reply
    }

    public func receiveServerFinish(_ message: Data) throws {
        guard role == .client, phase == .clientFinish else { throw SecureError.wrongPhase }
        phase = .failed
        guard var session else { throw SecureError.wrongPhase }
        let plaintext = try session.open(message, lane: .serverControl)
        guard try SecureMessage(wire: plaintext) == .finish else { throw SecureError.malformedMessage }
        self.session = session
        phase = .ready
    }

    public func takeSession() throws -> SecureSession {
        guard phase == .ready, let session else { throw SecureError.wrongPhase }
        self.session = nil
        phase = .consumed
        return session
    }

    private func hello(roleByte: UInt8) -> Data {
        Data([2, roleByte]) + identity.publicKey.rawRepresentation + agreement.publicKey.rawRepresentation + nonce
    }

    private func parseHello(_ message: Data, roleByte: UInt8) throws -> (identity: Data, agreement: Curve25519.KeyAgreement.PublicKey) {
        let bytes = [UInt8](message)
        guard bytes.count == 98, bytes[1] == roleByte else { throw SecureError.malformedMessage }
        guard bytes[0] == 2 else { throw SecureError.unsupportedVersion }
        return (
            Data(bytes[2..<34]),
            try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(bytes[34..<66]))
        )
    }

    private func checkPin(_ publicKey: Data) throws {
        if let pinnedPeer, pinnedPeer != publicKey { throw SecureError.identityChanged }
    }
}