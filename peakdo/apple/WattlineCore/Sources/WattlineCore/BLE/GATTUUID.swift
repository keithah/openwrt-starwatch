import CoreBluetooth

public enum GATTUUID: String, CaseIterable, Sendable {
    case linkPowerService = "5301"
    case deviceInformationService = "180A"
    case currentTimeService = "1805"

    case ota = "4301"
    case command = "4302"
    case extendedBatteryInfo = "4303"
    case dcPortStatus = "4304"
    case typeCPortStatus = "4305"
    case factoryMode = "4310"

    case modelNumber = "2A24"
    case firmwareRevision = "2A26"
    case hardwareRevision = "2A27"
    case softwareRevision = "2A28"
    case currentTime = "2A2B"

    public var bluetoothUUID: CBUUID { CBUUID(string: rawValue) }
}

public enum BLECharacteristic: Equatable, Sendable {
    case command
}

public enum BLETransactionAction: Equatable, Sendable {
    case writeWithResponse(characteristic: BLECharacteristic)
    case read(characteristic: BLECharacteristic)
    case complete(Data)
}

public enum BLETransactionStateError: Error, Equatable, Sendable {
    case invalidTransition
}

public struct BLETransactionStateMachine: Sendable {
    private enum State: Sendable {
        case idle
        case awaitingWrite
        case awaitingRead
        case complete
    }

    public let command: Data
    private var state: State = .idle

    public init(command: Data) {
        self.command = command
    }

    public mutating func start() throws -> BLETransactionAction {
        guard state == .idle else { throw BLETransactionStateError.invalidTransition }
        state = .awaitingWrite
        return .writeWithResponse(characteristic: .command)
    }

    public mutating func didWrite() throws -> BLETransactionAction {
        guard state == .awaitingWrite else { throw BLETransactionStateError.invalidTransition }
        state = .awaitingRead
        return .read(characteristic: .command)
    }

    public mutating func didUpdate(value: Data) throws -> BLETransactionAction {
        guard state == .awaitingRead else { throw BLETransactionStateError.invalidTransition }
        state = .complete
        return .complete(value)
    }
}
