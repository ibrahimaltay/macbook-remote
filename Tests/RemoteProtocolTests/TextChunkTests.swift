import Foundation
import XCTest

@testable import RemoteProtocol

final class TextChunkTests: XCTestCase {
    func testRoundTrips() {
        for chunk in [
            TextChunk(isFinal: true, bytes: Data("hello".utf8)),
            TextChunk(isFinal: false, bytes: Data("merhaba dünya".utf8)),
            TextChunk(isFinal: true, bytes: Data("🎧".utf8)),
        ] {
            XCTAssertEqual(TextChunk(wire: chunk.encoded), chunk)
        }
    }

    func testDecodesFromASliceThatDoesNotStartAtZero() {
        let slice = Data([0xFF, 0xFF, 3, 1, 0x68, 0x69]).dropFirst(2)
        XCTAssertEqual(TextChunk(wire: slice), TextChunk(isFinal: true, bytes: Data("hi".utf8)))
    }

    /// A two-byte payload is always a key event, so an empty chunk would decode as one
    /// — tag 3 reads back as the RIGHT command. Chunks must stay longer than that.
    func testRejectsAChunkShortEnoughToLookLikeAKeyEvent() {
        let empty = TextChunk(isFinal: true, bytes: Data())
        XCTAssertEqual(empty.encoded.count, KeyEvent.wireSize)
        XCTAssertNil(TextChunk(wire: empty.encoded))
        XCTAssertNotNil(KeyEvent(wire: empty.encoded))
    }

    func testIsNotConfusedWithPointerTraffic() {
        for event in [PointerEvent.move(dx: 3, dy: -4), .click(button: .right, count: 1)] {
            XCTAssertNil(TextChunk(wire: event.encoded))
        }
        XCTAssertNil(PointerEvent(wire: TextChunk(isFinal: true, bytes: Data("ab".utf8)).encoded))
    }

    func testSplitsAndRejoinsWithoutCaringWhereTheBreakLands() {
        let text = "çğıöşü emoji 🎧 tail"
        let bytes = Data(text.utf8)

        for size in 1...8 {
            var rebuilt = Data()
            var index = bytes.startIndex
            while index < bytes.endIndex {
                let end = bytes.index(index, offsetBy: size, limitedBy: bytes.endIndex) ?? bytes.endIndex
                let chunk = TextChunk(isFinal: end == bytes.endIndex, bytes: Data(bytes[index..<end]))
                rebuilt += TextChunk(wire: chunk.encoded)!.bytes
                index = end
            }
            XCTAssertEqual(String(data: rebuilt, encoding: .utf8), text)
        }
    }
}
