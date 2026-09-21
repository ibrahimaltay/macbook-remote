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
        case .backspace: 51
        }
    }

    var isArrow: Bool {
        switch self {
        case .up, .down, .left, .right: true
        case .mid, .backspace: false
        }
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

    /// Types text as if it came from the keyboard.
    public func type(_ text: String) {
        // Return has to be a real key press: apps do not reliably act on a newline
        // that arrives inside a Unicode string.
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            if index > 0 {
                tapReturn()
            }
            for chunk in Self.chunks(of: line) {
                post(chunk)
            }
        }
    }

    private func tapReturn() {
        for isDown in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: isDown)?
                .post(tap: .cghidEventTap)
        }
    }

    private func post(_ units: [UInt16]) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return }

        // Carrying the characters themselves rather than key codes keeps this correct
        // whatever layout the Mac is set to — a Turkish layout would otherwise turn
        // the key code for ';' into 'ş'.
        var units = units
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Splits on character boundaries, never through a surrogate pair, because some
    /// apps only read the first handful of units from any one event.
    private static func chunks(of line: String, maxUnits: Int = 20) -> [[UInt16]] {
        var chunks: [[UInt16]] = []
        var current: [UInt16] = []

        for character in line {
            let units = Array(character.utf16)
            if !current.isEmpty, current.count + units.count > maxUnits {
                chunks.append(current)
                current = []
            }
            current += units
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
