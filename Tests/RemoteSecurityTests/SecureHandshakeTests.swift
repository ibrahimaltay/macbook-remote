import CryptoKit
import Foundation
import RemoteProtocol
@testable import RemoteSecurity
import XCTest

final class SecureHandshakeTests: XCTestCase {
    private func complete(client: SecureHandshake, server: SecureHandshake) throws -> (SecureSession, SecureSession) {
        let hello = try client.start()
        let response = try server.receiveClientHello(hello)
        let finish = try client.receiveServerHello(response)
        let confirmation = try server.receiveClientFinish(finish)
        try client.receiveServerFinish(confirmation)
        return (try client.takeSession(), try server.takeSession())
    }

    func testPinnedHandshakeAndKeyConfirmation() throws {
        let clientIdentity = Curve25519.Signing.PrivateKey()
        let serverIdentity = Curve25519.Signing.PrivateKey()
        let client = SecureHandshake(identity: clientIdentity, role: .client, pinnedPeer: serverIdentity.publicKey.rawRepresentation)
        let server = SecureHandshake(identity: serverIdentity, role: .server, pinnedPeer: clientIdentity.publicKey.rawRepresentation)
        var (clientSession, serverSession) = try complete(client: client, server: server)
        let record = try clientSession.seal(SecureMessage.text(id: 1, value: "Secret").encoded(), lane: .clientInput)
        XCTAssertEqual(try SecureMessage(wire: serverSession.open(record, lane: .clientInput)), .text(id: 1, value: "Secret"))
        XCTAssertEqual(client.peerPublicKey, serverIdentity.publicKey.rawRepresentation)
        XCTAssertEqual(server.peerPublicKey, clientIdentity.publicKey.rawRepresentation)
        XCTAssertThrowsError(try client.takeSession())
    }

    func testChangedServerPinBlocksHandshake() throws {
        let client = SecureHandshake(identity: .init(), role: .client, pinnedPeer: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        let server = SecureHandshake(identity: .init(), role: .server)
        let response = try server.receiveClientHello(client.start())
        XCTAssertThrowsError(try client.receiveServerHello(response)) { XCTAssertEqual($0 as? SecureError, .identityChanged) }
        XCTAssertThrowsError(try client.takeSession())
    }

    func testChangedClientPinBlocksHandshake() throws {
        let client = SecureHandshake(identity: .init(), role: .client)
        let server = SecureHandshake(identity: .init(), role: .server, pinnedPeer: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        XCTAssertThrowsError(try server.receiveClientHello(client.start())) { XCTAssertEqual($0 as? SecureError, .identityChanged) }
    }

    func testTamperedTranscriptAndConfirmationFail() throws {
        let client = SecureHandshake(identity: .init(), role: .client)
        let server = SecureHandshake(identity: .init(), role: .server)
        var response = try server.receiveClientHello(client.start())
        response[97] ^= 1
        XCTAssertThrowsError(try client.receiveServerHello(response)) { XCTAssertEqual($0 as? SecureError, .invalidSignature) }
        XCTAssertThrowsError(try client.receiveServerHello(response)) { XCTAssertEqual($0 as? SecureError, .wrongPhase) }
        let otherClient = SecureHandshake(identity: .init(), role: .client)
        let otherServer = SecureHandshake(identity: .init(), role: .server)
        var finish = try otherClient.receiveServerHello(otherServer.receiveClientHello(otherClient.start()))
        finish[finish.count - 1] ^= 1
        XCTAssertThrowsError(try otherServer.receiveClientFinish(finish))
        XCTAssertThrowsError(try otherServer.takeSession())
    }

    func testFreshHandshakeChangesCiphertext() throws {
        let clientIdentity = Curve25519.Signing.PrivateKey()
        let serverIdentity = Curve25519.Signing.PrivateKey()
        var (first, _) = try complete(client: SecureHandshake(identity: clientIdentity, role: .client), server: SecureHandshake(identity: serverIdentity, role: .server))
        var (second, _) = try complete(client: SecureHandshake(identity: clientIdentity, role: .client), server: SecureHandshake(identity: serverIdentity, role: .server))
        XCTAssertNotEqual(try first.seal(Data([1]), lane: .clientInput), try second.seal(Data([1]), lane: .clientInput))
    }

    func testFirstUseDoesNotAuthenticateAnUnknownIdentity() throws {
        let client = SecureHandshake(identity: .init(), role: .client)
        let unknownServer = SecureHandshake(identity: .init(), role: .server)
        _ = try complete(client: client, server: unknownServer)
        XCTAssertNotNil(client.peerPublicKey)
    }

    func testRejectsLowOrderAgreementAndPrematureInput() throws {
        let client = SecureHandshake(identity: .init(), role: .client)
        let server = SecureHandshake(identity: .init(), role: .server)
        XCTAssertThrowsError(try client.takeSession())
        var hello = try client.start()
        hello.replaceSubrange(34..<66, with: Data(repeating: 0, count: 32))
        XCTAssertThrowsError(try server.receiveClientHello(hello))
        XCTAssertThrowsError(try server.takeSession())
    }
}