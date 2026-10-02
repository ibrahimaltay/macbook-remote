import RemoteSecurity

struct TextDeliveryTracker {
    private(set) var pendingID: UInt64?

    mutating func begin(_ id: UInt64) throws {
        guard pendingID == nil else { throw SecureError.wrongPhase }
        pendingID = id
    }

    mutating func receipt(id: UInt64, success: Bool) -> Bool? {
        guard pendingID == id else { return nil }
        pendingID = nil
        return success
    }

    mutating func cancel() -> Bool {
        guard pendingID != nil else { return false }
        pendingID = nil
        return true
    }
}