import Foundation

public enum MouseButton: UInt8, Sendable {
    case left = 0
    case right = 1
}

/// Mirrors the gesture and momentum phases of a real trackpad, so apps can
/// rubber-band and tell finger scrolling from coasting.
public enum ScrollPhase: UInt8, Sendable, CaseIterable {
    case began = 1
    case changed = 2
    case ended = 3
    case momentumBegan = 4
    case momentum = 5
    case momentumEnded = 6
}

/// Trackpad traffic. Key events keep their own untagged two-byte format, so these
/// carry a leading tag and the two are told apart by payload length.
public enum PointerEvent: Equatable, Sendable {
    case move(dx: Int16, dy: Int16)
    /// A whole click, expanded into press and release on the Mac: a dropped packet
    /// can then never strand a button in the down state.
    case click(button: MouseButton, count: UInt8)
    /// Pixel deltas in content direction: positive `dy` reveals content above.
    case scroll(dx: Int16, dy: Int16, phase: ScrollPhase)
}

extension PointerEvent {
    private enum Tag: UInt8 {
        case move = 1
        case click = 2
        // 3 is skipped: the legacy `TextChunk` used it in this tag space.
        case scroll = 4
    }

    public var encoded: Data {
        switch self {
        case .move(let dx, let dy):
            let x = UInt16(bitPattern: dx)
            let y = UInt16(bitPattern: dy)
            return Data([
                Tag.move.rawValue,
                UInt8(x & 0xFF), UInt8(x >> 8),
                UInt8(y & 0xFF), UInt8(y >> 8),
            ])
        case .click(let button, let count):
            return Data([Tag.click.rawValue, button.rawValue, count])
        case .scroll(let dx, let dy, let phase):
            let x = UInt16(bitPattern: dx)
            let y = UInt16(bitPattern: dy)
            return Data([
                Tag.scroll.rawValue,
                UInt8(x & 0xFF), UInt8(x >> 8),
                UInt8(y & 0xFF), UInt8(y >> 8),
                phase.rawValue,
            ])
        }
    }

    public init?(wire: Data) {
        let bytes = [UInt8](wire) // a Data slice is not zero-indexed, so copy it out
        guard let tag = bytes.first.flatMap(Tag.init(rawValue:)) else { return nil }

        switch tag {
        case .move:
            guard bytes.count == 5 else { return nil }
            let x = UInt16(bytes[1]) | UInt16(bytes[2]) << 8
            let y = UInt16(bytes[3]) | UInt16(bytes[4]) << 8
            self = .move(dx: Int16(bitPattern: x), dy: Int16(bitPattern: y))
        case .click:
            guard bytes.count == 3, let button = MouseButton(rawValue: bytes[1]) else { return nil }
            self = .click(button: button, count: bytes[2])
        case .scroll:
            guard bytes.count == 6, let phase = ScrollPhase(rawValue: bytes[5]) else { return nil }
            let x = UInt16(bytes[1]) | UInt16(bytes[2]) << 8
            let y = UInt16(bytes[3]) | UInt16(bytes[4]) << 8
            self = .scroll(dx: Int16(bitPattern: x), dy: Int16(bitPattern: y), phase: phase)
        }
    }
}
