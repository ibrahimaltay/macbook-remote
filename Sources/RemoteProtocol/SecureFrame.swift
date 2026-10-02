import Foundation

public enum SecureWireError: Error, Equatable {
    case malformed
    case oversized
    case expired
}

public enum SecureFrameKind: UInt8, Sendable {
    case clientHello = 1
    case serverHello = 2
    case clientFinish = 3
    case encryptedControl = 4
    case encryptedInput = 5

    fileprivate var maximumSize: Int {
        switch self {
        case .clientHello, .serverHello, .clientFinish: 1024
        case .encryptedControl, .encryptedInput: 8192
        }
    }
}

public struct SecureFrame: Sendable {
    public static func fragment(
        _ data: Data, kind: SecureFrameKind, id: UInt64, mtu: Int
    ) throws -> [Data] {
        guard mtu >= 20, !data.isEmpty else { throw SecureWireError.malformed }
        guard data.count <= kind.maximumSize else { throw SecureWireError.oversized }
        let bytes = [UInt8](data)
        let capacity = min(mtu - 16, bytes.count)
        var frames: [Data] = []
        var offset = 0
        while offset < bytes.count {
            let end = offset + min(capacity, bytes.count - offset)
            var header: [UInt8] = [0xA7, 2, kind.rawValue, end == bytes.count ? 1 : 0]
            for shift in stride(from: 56, through: 0, by: -8) {
                header.append(UInt8(truncatingIfNeeded: id >> shift))
            }
            header.append(UInt8(bytes.count >> 8))
            header.append(UInt8(bytes.count & 0xFF))
            header.append(UInt8(offset >> 8))
            header.append(UInt8(offset & 0xFF))
            var frame = Data(header)
            frame.append(contentsOf: bytes[offset..<end])
            frames.append(frame)
            offset = end
        }
        return frames
    }
}

public struct SecureFrameAssembler: Sendable {
    private struct Record: Sendable {
        let kind: SecureFrameKind
        let id: UInt64
        let total: Int
        let started: TimeInterval
        var updated: TimeInterval
        var data: Data
    }

    private var record: Record?

    public init() {}

    public mutating func reset() {
        record = nil
    }

    public mutating func accept(
        _ frame: Data, now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) throws -> (kind: SecureFrameKind, id: UInt64, data: Data)? {
        do {
            guard now.isFinite else { throw SecureWireError.malformed }
            if let record, now - record.updated >= 10 || now - record.started >= 30 {
                throw SecureWireError.expired
            }
            let bytes = [UInt8](frame)
            guard bytes.count > 16, bytes[0] == 0xA7, bytes[1] == 2,
                  let kind = SecureFrameKind(rawValue: bytes[2]), bytes[3] <= 1
            else { throw SecureWireError.malformed }
            let id = bytes[4..<12].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let total = Int(bytes[12]) << 8 | Int(bytes[13])
            let offset = Int(bytes[14]) << 8 | Int(bytes[15])
            guard total <= kind.maximumSize else { throw SecureWireError.oversized }
            let payload = Data(bytes[16...])
            let end = offset + payload.count
            guard total > 0, end <= total, (bytes[3] == 1) == (end == total)
            else { throw SecureWireError.malformed }
            if var current = record {
                guard current.kind == kind, current.id == id, current.total == total,
                      offset == current.data.count
                else { throw SecureWireError.malformed }
                current.data.append(payload)
                current.updated = now
                record = current
            } else {
                guard offset == 0 else { throw SecureWireError.malformed }
                record = Record(
                    kind: kind, id: id, total: total, started: now, updated: now, data: payload
                )
            }
            if bytes[3] == 1, let complete = record {
                reset()
                return (complete.kind, complete.id, complete.data)
            }
            return nil
        } catch {
            reset()
            throw error
        }
    }
}