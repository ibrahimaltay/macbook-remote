import Foundation
import RemoteProtocol
import RemoteSecurity

enum SecureInputDecoder {
    static func decode(_ record: Data, session: inout SecureSession, approved: Bool) throws -> SecureMessage {
        guard approved else { throw SecureError.wrongPhase }
        var candidate = session
        let message = try SecureMessage(wire: candidate.open(record, lane: .clientInput))
        switch message {
        case .key, .pointer, .text:
            session = candidate
            return message
        default:
            throw SecureError.wrongPhase
        }
    }
}