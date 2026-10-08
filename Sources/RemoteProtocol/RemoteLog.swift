import CoreBluetooth
import Foundation
import os

/// Connection diagnostics under subsystem `com.altay.lazyremote`. Messages are logged
/// publicly, so never pass key material, typed text, or message payloads.
public struct RemoteLog: Sendable {
    public static let subsystem = "com.altay.lazyremote"

    private let logger: Logger
    private let category: String

    public init(category: String) {
        self.category = category
        logger = Logger(subsystem: Self.subsystem, category: category)
    }

    public func info(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        mirror("INFO", message)
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        mirror("ERROR", message)
    }

    /// Short, stable prefix for correlating Core Bluetooth identifiers across both devices' logs.
    public static func id(_ uuid: UUID) -> String {
        String(uuid.uuidString.prefix(8))
    }

    public static func describe(_ state: CBManagerState) -> String {
        switch state {
        case .unknown: "unknown"
        case .resetting: "resetting"
        case .unsupported: "unsupported"
        case .unauthorized: "unauthorized"
        case .poweredOff: "poweredOff"
        case .poweredOn: "poweredOn"
        @unknown default: "state(\(state.rawValue))"
        }
    }

    public static func describe(_ error: Error?) -> String {
        guard let error else { return "none" }
        let ns = error as NSError
        return "\(ns.domain)#\(ns.code) \(String(describing: error))"
    }

    private func mirror(_ level: String, _ message: String) {
        #if DEBUG
        // Unified logging isn't captured by `devicectl --console`; stderr is.
        FileHandle.standardError.write(Data("[LazyRemote/\(category)] \(level) \(message)\n".utf8))
        #endif
    }
}
