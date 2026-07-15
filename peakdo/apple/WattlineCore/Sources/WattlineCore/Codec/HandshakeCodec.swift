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

public enum CurrentTimeCodec {
    public static func defaultCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    public static func encode(_ date: Date, calendar: Calendar = defaultCalendar()) -> Data {
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .weekday, .nanosecond],
            from: date
        )
        let year = UInt16(clamping: components.year ?? 0)
        let calendarWeekday = components.weekday ?? 1
        let bluetoothWeekday = UInt8(((calendarWeekday + 5) % 7) + 1)
        let fractions256 = UInt8(clamping: (components.nanosecond ?? 0) * 256 / 1_000_000_000)
        return Data([
            UInt8(truncatingIfNeeded: year), UInt8(truncatingIfNeeded: year >> 8),
            UInt8(clamping: components.month ?? 0), UInt8(clamping: components.day ?? 0),
            UInt8(clamping: components.hour ?? 0), UInt8(clamping: components.minute ?? 0),
            UInt8(clamping: components.second ?? 0), bluetoothWeekday, fractions256, 1,
        ])
    }
}

public enum HandshakeCodec {
    public static func features(from reply: Data) throws -> FeatureFlags {
        let request = CommandRequest(command: .features, action: .get)
        return FeatureFlags(rawValue: try CommandReply.decode(reply, for: request).uint32Payload())
    }
}
