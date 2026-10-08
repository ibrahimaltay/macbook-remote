import Foundation

/// Trackpad feel, read from the bundled `TrackpadTuning.json` so it can be tuned
/// without touching code.
public struct TrackpadTuning: Decodable, Sendable, Equatable {
    public struct Gain: Decodable, Sendable, Equatable {
        public var speed: Double
        public var accelerationPer1000: Double
        public var maxSpeed: Double

        /// Near `speed` when the finger is slow so you can aim, up to `maxSpeed` on a flick.
        public func gain(forFingerSpeed fingerSpeed: Double) -> Double {
            min(speed + fingerSpeed / 1000 * accelerationPer1000, maxSpeed)
        }
    }

    public struct Momentum: Decodable, Sendable, Equatable {
        public var enabled: Bool
        public var velocityKeptPerSecond: Double
        public var minStartVelocity: Double
        public var stopVelocity: Double
        public var maxVelocity: Double
    }

    public struct Scroll: Decodable, Sendable, Equatable {
        public var speed: Double
        public var accelerationPer1000: Double
        public var maxSpeed: Double
        public var naturalDirection: Bool
        public var momentum: Momentum

        public var gain: Gain {
            Gain(speed: speed, accelerationPer1000: accelerationPer1000, maxSpeed: maxSpeed)
        }
    }

    public var cursor: Gain
    public var scroll: Scroll

    public static let bundled: TrackpadTuning = {
        guard let url = Bundle.module.url(forResource: "TrackpadTuning", withExtension: "json") else {
            fatalError("TrackpadTuning.json is missing from the RemoteClientCore bundle")
        }
        do {
            return try JSONDecoder().decode(TrackpadTuning.self, from: Data(contentsOf: url))
        } catch {
            fatalError("TrackpadTuning.json is invalid: \(error)")
        }
    }()
}
