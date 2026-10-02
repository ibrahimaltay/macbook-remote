import CryptoKit
import Foundation
import RemoteProtocol
import RemoteSecurity
@testable import RemoteServerCore
import XCTest

final class SecureInputDecoderTests: XCTestCase {
    private func sessions() throws -> (SecureSession, SecureSession) {
        let client = Curve25519.KeyAgreement.PrivateKey()
        let server = Curve25519.KeyAgreement.PrivateKey()
        return (
            SecureSession(sharedSecret: try client.sharedSecretFromKeyAgreement(with: server.publicKey), transcript: Data("decoder test".utf8), role: .client),
            SecureSession(sharedSecret: try server.sharedSecretFromKeyAgreement(with: client.publicKey), transcript: Data("decoder test".utf8), role: .server)
        )
    }

    func testApprovalRequiredAndRevocationBlocksInput() throws {
        var (client, server) = try sessions()
        let key = SecureMessage.key(KeyEvent(command: .up, isDown: true))
        let record = try client.seal(key.encoded(), lane: .clientInput)
        XCTAssertThrowsError(try SecureInputDecoder.decode(record, session: &server, approved: false))
        XCTAssertEqual(try SecureInputDecoder.decode(record, session: &server, approved: true), key)
        let next = try client.seal(key.encoded(), lane: .clientInput)
        XCTAssertThrowsError(try SecureInputDecoder.decode(next, session: &server, approved: false))
    }

    func testOnlyValidEncryptedInputCanReachDispatcher() throws {
        var (client, server) = try sessions()
        let text = SecureMessage.text(id: 1, value: "\u{1F680} text")
        let valid = try client.seal(text.encoded(), lane: .clientInput)
        XCTAssertThrowsError(try SecureInputDecoder.decode(KeyEvent(command: .up, isDown: true).encoded, session: &server, approved: true))
        var tampered = valid
        tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try SecureInputDecoder.decode(tampered, session: &server, approved: true))
        XCTAssertEqual(try SecureInputDecoder.decode(valid, session: &server, approved: true), text)
        XCTAssertThrowsError(try SecureInputDecoder.decode(valid, session: &server, approved: true))
        let invalid = try client.seal(Data([3, 0, 0, 0, 0, 0, 0, 0, 2, 0xFF]), lane: .clientInput)
        XCTAssertThrowsError(try SecureInputDecoder.decode(invalid, session: &server, approved: true))
    }

    func testControlMessagesCannotBecomeInput() throws {
        var (client, server) = try sessions()
        for control in [SecureMessage.approved, .pending, .revoked, .finish, .name("Phone"), .textResult(id: 1, success: true)] {
            let record = try client.seal(control.encoded(), lane: .clientInput)
            XCTAssertThrowsError(try SecureInputDecoder.decode(record, session: &server, approved: true))
        }
        let pointer = SecureMessage.pointer(.move(dx: 1, dy: -1))
        let valid = try client.seal(pointer.encoded(), lane: .clientInput)
        XCTAssertEqual(try SecureInputDecoder.decode(valid, session: &server, approved: true), pointer)
    }
}