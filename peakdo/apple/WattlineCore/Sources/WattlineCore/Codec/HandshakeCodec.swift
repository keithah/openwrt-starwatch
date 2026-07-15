import Foundation

public struct OTAInfo: Equatable, Sendable {
    public let mode: DeviceMode
    public let cid: UInt16?

    public init(frame: Data) throws {
        switch try frame.byte(at: 0) {
        case 1: mode = .application
        case 2: mode = .ota
        default: throw BLETransportError.invalidResponse
        }

        if frame.count >= 15 {
            let value = try frame.uint16LittleEndian(at: 13)
            cid = value == 0 ? nil : value
        } else {
            cid = nil
        }
    }
}

public enum HandshakeCodec {
    public static func features(from reply: Data) throws -> FeatureFlags {
        let request = CommandRequest(command: .features, action: .get)
        return FeatureFlags(rawValue: try CommandReply.decode(reply, for: request).uint32Payload())
    }
}
