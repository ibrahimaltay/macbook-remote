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

    func testRoundTripsScrollInEveryPhase() {
        for phase in ScrollPhase.allCases {
            for (dx, dy) in [(Int16(0), Int16(0)), (-5, 12), (.min, .max)] {
                let event = PointerEvent.scroll(dx: dx, dy: dy, phase: phase)
                XCTAssertEqual(PointerEvent(wire: event.encoded), event)
            }
        }
        XCTAssertEqual(
            PointerEvent.scroll(dx: -2, dy: 300, phase: .changed).encoded,
            Data([4, 0xFE, 0xFF, 0x2C, 0x01, 2])
        )
    }

    func testRoundTripsButtonsAndSwipes() {
        for button in [MouseButton.left, .right] {
            for isDown in [true, false] {
                let event = PointerEvent.button(button, isDown: isDown)
                XCTAssertEqual(PointerEvent(wire: event.encoded), event)
            }
        }
        for direction in SwipeDirection.allCases {
            XCTAssertEqual(PointerEvent(wire: PointerEvent.swipe(direction).encoded), .swipe(direction))
        }
        XCTAssertEqual(PointerEvent.button(.left, isDown: true).encoded, Data([5, 0, 1]))
        XCTAssertEqual(PointerEvent.swipe(.up).encoded, Data([7, 2]))
    }

    func testDecodesFromASliceThatDoesNotStartAtZero() {
        let slice = Data([0xFF, 0xFF, 2, 1, 2]).dropFirst(2)
        XCTAssertEqual(PointerEvent(wire: slice), .click(button: .right, count: 2))
    }

    func testRejectsWrongLengthAndUnknownTag() {
        XCTAssertNil(PointerEvent(wire: Data([1, 0, 0, 0])))
        XCTAssertNil(PointerEvent(wire: Data([2, 0])))
        XCTAssertNil(PointerEvent(wire: Data([2, 9, 1])))
        XCTAssertNil(PointerEvent(wire: Data([9, 0, 0])))
        XCTAssertNil(PointerEvent(wire: Data([3, 0, 0, 0, 0, 1])))
        XCTAssertNil(PointerEvent(wire: Data([4, 0, 0, 0, 0])))
        XCTAssertNil(PointerEvent(wire: Data([4, 0, 0, 0, 0, 1, 0])))
        XCTAssertNil(PointerEvent(wire: Data([4, 0, 0, 0, 0, 0])))
        XCTAssertNil(PointerEvent(wire: Data([4, 0, 0, 0, 0, 7])))
        XCTAssertNil(PointerEvent(wire: Data([5, 0])))
        XCTAssertNil(PointerEvent(wire: Data([5, 0, 2])))
        XCTAssertNil(PointerEvent(wire: Data([5, 2, 1])))
        XCTAssertNil(PointerEvent(wire: Data([6, 0, 1])))
        XCTAssertNil(PointerEvent(wire: Data([7, 4])))
        XCTAssertNil(PointerEvent(wire: Data([7, 0, 0])))
        XCTAssertNil(PointerEvent(wire: Data()))
    }
}
