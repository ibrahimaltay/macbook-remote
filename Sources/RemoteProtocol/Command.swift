import Foundation

/// One of the buttons on the remote.
public enum Command: UInt8, CaseIterable, Sendable {
    case up = 0
    case down = 1
    case left = 2
    case right = 3
    case mid = 4
    case backspace = 5
    case enter = 6
}

/// A press or a release of one button.
public struct KeyEvent: Equatable, Sendable {
    public var command: Command
    public var isDown: Bool

    public init(command: Command, isDown: Bool) {
        self.command = command
        self.isDown = isDown
    }
}

extension KeyEvent {
    /// Every message is exactly this many bytes, which is all the framing we need.
    public static let wireSize = 2

    public var encoded: Data {
        Data([command.rawValue, isDown ? 1 : 0])
    }

    public init?(wire: Data) {
        guard wire.count == KeyEvent.wireSize else { return nil }
        let bytes = [UInt8](wire) // a Data slice is not zero-indexed, so copy it out
        guard let command = Command(rawValue: bytes[0]) else { return nil }
        self.init(command: command, isDown: bytes[1] == 1)
    }
}

extension Command {
    public var name: String {
        switch self {
        case .up: "UP"
        case .down: "DOWN"
        case .left: "LEFT"
        case .right: "RIGHT"
        case .mid: "MID"
        case .backspace: "BACKSPACE"
        case .enter: "ENTER"
        }
    }

    public init?(name: String) {
        let match = Command.allCases.first { $0.name == name.uppercased() }
        guard let match else { return nil }
        self = match
    }
}
