import Foundation

public struct DeviceID: Equatable, Sendable {
    public let macAddress: String

    public init(reply: Data) throws {
        let request = CommandRequest(command: .deviceID, action: .get)
        let payload = try CommandReply.decode(reply, for: request).payload
        guard payload.count >= 6 else { throw CodecError.truncated }
        macAddress = payload.prefix(6).reversed().map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
