import Foundation

public enum SecureMessage: Sendable, Equatable {
    case key(KeyEvent)
    case pointer(PointerEvent)
    case text(id: UInt64, value: String)
    case name(String)
    case pending
    case approved
    case revoked
    case textResult(id: UInt64, success: Bool)
    case finish

    public func encoded() throws -> Data {
        switch self {
        case .key(let event):
            return Data([1]) + event.encoded
        case .pointer(let event):
            return Data([2]) + event.encoded
        case .text(let id, let value):
            return Data([3]) + Self.encodeID(id) + (try Self.encodeString(value, limit: 4096))
        case .name(let value):
            return Data([4]) + (try Self.encodeString(value, limit: 128))
        case .pending: return Data([5])
        case .approved: return Data([6])
        case .revoked: return Data([7])
        case .textResult(let id, let success):
            return Data([8]) + Self.encodeID(id) + Data([success ? 1 : 0])
        case .finish: return Data([9])
        }
    }

    public init(wire: Data) throws {
        let bytes = [UInt8](wire)
        guard let tag = bytes.first else { throw SecureWireError.malformed }
        let payload = Data(bytes.dropFirst())
        switch tag {
        case 1:
            guard bytes.count == 3, bytes[2] <= 1, let event = KeyEvent(wire: payload)
            else { throw SecureWireError.malformed }
            self = .key(event)
        case 2:
            guard let event = PointerEvent(wire: payload) else { throw SecureWireError.malformed }
            self = .pointer(event)
        case 3:
            guard bytes.count > 9 else { throw SecureWireError.malformed }
            self = .text(
                id: Self.decodeID(bytes[1..<9]),
                value: try Self.decodeString(Data(bytes[9...]), limit: 4096)
            )
        case 4:
            self = .name(try Self.decodeString(payload, limit: 128))
        case 5, 6, 7, 9:
            guard bytes.count == 1 else { throw SecureWireError.malformed }
            switch tag {
            case 5: self = .pending
            case 6: self = .approved
            case 7: self = .revoked
            default: self = .finish
            }
        case 8:
            guard bytes.count == 10, bytes[9] <= 1 else { throw SecureWireError.malformed }
            self = .textResult(id: Self.decodeID(bytes[1..<9]), success: bytes[9] == 1)
        default:
            throw SecureWireError.malformed
        }
    }

    private static func encodeID(_ id: UInt64) -> Data {
        Data(stride(from: 56, through: 0, by: -8).map { UInt8(truncatingIfNeeded: id >> $0) })
    }

    private static func decodeID(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private static func encodeString(_ value: String, limit: Int) throws -> Data {
        let data = Data(value.utf8)
        guard !data.isEmpty else { throw SecureWireError.malformed }
        guard data.count <= limit else { throw SecureWireError.oversized }
        return data
    }

    private static func decodeString(_ data: Data, limit: Int) throws -> String {
        guard !data.isEmpty else { throw SecureWireError.malformed }
        guard data.count <= limit else { throw SecureWireError.oversized }
        guard let value = String(data: data, encoding: .utf8) else { throw SecureWireError.malformed }
        return value
    }
}