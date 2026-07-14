import Foundation

public enum PowerFlow: Int8, Equatable, Sendable {
    case discharging = -1
    case idle = 0
    case charging = 1
}

public enum TypeCPortMode: UInt8, Equatable, Sendable {
    case disabled = 0
    case input = 1
    case output = 2
    case inputAndOutput = 3
}

public struct BatteryStatus: Equatable, Sendable {
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

    public init(frame: Data) throws {
        guard frame.count >= 16 else { throw CodecError.truncated }

        enabled = try frame.byte(at: 0) != 0
        status = try frame.powerFlow(at: 1)
        isFull = try frame.byte(at: 2) != 0
        maxCapacity = try frame.sfloat(at: 3)
        capacity = try frame.sfloat(at: 5)
        level = try frame.byte(at: 7)
        voltage = try frame.sfloat(at: 8)
        current = try frame.sfloat(at: 10)
        power = try frame.sfloat(at: 12)
        remainingMinutes = try frame.uint16LittleEndian(at: 14)
    }
}

public struct DCPortStatus: Equatable, Sendable {
    public let enabled: Bool
    public let status: PowerFlow
    public let voltage: Double
    public let current: Double
    public let power: Double
    public let bypassOn: Bool?

    public init(frame: Data) throws {
        guard frame.count >= 8 else { throw CodecError.truncated }

        enabled = try frame.byte(at: 0) != 0
        status = try frame.powerFlow(at: 1)
        voltage = try frame.sfloat(at: 2)
        current = try frame.sfloat(at: 4)
        power = try frame.sfloat(at: 6)
        bypassOn = frame.count >= 9 ? try frame.byte(at: 8) != 0 : nil
    }
}

public struct TypeCPortStatus: Equatable, Sendable {
    public let enabled: Bool
    public let status: PowerFlow
    public let voltage: Double
    public let current: Double
    public let power: Double
    public let temperature: Double
    public let mode: TypeCPortMode?
    public let isDCInput: Bool

    public init(frame: Data) throws {
        guard frame.count >= 10 else { throw CodecError.truncated }

        enabled = try frame.byte(at: 0) != 0
        status = try frame.powerFlow(at: 1)
        voltage = try frame.sfloat(at: 2)
        current = try frame.sfloat(at: 4)
        power = try frame.sfloat(at: 6)
        temperature = try frame.sfloat(at: 8)
        mode = frame.count >= 12 ? TypeCPortMode(rawValue: try frame.byte(at: 11)) : nil
        isDCInput = frame.count >= 13 ? try frame.byte(at: 12) != 0 : false
    }
}

private extension Data {
    func powerFlow(at offset: Int) throws -> PowerFlow {
        PowerFlow(rawValue: Int8(bitPattern: try byte(at: offset))) ?? .idle
    }

    func sfloat(at offset: Int) throws -> Double {
        let value = try SFloat.decode(Data([
            try byte(at: offset),
            try byte(at: offset + 1),
        ]))

        return switch value {
        case let .finite(number): number
        case .nan: .nan
        case .positiveInfinity: .infinity
        case .negativeInfinity: -.infinity
        }
    }
}
