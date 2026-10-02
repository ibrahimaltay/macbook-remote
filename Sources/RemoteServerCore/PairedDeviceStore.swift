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
