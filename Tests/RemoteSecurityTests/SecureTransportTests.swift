import CryptoKit
import Foundation
import RemoteProtocol
import RemoteSecurity
import XCTest

final class SecureTransportTests: XCTestCase {
    private func transmit(_ data: Data, kind: SecureFrameKind, id: UInt64, mtu: Int) throws -> Data {
        let frames = try SecureFrame.fragment(data, kind: kind, id: id, mtu: mtu)
        var assembler = SecureFrameAssembler()
        var completed: Data?
        for (index, frame) in frames.enumerated() {
            XCTAssertLessThanOrEqual(frame.count, mtu)
            let result = try assembler.accept(frame, now: Double(index) / 1000)
            if index < frames.count - 1 { XCTAssertNil(result) }
            completed = result?.data ?? completed
        }
        return try XCTUnwrap(completed)
    }

    private func connect(mtu: Int) throws -> (SecureSession, SecureSession) {
        let client = SecureHandshake(identity: .init(), role: .client)
        let server = SecureHandshake(identity: .init(), role: .server)
        let hello = try transmit(client.start(), kind: .clientHello, id: 1, mtu: mtu)
        let reply = try transmit(server.receiveClientHello(hello), kind: .serverHello, id: 0, mtu: mtu)
        let finish = try transmit(client.receiveServerHello(reply), kind: .clientFinish, id: 2, mtu: mtu)
        let confirmation = try transmit(server.receiveClientFinish(finish), kind: .encryptedControl, id: 1, mtu: mtu)
        try client.receiveServerFinish(confirmation)
        return (try client.takeSession(), try server.takeSession())
    }

    func testFragmentedHandshakeApprovalTextAndReceipt() throws {
        for mtu in [20, 185, 244] {
            var (client, server) = try connect(mtu: mtu)
            let name = try client.seal(SecureMessage.name("Phone").encoded(), lane: .clientControl)
            let assembledName = try transmit(name, kind: .encryptedControl, id: 3, mtu: mtu)
            XCTAssertEqual(try SecureMessage(wire: server.open(assembledName, lane: .clientControl)), .name("Phone"))
            let pending = try server.seal(SecureMessage.pending.encoded(), lane: .serverControl)
            XCTAssertEqual(try SecureMessage(wire: client.open(transmit(pending, kind: .encryptedControl, id: 2, mtu: mtu), lane: .serverControl)), .pending)
            let approved = try server.seal(SecureMessage.approved.encoded(), lane: .serverControl)
            XCTAssertEqual(try SecureMessage(wire: client.open(transmit(approved, kind: .encryptedControl, id: 3, mtu: mtu), lane: .serverControl)), .approved)
            let text = String(repeating: "\u{1F680}", count: 1024)
            XCTAssertEqual(text.utf8.count, 4096)
            let sealed = try client.seal(SecureMessage.text(id: 42, value: text).encoded(), lane: .clientInput)
            let frames = try SecureFrame.fragment(sealed, kind: .encryptedInput, id: 4, mtu: mtu)
            for frame in frames { XCTAssertNil(frame.range(of: Data(text.utf8.prefix(16)))) }
            let received = try server.open(transmit(sealed, kind: .encryptedInput, id: 4, mtu: mtu), lane: .clientInput)
            XCTAssertEqual(try SecureMessage(wire: received), .text(id: 42, value: text))
            let receipt = try server.seal(SecureMessage.textResult(id: 42, success: true).encoded(), lane: .serverControl)
            XCTAssertEqual(try SecureMessage(wire: client.open(transmit(receipt, kind: .encryptedControl, id: 4, mtu: mtu), lane: .serverControl)), .textResult(id: 42, success: true))
        }
    }

    func testRawLegacyInputCannotBecomeSecureRecord() throws {
        var (_, server) = try connect(mtu: 20)
        for legacy in [KeyEvent(command: .up, isDown: true).encoded,
                       PointerEvent.move(dx: 1, dy: 1).encoded,
                       TextChunk(isFinal: true, bytes: Data("secret".utf8)).encoded] {
            var assembler = SecureFrameAssembler()
            XCTAssertThrowsError(try assembler.accept(legacy))
            XCTAssertThrowsError(try server.open(legacy, lane: .clientInput))
        }
    }

    func testInterruptedAndReplayedTextDoesNotDecrypt() throws {
        var (client, server) = try connect(mtu: 20)
        let sealed = try client.seal(SecureMessage.text(id: 1, value: "Do not replay").encoded(), lane: .clientInput)
        let frames = try SecureFrame.fragment(sealed, kind: .encryptedInput, id: 1, mtu: 20)
        var assembler = SecureFrameAssembler()
        for frame in frames.dropLast() { XCTAssertNil(try assembler.accept(frame, now: 0)) }
        XCTAssertThrowsError(try assembler.accept(try XCTUnwrap(frames.last), now: 10))
        _ = try server.open(sealed, lane: .clientInput)
        XCTAssertThrowsError(try server.open(sealed, lane: .clientInput))
        var (_, reconnected) = try connect(mtu: 20)
        XCTAssertThrowsError(try reconnected.open(sealed, lane: .clientInput))
    }
}