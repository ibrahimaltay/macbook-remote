import CryptoKit
import Foundation
@testable import RemoteSecurity
import XCTest

final class SecureSessionTests: XCTestCase {
    private func sessions(transcript: Data = Data("test transcript".utf8)) throws -> (SecureSession, SecureSession) {
        let clientKey = Curve25519.KeyAgreement.PrivateKey()
        let serverKey = Curve25519.KeyAgreement.PrivateKey()
        return (
            SecureSession(sharedSecret: try clientKey.sharedSecretFromKeyAgreement(with: serverKey.publicKey), transcript: transcript, role: .client),
            SecureSession(sharedSecret: try serverKey.sharedSecretFromKeyAgreement(with: clientKey.publicKey), transcript: transcript, role: .server)
        )
    }

    func testRoundTripAndReplayProtection() throws {
        var (client, server) = try sessions()
        let plaintext = Data("private text".utf8)
        let record = try client.seal(plaintext, lane: .clientInput)
        XCTAssertNil(record.range(of: plaintext))
        XCTAssertEqual(try server.open(record, lane: .clientInput), plaintext)
        XCTAssertThrowsError(try server.open(record, lane: .clientInput)) { XCTAssertEqual($0 as? SecureError, .replay) }
    }

    func testTamperingDoesNotConsumeSequence() throws {
        var (client, server) = try sessions()
        let record = try client.seal(Data([42]), lane: .clientControl)
        var tampered = record
        tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try server.open(tampered, lane: .clientControl)) { XCTAssertEqual($0 as? SecureError, .authenticationFailed) }
        XCTAssertEqual(try server.open(record, lane: .clientControl), Data([42]))
    }

    func testIndependentLanesAndDirections() throws {
        var (client, server) = try sessions()
        let control = try client.seal(Data([1]), lane: .clientControl)
        let input = try client.seal(Data([1]), lane: .clientInput)
        let reply = try server.seal(Data([1]), lane: .serverControl)
        XCTAssertNotEqual(Data(control.dropFirst(12)), Data(input.dropFirst(12)))
        XCTAssertNotEqual(Data(control.dropFirst(12)), Data(reply.dropFirst(12)))
        XCTAssertEqual(try server.open(input, lane: .clientInput), Data([1]))
        XCTAssertEqual(try server.open(control, lane: .clientControl), Data([1]))
        XCTAssertEqual(try client.open(reply, lane: .serverControl), Data([1]))
        XCTAssertThrowsError(try server.seal(Data([1]), lane: .clientInput))
    }

    func testOldSessionAndModifiedHeaderFail() throws {
        var (client, server) = try sessions()
        var (_, otherServer) = try sessions()
        let record = try client.seal(Data([1]), lane: .clientInput)
        XCTAssertThrowsError(try otherServer.open(record, lane: .clientInput))
        var tampered = record
        tampered[9] = 1
        XCTAssertThrowsError(try server.open(tampered, lane: .clientInput))
    }

    func testSizeAndControlOrdering() throws {
        var (client, server) = try sessions()
        XCTAssertThrowsError(try client.seal(Data(), lane: .clientInput))
        let largest = Data(repeating: 1, count: 8192 - 28)
        let record = try client.seal(largest, lane: .clientInput)
        XCTAssertEqual(record.count, 8192)
        XCTAssertEqual(try server.open(record, lane: .clientInput), largest)
        XCTAssertThrowsError(try client.seal(Data(repeating: 1, count: largest.count + 1), lane: .clientInput))
        let first = try client.seal(Data([1]), lane: .clientControl)
        let second = try client.seal(Data([2]), lane: .clientControl)
        XCTAssertThrowsError(try server.open(second, lane: .clientControl))
        XCTAssertEqual(try server.open(first, lane: .clientControl), Data([1]))
        XCTAssertEqual(try server.open(second, lane: .clientControl), Data([2]))
    }
}