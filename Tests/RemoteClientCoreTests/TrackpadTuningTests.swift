import XCTest

@testable import RemoteClientCore

final class TrackpadTuningTests: XCTestCase {
    private let momentum = TrackpadTuning.Momentum(
        enabled: true, velocityKeptPerSecond: 0.135,
        minStartVelocity: 100, stopVelocity: 10, maxVelocity: 5000
    )

    /// Catches a broken edit to the JSON before it reaches the phone.
    func testBundledFileDecodesWithSaneValues() {
        let tuning = TrackpadTuning.bundled
        for gain in [tuning.cursor, tuning.scroll.gain] {
            XCTAssertGreaterThan(gain.speed, 0)
            XCTAssertGreaterThanOrEqual(gain.accelerationPer1000, 0)
            XCTAssertGreaterThanOrEqual(gain.maxSpeed, gain.speed)
        }
        let momentum = tuning.scroll.momentum
        XCTAssertGreaterThan(momentum.velocityKeptPerSecond, 0)
        XCTAssertLessThan(momentum.velocityKeptPerSecond, 1)
        XCTAssertGreaterThan(momentum.stopVelocity, 0)
        XCTAssertGreaterThanOrEqual(momentum.minStartVelocity, momentum.stopVelocity)
        XCTAssertGreaterThanOrEqual(momentum.maxVelocity, momentum.minStartVelocity)
        XCTAssertGreaterThan(tuning.gestures.swipeDistance, 0)
        XCTAssertGreaterThan(tuning.gestures.dragHoldSeconds, 0)
    }

    func testGainRampsWithFingerSpeedUpToTheCap() {
        let gain = TrackpadTuning.Gain(speed: 1, accelerationPer1000: 2, maxSpeed: 4)
        XCTAssertEqual(gain.gain(forFingerSpeed: 0), 1)
        XCTAssertEqual(gain.gain(forFingerSpeed: 500), 2)
        XCTAssertEqual(gain.gain(forFingerSpeed: 10_000), 4)
    }

    func testMomentumDoesNotStartWhenSlowOrDisabled() {
        XCTAssertNil(ScrollMomentum(velocityX: 60, velocityY: 60, tuning: momentum))
        var off = momentum
        off.enabled = false
        XCTAssertNil(ScrollMomentum(velocityX: 0, velocityY: 3000, tuning: off))
    }

    func testMomentumIsCappedAndKeepsDirection() throws {
        let coast = try XCTUnwrap(ScrollMomentum(velocityX: -30_000, velocityY: 40_000, tuning: momentum))
        XCTAssertEqual(coast.velocityX, -3000, accuracy: 0.001)
        XCTAssertEqual(coast.velocityY, 4000, accuracy: 0.001)
    }

    func testMomentumDeceleratesToAStopIndependentOfFrameRate() throws {
        func coast(frame: Double) throws -> (distance: Double, frames: Int) {
            var momentum = try XCTUnwrap(ScrollMomentum(velocityX: 0, velocityY: 2000, tuning: self.momentum))
            var distance = 0.0
            var frames = 0
            var last = Double.infinity
            while !momentum.isFinished {
                let step = momentum.step(dt: frame).dy
                XCTAssertGreaterThan(step, 0)
                XCTAssertLessThan(step, last)
                last = step
                distance += step
                frames += 1
                if frames > 10_000 { XCTFail("never stopped"); break }
            }
            XCTAssertEqual(momentum.step(dt: frame).dy, 0)
            return (distance, frames)
        }
        let at60 = try coast(frame: 1.0 / 60)
        let at120 = try coast(frame: 1.0 / 120)
        XCTAssertEqual(at60.distance, at120.distance, accuracy: 2000 * 0.01)
        XCTAssertGreaterThan(at120.frames, at60.frames)
    }
}
