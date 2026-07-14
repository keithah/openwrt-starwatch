import Foundation

public enum Command: UInt8, Equatable, Sendable {
    case dcControl = 0x01
    case typeCPowerLimit = 0x02
    case barrierFreeMode = 0x03
    case blePIN = 0x04
    case ip2366RegisterDefaultValue = 0x05
    case scheduledOnOff = 0x06
    case deviceID = 0x10
    case restart = 0x11
    case ip2366RegisterValue = 0x12
    case typeCControl = 0x13
    case dcBypassControl = 0x14
    case dcBypassThreshold = 0x15
    case getUSBFirmwareVersion = 0x17
    case runningModeControl = 0xE0
    case test = 0xF0
    case features = 0xFE
}

public enum Action: UInt8, Equatable, Sendable {
    case get = 0x00
    case set = 0x01
    case delete = 0x02
}

public struct CommandRequest: Equatable, Sendable {
    public let command: Command
    public let action: Action
    public let payload: [UInt8]

    public init(command: Command, action: Action, payload: [UInt8] = []) {
        self.command = command
        self.action = action
        self.payload = payload
    }

    public var bytes: Data {
        Data([command.rawValue, action.rawValue] + payload)
    }
}

public enum CommandResultPolicy: Equatable, Sendable {
    case standard
    case runtimeUnset
    case ignoreForBypass

    fileprivate func accepts(_ result: UInt8) -> Bool {
        switch self {
        case .standard: result == 0x00
        case .runtimeUnset: result == 0x00 || result == 0xFF
        case .ignoreForBypass: true
        }
    }
}

public struct CommandReply: Equatable, Sendable {
    public let result: UInt8
    public let payload: Data

    public static func decode(
        _ data: Data,
        for request: CommandRequest,
        resultPolicy: CommandResultPolicy = .standard
    ) throws -> CommandReply {
        let commandEcho = try data.byte(at: 0)
        guard commandEcho == request.command.rawValue else {
            throw CodecError.commandEchoMismatch(expected: request.command.rawValue, actual: commandEcho)
        }

        let expectedAction = request.action.rawValue | 0x80
        let actionEcho = try data.byte(at: 1)
        guard actionEcho == expectedAction else {
            throw CodecError.actionEchoMismatch(expected: expectedAction, actual: actionEcho)
        }

        let result = try data.byte(at: 2)
        guard resultPolicy.accepts(result) else {
            throw CodecError.rejectedResult(result)
        }

        return CommandReply(result: result, payload: data.dropFirst(3))
    }

    public func uint32Payload() throws -> UInt32 {
        try payload.uint32LittleEndian(at: 0)
    }
}
