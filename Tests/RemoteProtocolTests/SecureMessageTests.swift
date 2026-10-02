import Foundation
import XCTest

@testable import RemoteProtocol

final class SecureMessageTests: XCTestCase {
    private func assertError(
        _ expected: SecureWireError, file: StaticString = #filePath, line: UInt = #line,
        _ action: () throws -> Void
    ) {
        XCTAssertThrowsError(try action(), file: file, line: line) {
            XCTAssertEqual($0 as? SecureWireError, expected, file: file, line: line)
        }
    }

    func testRoundTripsAllTagsAndSlices() throws {
        let messages: [SecureMessage] = [
            .key(KeyEvent(command: .up, isDown: true)),
            .pointer(.move(dx: .min, dy: .max)),
            .text(id: .max, value: "Hello \u{1F600}\n\u{015F}"),
            .name("Phone \u{1F4F1}"), .pending, .approved, .revoked,
            .textResult(id: 0, success: true), .finish,
            .textResult(id: .max, success: false),
        ]
        for (index, message) in messages.enumerated() {
            let wire = try message.encoded()
            if index < 9 { XCTAssertEqual(wire.first, UInt8(index + 1)) }
            XCTAssertEqual(try SecureMessage(wire: wire), message)
            XCTAssertEqual(try SecureMessage(wire: (Data([99, 98]) + wire).dropFirst(2)), message)
        }
        for command in Command.allCases {
            for isDown in [false, true] {
                let message = SecureMessage.key(KeyEvent(command: command, isDown: isDown))
                XCTAssertEqual(try SecureMessage(wire: message.encoded()), message)
            }
        }
        for button in [MouseButton.left, .right] {
            for count: UInt8 in [0, 1, 2, 255] {
                let message = SecureMessage.pointer(.click(button: button, count: count))
                XCTAssertEqual(try SecureMessage(wire: message.encoded()), message)
            }
        }
    }

    func testBinaryIDsAndInnerCodecs() throws {
        XCTAssertEqual(try SecureMessage.text(id: 0x0102030405060708, value: "A").encoded(), Data([3, 1, 2, 3, 4, 5, 6, 7, 8, 65]))
        XCTAssertEqual(try SecureMessage.textResult(id: 0x0102030405060708, success: false).encoded(), Data([8, 1, 2, 3, 4, 5, 6, 7, 8, 0]))
        let event = PointerEvent.move(dx: -2, dy: 300)
        XCTAssertEqual(try SecureMessage.pointer(event).encoded(), Data([2]) + event.encoded)
    }

    func testStrictParsingAndLengths() {
        let invalid: [[UInt8]] = [
            [], [0], [10], [0, 1], [1], [1, 0], [1, 0, 2], [1, 0, 255],
            [1, 6, 1], [1, 0, 1, 0], [2], [2, 1, 0, 0, 0],
            [2, 1, 0, 0, 0, 0, 0], [2, 2, 2, 1], [2, 3, 0, 1],
            [3], [3, 0, 0, 0, 0, 0, 0, 0, 0], [4],
            [8], [8, 0, 0, 0, 0, 0, 0, 0, 0],
            [8, 0, 0, 0, 0, 0, 0, 0, 0, 2],
            [8, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0],
        ]
        for bytes in invalid {
            assertError(.malformed) { _ = try SecureMessage(wire: Data(bytes)) }
        }
        for tag: UInt8 in [5, 6, 7, 9] {
            assertError(.malformed) { _ = try SecureMessage(wire: Data([tag, 0])) }
        }
        for bytes: [UInt8] in [[0xFF], [0xC0, 0xAF], [0xED, 0xA0, 0x80], [0xF0, 0x9F]] {
            assertError(.malformed) { _ = try SecureMessage(wire: Data([4] + bytes)) }
            assertError(.malformed) {
                _ = try SecureMessage(wire: Data([3] + Array(repeating: 0, count: 8) + bytes))
            }
        }
    }

    func testStringByteLimitsAndUnicode() throws {
        for (limit, isText) in [(4096, true), (128, false)] {
            let value = String(repeating: "\u{1F600}", count: limit / 4)
            let message: SecureMessage = isText ? .text(id: 1, value: value) : .name(value)
            XCTAssertEqual(value.utf8.count, limit)
            XCTAssertEqual(try SecureMessage(wire: message.encoded()), message)
            let oversized: SecureMessage = isText ? .text(id: 1, value: value + "a") : .name(value + "a")
            assertError(.oversized) { _ = try oversized.encoded() }
            assertError(.oversized) {
                _ = try SecureMessage(wire: message.encoded() + Data([65]))
            }
            let empty: SecureMessage = isText ? .text(id: 1, value: "") : .name("")
            assertError(.malformed) { _ = try empty.encoded() }
        }
    }
}