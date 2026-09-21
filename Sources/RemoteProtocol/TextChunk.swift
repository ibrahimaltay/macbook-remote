import Foundation

/// One slice of a typed message.
///
/// A BLE write is capped by the negotiated MTU, so anything longer than a short
/// phrase arrives in pieces and is put back together on the Mac.
public struct TextChunk: Equatable, Sendable {
    public var isFinal: Bool
    /// Raw UTF-8. Splitting bytes rather than characters means a break can land
    /// anywhere; the Mac only decodes once the last chunk arrives.
    public var bytes: Data

    public init(isFinal: Bool, bytes: Data) {
        self.isFinal = isFinal
        self.bytes = bytes
    }
}

extension TextChunk {
    /// Shares a tag space with `PointerEvent`, which uses 1 and 2.
    private static let tag: UInt8 = 3
    public static let headerSize = 2

    /// How much text the Mac will hold before giving up on a message that never
    /// ends, so a stuck or hostile sender cannot grow its memory without limit.
    public static let maxBytes = 4096

    public var encoded: Data {
        Data([Self.tag, isFinal ? 1 : 0]) + bytes
    }

    public init?(wire: Data) {
        let bytes = [UInt8](wire) // a Data slice is not zero-indexed, so copy it out
        // Strictly longer than a key event, never equal: two bytes always means a key.
        guard bytes.count > Self.headerSize, bytes[0] == Self.tag else { return nil }
        self.init(isFinal: bytes[1] == 1, bytes: Data(bytes.dropFirst(Self.headerSize)))
    }
}
