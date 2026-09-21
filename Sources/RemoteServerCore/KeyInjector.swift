import ApplicationServices
import CoreGraphics
import RemoteProtocol

extension Command {
    var keyCode: CGKeyCode {
        switch self {
        case .up: 126
        case .down: 125
        case .left: 123
        case .right: 124
        case .mid: 49
        }
    }

    var isArrow: Bool {
        self != .mid
    }
}

/// Turns remote messages into real key presses on this Mac.
/// Unchecked because `CGEventSource` is not marked `Sendable`, but is only read from here.
public struct KeyInjector: @unchecked Sendable {
    private let source: CGEventSource?

    public init() {
        source = CGEventSource(stateID: .hidSystemState)
    }

    public static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Opens the system prompt that points at Privacy & Security → Accessibility.
    @discardableResult
    public static func requestTrust() -> Bool {
        // Spelled out because `kAXTrustedCheckOptionPrompt` is a global var, which Swift 6 rejects.
        let key = "AXTrustedCheckOptionPrompt"
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public func post(_ event: KeyEvent) {
        guard let cgEvent = CGEvent(
            keyboardEventSource: source,
            virtualKey: event.command.keyCode,
            keyDown: event.isDown
        ) else { return }

        // Some apps ignore arrow keys that arrive without this flag.
        if event.command.isArrow {
            cgEvent.flags = .maskNumericPad
        }
        cgEvent.post(tap: .cghidEventTap)
    }

    public func tap(_ command: Command) {
        post(KeyEvent(command: command, isDown: true))
        post(KeyEvent(command: command, isDown: false))
    }
}
