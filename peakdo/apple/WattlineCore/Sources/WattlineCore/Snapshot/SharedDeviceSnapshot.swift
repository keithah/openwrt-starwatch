import Foundation

public enum SharedConnectionState: String, Codable, Equatable, Sendable {
    case loading, live, disconnected, reconnecting
}

public struct SharedBatterySnapshot: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let status: PowerFlow
    public let isFull: Bool
    public let maxCapacity: Double
    public let capacity: Double
    public let level: UInt8
    public let voltage: Double
    public let current: Double
    public let power: Double
    public let remainingMinutes: UInt16

    public init(enabled: Bool, status: PowerFlow, isFull: Bool, maxCapacity: Double, capacity: Double, level: UInt8, voltage: Double, current: Double, power: Double, remainingMinutes: UInt16) {
        self.enabled = enabled; self.status = status; self.isFull = isFull; self.maxCapacity = maxCapacity; self.capacity = capacity; self.level = level; self.voltage = voltage; self.current = current; self.power = power; self.remainingMinutes = remainingMinutes
    }
    private enum CodingKeys: String, CodingKey { case enabled, status, isFull, maxCapacity, capacity, level, voltage, current, power, remainingMinutes }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled); try c.encode(status, forKey: .status); try c.encode(isFull, forKey: .isFull); try c.encode(level, forKey: .level); try c.encode(remainingMinutes, forKey: .remainingMinutes)
        try c.encode(SnapshotDouble(maxCapacity), forKey: .maxCapacity); try c.encode(SnapshotDouble(capacity), forKey: .capacity); try c.encode(SnapshotDouble(voltage), forKey: .voltage); try c.encode(SnapshotDouble(current), forKey: .current); try c.encode(SnapshotDouble(power), forKey: .power)
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled); status = try c.decode(PowerFlow.self, forKey: .status); isFull = try c.decode(Bool.self, forKey: .isFull); level = try c.decode(UInt8.self, forKey: .level); remainingMinutes = try c.decode(UInt16.self, forKey: .remainingMinutes)
        maxCapacity = try c.decode(SnapshotDouble.self, forKey: .maxCapacity).value; capacity = try c.decode(SnapshotDouble.self, forKey: .capacity).value; voltage = try c.decode(SnapshotDouble.self, forKey: .voltage).value; current = try c.decode(SnapshotDouble.self, forKey: .current).value; power = try c.decode(SnapshotDouble.self, forKey: .power).value
    }
}

public struct SharedPortSnapshot: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let status: PowerFlow
    public let voltage: Double
    public let current: Double
    public let power: Double
    public let bypassOn: Bool?
    public let mode: TypeCPortMode?
    public let isDCInput: Bool?
    public init(enabled: Bool, status: PowerFlow, voltage: Double, current: Double, power: Double, bypassOn: Bool? = nil, mode: TypeCPortMode? = nil, isDCInput: Bool? = nil) {
        self.enabled = enabled; self.status = status; self.voltage = voltage; self.current = current; self.power = power; self.bypassOn = bypassOn; self.mode = mode; self.isDCInput = isDCInput
    }
    private enum CodingKeys: String, CodingKey { case enabled, status, voltage, current, power, bypassOn, mode, isDCInput }
    public func encode(to encoder: Encoder) throws { var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(enabled, forKey: .enabled); try c.encode(status, forKey: .status); try c.encode(SnapshotDouble(voltage), forKey: .voltage); try c.encode(SnapshotDouble(current), forKey: .current); try c.encode(SnapshotDouble(power), forKey: .power); try c.encodeIfPresent(bypassOn, forKey: .bypassOn); try c.encodeIfPresent(mode, forKey: .mode); try c.encodeIfPresent(isDCInput, forKey: .isDCInput) }
    public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); enabled = try c.decode(Bool.self, forKey: .enabled); status = try c.decode(PowerFlow.self, forKey: .status); voltage = try c.decode(SnapshotDouble.self, forKey: .voltage).value; current = try c.decode(SnapshotDouble.self, forKey: .current).value; power = try c.decode(SnapshotDouble.self, forKey: .power).value; bypassOn = try c.decodeIfPresent(Bool.self, forKey: .bypassOn); mode = try c.decodeIfPresent(TypeCPortMode.self, forKey: .mode); isDCInput = try c.decodeIfPresent(Bool.self, forKey: .isDCInput) }
}

public struct SharedDeviceSnapshot: Codable, Equatable, Sendable {
    public let peripheralID: UUID
    public let featuresRawValue: UInt32
    public let battery: SharedBatterySnapshot?
    public let dc: SharedPortSnapshot?
    public let typeC: SharedPortSnapshot?
    public let connection: SharedConnectionState
    public let observedAt: Date
    public init(peripheralID: UUID, featuresRawValue: UInt32, battery: SharedBatterySnapshot?, dc: SharedPortSnapshot?, typeC: SharedPortSnapshot?, connection: SharedConnectionState, observedAt: Date) { self.peripheralID = peripheralID; self.featuresRawValue = featuresRawValue; self.battery = battery; self.dc = dc; self.typeC = typeC; self.connection = connection; self.observedAt = observedAt }
}

public struct SharedSnapshotEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let snapshot: SharedDeviceSnapshot
    public init(schemaVersion: Int = 1, snapshot: SharedDeviceSnapshot) { self.schemaVersion = schemaVersion; self.snapshot = snapshot }
}

private struct SnapshotDouble: Codable, Equatable, Sendable {
    let value: Double
    init(_ value: Double) { self.value = value }
    init(from decoder: Decoder) throws { let c = try decoder.singleValueContainer(); let raw = try c.decode(String.self); switch raw { case "nan": value = .nan; case "infinity": value = .infinity; case "-infinity": value = -.infinity; default: guard let d = Double(raw) else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "invalid floating point") }; value = d } }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); if value.isNaN { try c.encode("nan") } else if value == .infinity { try c.encode("infinity") } else if value == -.infinity { try c.encode("-infinity") } else { try c.encode(String(value)) } }
}
