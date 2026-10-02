import CoreBluetooth
import Foundation

/// The BLE service the Mac advertises and the iPhone looks for.
///
/// These are computed rather than stored because `CBUUID` is a non-Sendable class,
/// which a `static let` cannot hold under strict concurrency.
public enum RemoteService {
    public static var uuid: CBUUID { CBUUID(string: "CD7662C9-9F43-489F-BDD2-9E82E334D46B") }

    /// Two-byte key events, written without response. The hot path.
    public static var keyEventUUID: CBUUID { CBUUID(string: "78C40C74-DAA7-49B7-88C9-9EE7E85BB5A4") }

    /// Read/notify carries the approval state; write carries the phone's name.
    public static var controlUUID: CBUUID { CBUUID(string: "511438D4-A85C-4C8A-B82F-D22566DE4C54") }

    public static let defaultName = "LazyRemote"
}

/// Whether the Mac has accepted a device.
///
/// Link encryption alone is not enough: BLE bonds cannot be revoked from inside the
/// app, so the Mac keeps its own list and can drop a device without System Settings.
public enum ApprovalState: UInt8, Sendable {
    case pending = 0
    case approved = 1

    public var encoded: Data { Data([rawValue]) }

    public init(wire: Data) {
        self = wire.first.flatMap(ApprovalState.init(rawValue:)) ?? .pending
    }
}
