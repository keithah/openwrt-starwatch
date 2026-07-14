import Foundation

public enum PowerLimitType: UInt8, CaseIterable, Equatable, Sendable {
    case global = 1
    case input = 2
    case output = 3
    case runtime = 4
}

public enum PowerLimitLevel: UInt8, CaseIterable, Equatable, Sendable {
    case watts30 = 0
    case watts45 = 1
    case watts60 = 2
    case watts65 = 3
    case watts100 = 4
    case watts140 = 5
}

public enum RunningMode: UInt8, Equatable, Sendable {
    case user = 0
    case factory = 1
}

public enum DeviceWriteTarget: Equatable, Sendable {
    case command
    case ota
    case factoryMode
}

public struct DeviceRequest: Equatable, Sendable {
    public let target: DeviceWriteTarget
    public let bytes: Data
    let command: CommandRequest?

    public init(_ command: CommandRequest) {
        target = .command
        bytes = command.bytes
        self.command = command
    }

    public init(target: DeviceWriteTarget, bytes: Data) {
        self.target = target
        self.bytes = bytes
        command = nil
    }
}

public enum ExpectedDisconnectPolicy: Equatable, Sendable {
    case none
    case successThenReconnect
    case successThenAwaitOTAMode
    case successThenDisarmReconnect
}

public enum DeviceCommandFollowUp: Equatable, Sendable {
    case getPowerLimit(PowerLimitType)

    public var command: DeviceCommand {
        switch self {
        case let .getPowerLimit(type): .getPowerLimit(type)
        }
    }
}

public enum DeviceCommandError: Error, Equatable {
    case replyNotSupported
}

public struct DeviceCommand: Equatable, Sendable {
    public let request: DeviceRequest
    public let resultPolicy: CommandResultPolicy
    public let expectsRead: Bool
    public let reconciler: MutationReconciler
    public let timeout: Duration?
    public let followUp: DeviceCommandFollowUp?
    public let disconnectPolicy: ExpectedDisconnectPolicy

    public init(
        request: DeviceRequest,
        resultPolicy: CommandResultPolicy = .standard,
        expectsRead: Bool = true,
        reconciler: MutationReconciler = .none,
        timeout: Duration? = nil,
        followUp: DeviceCommandFollowUp? = nil,
        disconnectPolicy: ExpectedDisconnectPolicy = .none
    ) {
        self.request = request
        self.resultPolicy = resultPolicy
        self.expectsRead = expectsRead
        self.reconciler = reconciler
        self.timeout = timeout
        self.followUp = followUp
        self.disconnectPolicy = disconnectPolicy
    }

    @discardableResult
    public func validate(_ reply: Data) throws -> CommandReply {
        guard expectsRead, let command = request.command else {
            throw DeviceCommandError.replyNotSupported
        }
        return try CommandReply.decode(reply, for: command, resultPolicy: resultPolicy)
    }
}

public extension DeviceCommand {
    static func setDC(_ on: Bool) -> DeviceCommand {
        DeviceCommand(
            request: DeviceRequest(CommandRequest(command: .dcControl, action: .set, payload: [on ? 1 : 0])),
            reconciler: .dcEnabled(on),
            timeout: .seconds(3)
        )
    }

    static func setTypeCOutput(_ on: Bool) -> DeviceCommand {
        DeviceCommand(
            request: DeviceRequest(
                CommandRequest(command: .typeCControl, action: .set, payload: [0x02, on ? 1 : 0])
            ),
            reconciler: .typeCOutput(on),
            timeout: .seconds(3)
        )
    }

    static func getPowerLimit(_ type: PowerLimitType) -> DeviceCommand {
        DeviceCommand(
            request: DeviceRequest(
                CommandRequest(command: .typeCPowerLimit, action: .get, payload: [type.rawValue])
            ),
            resultPolicy: type == .runtime ? .runtimeUnset : .standard
        )
    }

    static func setPowerLimit(_ type: PowerLimitType, level: PowerLimitLevel) -> DeviceCommand {
        DeviceCommand(
            request: DeviceRequest(
                CommandRequest(
                    command: .typeCPowerLimit,
                    action: .set,
                    payload: [type.rawValue, level.rawValue]
                )
            ),
            followUp: .getPowerLimit(type)
        )
    }

    static func clearPowerLimit(_ type: PowerLimitType) -> DeviceCommand {
        // API §3.4: the PWA's timer opcode is accepted as a no-op; clearing must use power-limit DEL.
        DeviceCommand(
            request: DeviceRequest(
                CommandRequest(command: .typeCPowerLimit, action: .delete, payload: [type.rawValue])
            ),
            followUp: .getPowerLimit(type)
        )
    }

    static func setBypass(_ on: Bool) -> DeviceCommand {
        DeviceCommand(
            request: DeviceRequest(
                CommandRequest(command: .dcBypassControl, action: .set, payload: [on ? 1 : 0])
            ),
            // API §3.4: bypass reports nonstandard results; telemetry is authoritative.
            resultPolicy: .ignoreForBypass,
            reconciler: .bypass(on),
            timeout: .seconds(10)
        )
    }

    static let restart = DeviceCommand(
        request: DeviceRequest(CommandRequest(command: .restart, action: .set)),
        expectsRead: false,
        // Spec §5.7/API §3.4: the immediate disconnect is the success acknowledgement.
        disconnectPolicy: .successThenReconnect
    )

    static let enterOTA = DeviceCommand(
        request: DeviceRequest(target: .ota, bytes: Data([0x50, 0x4B])),
        expectsRead: false,
        disconnectPolicy: .successThenAwaitOTAMode
    )

    static let shutdown = DeviceCommand(
        request: DeviceRequest(target: .factoryMode, bytes: Data([0x46, 0x4D])),
        expectsRead: false,
        disconnectPolicy: .successThenDisarmReconnect
    )

    static func runningMode(_ mode: RunningMode) -> DeviceCommand {
        DeviceCommand(
            request: DeviceRequest(
                CommandRequest(command: .runningModeControl, action: .set, payload: [mode.rawValue])
            )
        )
    }
}
