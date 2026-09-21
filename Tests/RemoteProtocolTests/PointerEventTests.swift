import Foundation
import XCTest

@testable import RemoteProtocol

final class PointerEventTests: XCTestCase {
    func testRoundTripsMovementIncludingNegatives() {
        for event in [
            PointerEvent.move(dx: 0, dy: 0),
            .move(dx: 7, dy: -3),
            .move(dx: -1, dy: 1),
            .move(dx: .max, dy: .min),
        ] {
            XCTAssertEqual(PointerEvent(wire: event.encoded), event)
        }
    }

    func testRoundTripsClicks() {
        for event in [
            PointerEvent.click(button: .left, count: 1),
            .click(button: .left, count: 2),
            .click(button: .right, count: 1),
        ] {
            XCTAssertEqual(PointerEvent(wire: event.encoded), event)
        }
    }

    func testDecodesFromASliceThatDoesNotStartAtZero() {
        let slice = Data([0xFF, 0xFF, 2, 1, 2]).dropFirst(2)
        XCTAssertEqual(PointerEvent(wire: slice), .click(button: .right, count: 2))
    }

    /// Key events stay two untagged bytes, so the two formats have to stay tellable
    /// apart by length alone — that is what keeps older builds working.
    func testNeverDecodesATwoByteKeyEvent() {
        for command in Command.allCases {
            for isDown in [true, false] {
                XCTAssertNil(PointerEvent(wire: KeyEvent(command: command, isDown: isDown).encoded))
            }
        }
    }

    func testRejectsWrongLengthAndUnknownTag() {
        XCTAssertNil(PointerEvent(wire: Data([1, 0, 0, 0])))
        XCTAssertNil(PointerEvent(wire: Data([2, 0])))
        XCTAssertNil(PointerEvent(wire: Data([2, 9, 1])))
        XCTAssertNil(PointerEvent(wire: Data([7, 0, 0])))
        XCTAssertNil(PointerEvent(wire: Data()))
    }
}
