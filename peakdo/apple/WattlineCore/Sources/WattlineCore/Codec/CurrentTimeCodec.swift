import Foundation

public enum CurrentTimeCodec {
    public static func defaultCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    public static func encode(
        _ date: Date,
        calendar: Calendar = defaultCalendar(),
        adjustReason: UInt8
    ) -> Data {
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
            UInt8(clamping: components.second ?? 0), bluetoothWeekday, fractions256, adjustReason,
        ])
    }

    public static func decode(
        _ data: Data,
        calendar: Calendar = defaultCalendar()
    ) throws -> Date {
        guard data.count >= 10 else { throw BLETransportError.invalidResponse }
        let bytes = Array(data.prefix(10))
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = Int(bytes[0]) | Int(bytes[1]) << 8
        components.month = Int(bytes[2])
        components.day = Int(bytes[3])
        components.hour = Int(bytes[4])
        components.minute = Int(bytes[5])
        components.second = Int(bytes[6])
        components.nanosecond = Int(bytes[8]) * 1_000_000_000 / 256
        guard let date = calendar.date(from: components) else {
            throw BLETransportError.invalidResponse
        }
        return date
    }
}
