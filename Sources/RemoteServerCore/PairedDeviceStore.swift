import Foundation

/// A device the Mac has seen. Approved ones can inject key presses; the rest are
/// waiting for the user to allow them from the menu bar.
public struct PairedDevice: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var isApproved: Bool
    public var isConnected: Bool

    public init(id: UUID, name: String, isApproved: Bool, isConnected: Bool) {
        self.id = id
        self.name = name
        self.isApproved = isApproved
        self.isConnected = isConnected
    }

    /// Enough of the identifier to tell two same-named iPhones apart.
    public var shortID: String { String(id.uuidString.prefix(4)) }
}

/// Remembers which devices the user allowed, across launches.
struct PairedDeviceStore {
    private static let key = "approvedDevices"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Identifier string → last known device name.
    private func load() -> [String: String] {
        defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    private func save(_ entries: [String: String]) {
        defaults.set(entries, forKey: Self.key)
    }

    func isApproved(_ id: UUID) -> Bool {
        load()[id.uuidString] != nil
    }

    func name(for id: UUID) -> String? {
        load()[id.uuidString]
    }

    func approve(_ id: UUID, name: String) {
        var entries = load()
        entries[id.uuidString] = name
        save(entries)
    }

    /// Only updates devices already approved; an unknown device must be allowed first.
    func rename(_ id: UUID, to name: String) {
        var entries = load()
        guard entries[id.uuidString] != nil else { return }
        entries[id.uuidString] = name
        save(entries)
    }

    func forget(_ id: UUID) {
        var entries = load()
        entries.removeValue(forKey: id.uuidString)
        save(entries)
    }

    var approved: [UUID: String] {
        load().reduce(into: [:]) { result, entry in
            guard let id = UUID(uuidString: entry.key) else { return }
            result[id] = entry.value
        }
    }
}
