@testable import RemoteClientCore
import XCTest

final class TextDeliveryTrackerTests: XCTestCase {
    func testOnlyMatchingReceiptCompletesOnce() throws {
        var tracker = TextDeliveryTracker()
        try tracker.begin(42)
        XCTAssertNil(tracker.receipt(id: 1, success: true))
        XCTAssertEqual(tracker.pendingID, 42)
        XCTAssertEqual(tracker.receipt(id: 42, success: true), true)
        XCTAssertNil(tracker.receipt(id: 42, success: true))
        XCTAssertFalse(tracker.cancel())
    }

    func testCancellationAndStaleReceiptDoNotCompleteNextMessage() throws {
        var tracker = TextDeliveryTracker()
        try tracker.begin(1)
        XCTAssertTrue(tracker.cancel())
        XCTAssertFalse(tracker.cancel())
        try tracker.begin(2)
        XCTAssertNil(tracker.receipt(id: 1, success: true))
        XCTAssertEqual(tracker.pendingID, 2)
        XCTAssertEqual(tracker.receipt(id: 2, success: false), false)
    }

    func testConcurrentSubmissionCannotReplacePendingMessage() throws {
        var tracker = TextDeliveryTracker()
        try tracker.begin(1)
        XCTAssertThrowsError(try tracker.begin(2))
        XCTAssertEqual(tracker.pendingID, 1)
        XCTAssertEqual(tracker.receipt(id: 1, success: true), true)
    }
}