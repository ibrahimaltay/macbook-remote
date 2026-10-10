import Foundation
import XCTest

@testable import RemoteProtocol

final class CommandTests: XCTestCase {
    func testRoundTripsEveryCommand() {
        for command in Command.allCases {
            for isDown in [true, false] {
                let event = KeyEvent(command: command, isDown: isDown)
                XCTAssertEqual(KeyEvent(wire: event.encoded), event)
            }
        }
    }

    func testEncodesToTwoBytes() {
        XCTAssertEqual(KeyEvent(command: .mid, isDown: true).encoded, Data([4, 1]))
        XCTAssertEqual(KeyEvent(command: .enter, isDown: true).encoded, Data([6, 1]))
        XCTAssertEqual(KeyEvent(command: .spotlight, isDown: true).encoded, Data([7, 1]))
    }

    func testDecodesFromASliceThatDoesNotStartAtZero() {
        let slice = Data([0xFF, 0xFF, 2, 1]).dropFirst(2)
        XCTAssertEqual(KeyEvent(wire: slice), KeyEvent(command: .left, isDown: true))
    }

    func testRejectsWrongLengthAndUnknownCommand() {
        XCTAssertNil(KeyEvent(wire: Data([0])))
        XCTAssertNil(KeyEvent(wire: Data([0, 1, 2])))
        XCTAssertNil(KeyEvent(wire: Data([99, 1])))
    }

    func testParsesCommandNames() {
        XCTAssertEqual(Command(name: "right"), .right)
        XCTAssertEqual(Command(name: "enter"), .enter)
        XCTAssertEqual(Command(name: "spotlight"), .spotlight)
        XCTAssertNil(Command(name: "VOLUME_UP"))
    }
}
