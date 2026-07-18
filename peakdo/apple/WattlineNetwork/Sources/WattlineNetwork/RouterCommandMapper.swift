import Foundation
import WattlineCore

public enum RouterRequestConfirmation: Equatable, Sendable {
    case none
    case telemetry(MutationReconciler, timeout: Duration)
    case powerLimit(PowerLimitType)
    case bypassThreshold(Double)
    case scheduleMutation
    case disconnect(ExpectedDisconnectPolicy)
}

public struct RouterRequest: Equatable, Sendable {
    public let method: String
    public let path: String
    public let body: Data?
    public let confirmation: RouterRequestConfirmation
    public let ignoresResponseResult: Bool

    public init(
        method: String,
        path: String,
        body: Data? = nil,
        confirmation: RouterRequestConfirmation = .none,
        ignoresResponseResult: Bool = false
    ) {
        self.method = method
        self.path = path
        self.body = body
        self.confirmation = confirmation
        self.ignoresResponseResult = ignoresResponseResult
    }
}

public struct RouterSchedule: Codable, Equatable, Sendable {
    public let id: UInt8?
    public let status: Int8
    public let type: UInt8
    public let hour: UInt8
    public let minute: UInt8
    public let repeatMask: UInt32
    public let action: UInt8

    public init(
        id: UInt8?,
        status: Int8,
        type: UInt8,
        hour: UInt8,
        minute: UInt8,
        repeatMask: UInt32,
        action: UInt8
    ) {
        self.id = id
        self.status = status
        self.type = type
        self.hour = hour
        self.minute = minute
        self.repeatMask = repeatMask
        self.action = action
    }

    private enum CodingKeys: String, CodingKey {
        case id, status, type, hour, minute, action
        case repeatMask = "repeat"
    }
}

public struct RouterCommandMapper: Sendable {
    public init() {}

    public func route(for command: DeviceCommand) throws -> RouterRequest {
        let bytes = [UInt8](command.request.bytes)
        switch bytes {
        case [0x01, 0x01, 0x00]:
            return try action("dc_off", confirmation: .telemetry(.dcEnabled(false), timeout: .seconds(3)))
        case [0x01, 0x01, 0x01]:
            return try action("dc_on", confirmation: .telemetry(.dcEnabled(true), timeout: .seconds(3)))
        case [0x13, 0x01, 0x02, 0x00]:
            return try action("usbc_off", confirmation: .telemetry(.typeCOutput(false), timeout: .seconds(3)))
        case [0x13, 0x01, 0x02, 0x01]:
            return try action("usbc_on", confirmation: .telemetry(.typeCOutput(true), timeout: .seconds(3)))
        case [0x14, 0x01, 0x00]:
            return try action(
                "bypass_off",
                confirmation: .telemetry(.bypass(false), timeout: .seconds(10)),
                ignoresResponseResult: true
            )
        case [0x14, 0x01, 0x01]:
            return try action(
                "bypass_on",
                confirmation: .telemetry(.bypass(true), timeout: .seconds(10)),
                ignoresResponseResult: true
            )
        case [0x11, 0x01]:
            return try action("restart", confirmation: .disconnect(.successThenReconnect))
        default:
            break
        }

        if bytes.count == 3, bytes[0] == 0x02, bytes[1] == 0x00,
           let type = PowerLimitType(rawValue: bytes[2]) {
            return RouterRequest(
                method: "GET",
                path: "/api/v1/device/usbc-limit",
                confirmation: .powerLimit(type)
            )
        }
        if bytes.count == 4, bytes[0] == 0x02, bytes[1] == 0x01,
           let type = PowerLimitType(rawValue: bytes[2]),
           let level = PowerLimitLevel(rawValue: bytes[3]), type != .runtime {
            return try powerLimit(type: type, values: ["watts": Self.watts(for: level)])
        }
        if bytes.count == 3, bytes[0] == 0x02, bytes[1] == 0x02,
           let type = PowerLimitType(rawValue: bytes[2]), type != .runtime {
            return try powerLimit(type: type, values: ["clear": true])
        }

        throw NetworkError.unsupported("Router does not support command bytes \(bytes)")
    }

    public func setBypassThreshold(volts: Double) throws -> RouterRequest {
        guard volts > 0, volts <= 60 else {
            throw NetworkError.unsupported("Bypass threshold must be greater than 0 and at most 60 volts")
        }
        return RouterRequest(
            method: "POST",
            path: "/api/v1/device/bypass-threshold",
            body: try JSONSerialization.data(withJSONObject: ["volts": volts]),
            confirmation: .bypassThreshold(volts)
        )
    }

    public func listSchedules() -> RouterRequest {
        RouterRequest(method: "GET", path: "/api/v1/device/schedules")
    }

    public func upsertSchedule(_ schedule: RouterSchedule) throws -> RouterRequest {
        guard schedule.id != 0xFF, schedule.type <= 3, schedule.hour <= 23,
              schedule.minute <= 59, schedule.action <= 1 else {
            throw NetworkError.unsupported("Invalid router schedule")
        }
        return RouterRequest(
            method: "POST",
            path: "/api/v1/device/schedules",
            body: try JSONEncoder().encode(schedule),
            confirmation: .scheduleMutation
        )
    }

    public func deleteSchedule(id: UInt8) throws -> RouterRequest {
        guard id != 0xFF else { throw NetworkError.unsupported("Invalid router schedule ID") }
        return RouterRequest(
            method: "DELETE",
            path: "/api/v1/device/schedules/\(id)",
            confirmation: .scheduleMutation
        )
    }

    private func action(
        _ value: String,
        confirmation: RouterRequestConfirmation,
        ignoresResponseResult: Bool = false
    ) throws -> RouterRequest {
        RouterRequest(
            method: "POST",
            path: "/api/v1/device/action",
            body: try JSONSerialization.data(withJSONObject: ["action": value]),
            confirmation: confirmation,
            ignoresResponseResult: ignoresResponseResult
        )
    }

    private func powerLimit(type: PowerLimitType, values: [String: Any]) throws -> RouterRequest {
        var body = values
        body["type"] = Self.name(for: type)
        return RouterRequest(
            method: "POST",
            path: "/api/v1/device/usbc-limit",
            body: try JSONSerialization.data(withJSONObject: body),
            confirmation: .powerLimit(type)
        )
    }

    private static func name(for type: PowerLimitType) -> String {
        switch type {
        case .global: "global"
        case .input: "input"
        case .output: "output"
        case .runtime: "runtime"
        }
    }

    private static func watts(for level: PowerLimitLevel) -> Int {
        switch level {
        case .watts30: 30
        case .watts45: 45
        case .watts60: 60
        case .watts65: 65
        case .watts100: 100
        case .watts140: 140
        }
    }
}
