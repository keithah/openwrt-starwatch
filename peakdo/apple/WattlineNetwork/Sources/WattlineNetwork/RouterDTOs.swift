import Foundation

public struct RouterDeviceDTO: Decodable, Equatable, Sendable {
    public let id: String
    public let model: String
    public let hardwareRevision: String
    public let applicationFirmware: String
    public let otaFirmware: String
    public let cid: UInt16
    public let featuresRaw: UInt32
    public let available: RouterAvailabilityDTO
    public let mode: String
    public let connection: RouterDeviceConnectionDTO
    public let magicDNSName: String

    private enum CodingKeys: String, CodingKey {
        case id
        case model
        case hardwareRevision = "hardware_revision"
        case applicationFirmware = "application_firmware"
        case otaFirmware = "ota_firmware"
        case cid
        case featuresRaw = "features_raw"
        case available
        case mode
        case connection
        case magicDNSName = "magic_dns_name"
    }
}

public struct RouterAvailabilityDTO: Decodable, Equatable, Sendable {
    public let currentTime: Bool
    public let ota: Bool
    public let dc: Bool
    public let usbc: Bool

    private enum CodingKeys: String, CodingKey {
        case currentTime = "current_time"
        case ota, dc, usbc
    }
}

public struct RouterDeviceConnectionDTO: Decodable, Equatable, Sendable {
    public let connected: Bool
    public let phase: String
    public let reconnect: String
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
