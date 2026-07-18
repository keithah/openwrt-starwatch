import Foundation
import WattlineCore

public enum RouterRequestConfirmation: Equatable, Sendable {
    case none
    case telemetry(MutationReconciler, timeout: Duration)
    case powerLimit(PowerLimitType)
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

public struct RouterCommandMapper: Sendable {
    public init() {}

    public func route(for command: DeviceCommand) throws -> RouterRequest {
        let bytes = [UInt8](command.request.bytes)
        switch bytes {
        case [0x01, 0x01, 0x00]:
            return try control(
                path: "/api/v1/device/dc",
                on: false,
                confirmation: .telemetry(.dcEnabled(false), timeout: .seconds(3))
            )
        case [0x01, 0x01, 0x01]:
            return try control(
                path: "/api/v1/device/dc",
                on: true,
                confirmation: .telemetry(.dcEnabled(true), timeout: .seconds(3))
            )
        case [0x13, 0x01, 0x02, 0x00]:
            return try control(
                path: "/api/v1/device/usbc/output",
                on: false,
                confirmation: .telemetry(.typeCOutput(false), timeout: .seconds(3))
            )
        case [0x13, 0x01, 0x02, 0x01]:
            return try control(
                path: "/api/v1/device/usbc/output",
                on: true,
                confirmation: .telemetry(.typeCOutput(true), timeout: .seconds(3))
            )
        case [0x14, 0x01, 0x00]:
            return try control(
                path: "/api/v1/device/dc/bypass",
                on: false,
                confirmation: .telemetry(.bypass(false), timeout: .seconds(10)),
                ignoresResponseResult: true
            )
        case [0x14, 0x01, 0x01]:
            return try control(
                path: "/api/v1/device/dc/bypass",
                on: true,
                confirmation: .telemetry(.bypass(true), timeout: .seconds(10)),
                ignoresResponseResult: true
            )
        case [0x11, 0x01]:
            return RouterRequest(
                method: "POST",
                path: "/api/v1/device/restart",
                confirmation: .disconnect(.successThenReconnect)
            )
        case [0x46, 0x4D]:
            return RouterRequest(
                method: "POST",
                path: "/api/v1/device/shutdown",
                body: try JSONSerialization.data(withJSONObject: ["confirm": true]),
                confirmation: .disconnect(.successThenDisarmReconnect)
            )
        default:
            break
        }

        if bytes.count == 3, bytes[0] == 0x02, bytes[1] == 0x00,
           let type = PowerLimitType(rawValue: bytes[2]) {
            return RouterRequest(
                method: "GET",
                path: "/api/v1/device/usbc/limit/\(Self.name(for: type))",
                confirmation: .powerLimit(type)
            )
        }
        if bytes.count == 4, bytes[0] == 0x02, bytes[1] == 0x01,
           let type = PowerLimitType(rawValue: bytes[2]),
           let level = PowerLimitLevel(rawValue: bytes[3]), type != .runtime {
            return RouterRequest(
                method: "PUT",
                path: "/api/v1/device/usbc/limit/\(Self.name(for: type))",
                body: try JSONSerialization.data(withJSONObject: ["watts": Self.watts(for: level)]),
                confirmation: .powerLimit(type)
            )
        }
        if bytes.count == 3, bytes[0] == 0x02, bytes[1] == 0x02,
           let type = PowerLimitType(rawValue: bytes[2]), type != .runtime {
            return RouterRequest(
                method: "DELETE",
                path: "/api/v1/device/usbc/limit/\(Self.name(for: type))",
                confirmation: .powerLimit(type)
            )
        }

        throw NetworkError.unsupported("Router does not support command bytes \(bytes)")
    }

    private func control(
        path: String,
        on: Bool,
        confirmation: RouterRequestConfirmation,
        ignoresResponseResult: Bool = false
    ) throws -> RouterRequest {
        RouterRequest(
            method: "POST",
            path: path,
            body: try JSONSerialization.data(withJSONObject: ["on": on]),
            confirmation: confirmation,
            ignoresResponseResult: ignoresResponseResult
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
