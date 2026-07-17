import Foundation

public struct RouterStatusDTO: Codable, Equatable, Sendable {
    public let connected: Bool
    public let device: RouterIdentityDTO
}

public struct RouterIdentityDTO: Codable, Equatable, Sendable {
    public let model: String
    public let hardwareRevision: String
    public let firmware: String
    public let mac: String
    public let cid: UInt16
    public let features: UInt32

    private enum CodingKeys: String, CodingKey {
        case model
        case hardwareRevision = "hw_rev"
        case firmware
        case mac
        case cid
        case features
    }
}

public struct RouterBatteryDTO: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let status: Int8
    public let full: Bool
    public let maxWh: Double
    public let wh: Double
    public let level: UInt8
    public let volts: Double
    public let amps: Double
    public let watts: Double
    public let remainMin: UInt16

    private enum CodingKeys: String, CodingKey {
        case enabled
        case status
        case full
        case maxWh = "max_wh"
        case wh
        case level
        case volts
        case amps
        case watts
        case remainMin = "remain_min"
    }
}

public struct RouterDCPortDTO: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let status: Int8
    public let volts: Double
    public let amps: Double
    public let watts: Double
    public let bypass: Bool
}

public struct RouterTypeCPortDTO: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let status: Int8
    public let volts: Double
    public let amps: Double
    public let watts: Double
    public let tempC: Double
    public let mode: UInt8
    public let dcInput: Bool

    private enum CodingKeys: String, CodingKey {
        case enabled
        case status
        case volts
        case amps
        case watts
        case tempC = "temp_c"
        case mode
        case dcInput = "dc_input"
    }
}

public struct RouterSnapshotDTO: Codable, Equatable, Sendable {
    public let battery: RouterBatteryDTO?
    public let dc: RouterDCPortDTO?
    public let typeC: RouterTypeCPortDTO?
    public let connected: Bool
    public let updatedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case battery
        case dc
        case typeC = "typec"
        case connected
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        battery = try container.decodeIfPresent(RouterBatteryDTO.self, forKey: .battery)
        dc = try container.decodeIfPresent(RouterDCPortDTO.self, forKey: .dc)
        typeC = try container.decodeIfPresent(RouterTypeCPortDTO.self, forKey: .typeC)
        connected = try container.decode(Bool.self, forKey: .connected)

        guard let value = try container.decodeIfPresent(String.self, forKey: .updatedAt) else {
            updatedAt = nil
            return
        }
        guard let date = RouterISO8601.date(from: value) else {
            throw DecodingError.dataCorruptedError(
                forKey: .updatedAt,
                in: container,
                debugDescription: "Invalid ISO 8601 timestamp: \(value)"
            )
        }
        updatedAt = date
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(battery, forKey: .battery)
        try container.encodeIfPresent(dc, forKey: .dc)
        try container.encodeIfPresent(typeC, forKey: .typeC)
        try container.encode(connected, forKey: .connected)
        if let updatedAt {
            try container.encode(RouterISO8601.string(from: updatedAt), forKey: .updatedAt)
        }
    }
}

private enum RouterISO8601 {
    static func date(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
