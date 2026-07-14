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

public struct BLEConnectionScope: Equatable, Hashable, Sendable {
    public let peripheralID: UUID
    public let generation: UInt64

    public init(peripheralID: UUID, generation: UInt64) {
        self.peripheralID = peripheralID
        self.generation = generation
    }
}

public enum BLECallbackDisposition: Equatable, Sendable {
    case accepted
    case ignored
}

public enum BLEExternalIOAdmission: Equatable, Sendable {
    case allowed
    case notReady
}

public enum BLEExternalOperation: Equatable, Sendable {
    case command
    case refreshTelemetry
}

public struct BLESessionLifecycleStateMachine: Sendable {
    private enum State: Sendable {
        case idle
        case connecting(BLEConnectionScope)
        case setup(BLEConnectionScope)
        case ready(BLEConnectionScope)
        case tearingDown(BLEConnectionScope)

        var scope: BLEConnectionScope? {
            switch self {
            case .idle: nil
            case let .connecting(scope), let .setup(scope), let .ready(scope),
                 let .tearingDown(scope): scope
            }
        }
    }

    private var state: State = .idle

    public init() {}

    public var canBeginConnection: Bool {
        if case .idle = state { return true }
        return false
    }

    public mutating func beginConnection(scope: BLEConnectionScope) -> Bool {
        guard canBeginConnection else { return false }
        state = .connecting(scope)
        return true
    }

    public mutating func didConnect(scope: BLEConnectionScope) -> Bool {
        guard case .connecting(scope) = state else { return false }
        state = .setup(scope)
        return true
    }

    public mutating func didFinishSetup(scope: BLEConnectionScope) -> Bool {
        guard case .setup(scope) = state else { return false }
        state = .ready(scope)
        return true
    }

    public func externalIOAdmission(scope: BLEConnectionScope) -> BLEExternalIOAdmission {
        guard case .ready(scope) = state else { return .notReady }
        return .allowed
    }

    public func externalIOAdmission(
        for _: BLEExternalOperation,
        scope: BLEConnectionScope
    ) -> BLEExternalIOAdmission {
        externalIOAdmission(scope: scope)
    }

    public mutating func beginTeardown(scope: BLEConnectionScope) -> Bool {
        guard state.scope == scope else { return false }
        if case .tearingDown = state { return false }
        state = .tearingDown(scope)
        return true
    }

    public mutating func didDisconnect(
        scope: BLEConnectionScope
    ) -> BLECallbackDisposition {
        guard state.scope == scope else { return .ignored }
        state = .idle
        return .accepted
    }

    public mutating func terminate(scope: BLEConnectionScope) -> Bool {
        guard state.scope == scope else { return false }
        state = .idle
        return true
    }
}

public struct BLEBridgeCallbackStateMachine: Sendable {
    private enum DiscoveryPhase: Sendable {
        case none
        case services
        case characteristics
    }

    private enum IOPhase: Sendable {
        case write(followedByRead: Bool)
        case update
    }

    private struct PendingIO: Sendable {
        let scope: BLEConnectionScope
        let characteristic: GATTUUID
        let phase: IOPhase
    }

    private var nextGeneration: UInt64 = 0
    private var discoveryPhase: DiscoveryPhase = .none
    private var pendingIO: PendingIO?
    public private(set) var activeScope: BLEConnectionScope?
    public private(set) var outstandingCharacteristicDiscoveries = 0

    public init() {}

    @discardableResult
    public mutating func beginConnection(peripheralID: UUID) -> BLEConnectionScope {
        nextGeneration &+= 1
        let scope = BLEConnectionScope(peripheralID: peripheralID, generation: nextGeneration)
        activeScope = scope
        discoveryPhase = .none
        outstandingCharacteristicDiscoveries = 0
        pendingIO = nil
        return scope
    }

    public mutating func expectServiceDiscovery(scope: BLEConnectionScope) {
        guard scope == activeScope else { return }
        discoveryPhase = .services
        outstandingCharacteristicDiscoveries = 0
    }

    public mutating func didDiscoverServices(scope: BLEConnectionScope) -> BLECallbackDisposition {
        guard scope == activeScope, discoveryPhase == .services else { return .ignored }
        discoveryPhase = .none
        return .accepted
    }

    public mutating func expectCharacteristicDiscoveries(
        scope: BLEConnectionScope,
        count: Int
    ) {
        guard scope == activeScope else { return }
        discoveryPhase = .characteristics
        outstandingCharacteristicDiscoveries = max(0, count)
    }

    public mutating func didDiscoverCharacteristics(
        scope: BLEConnectionScope
    ) -> BLECallbackDisposition {
        guard scope == activeScope,
              discoveryPhase == .characteristics,
              outstandingCharacteristicDiscoveries > 0
        else { return .ignored }
        outstandingCharacteristicDiscoveries -= 1
        if outstandingCharacteristicDiscoveries == 0 { discoveryPhase = .none }
        return .accepted
    }

    public mutating func expectWrite(
        scope: BLEConnectionScope,
        characteristic: GATTUUID,
        followedByRead: Bool
    ) {
        guard scope == activeScope else { return }
        pendingIO = PendingIO(
            scope: scope,
            characteristic: characteristic,
            phase: .write(followedByRead: followedByRead)
        )
    }

    public mutating func expectUpdate(
        scope: BLEConnectionScope,
        characteristic: GATTUUID
    ) {
        guard scope == activeScope else { return }
        pendingIO = PendingIO(scope: scope, characteristic: characteristic, phase: .update)
    }

    public mutating func didWrite(
        scope: BLEConnectionScope,
        characteristic: GATTUUID
    ) -> BLECallbackDisposition {
        guard let pendingIO,
              pendingIO.scope == scope,
              scope == activeScope,
              pendingIO.characteristic == characteristic,
              case let .write(followedByRead) = pendingIO.phase
        else { return .ignored }
        self.pendingIO = followedByRead
            ? PendingIO(scope: scope, characteristic: characteristic, phase: .update)
            : nil
        return .accepted
    }

    public mutating func didUpdate(
        scope: BLEConnectionScope,
        characteristic: GATTUUID
    ) -> BLECallbackDisposition {
        guard let pendingIO,
              pendingIO.scope == scope,
              scope == activeScope,
              pendingIO.characteristic == characteristic,
              case .update = pendingIO.phase
        else { return .ignored }
        self.pendingIO = nil
        return .accepted
    }

    public mutating func clearIO(scope: BLEConnectionScope) {
        guard scope == activeScope, pendingIO?.scope == scope else { return }
        pendingIO = nil
    }

    public mutating func didDisconnect(scope: BLEConnectionScope) -> BLECallbackDisposition {
        guard scope == activeScope else { return .ignored }
        activeScope = nil
        discoveryPhase = .none
        outstandingCharacteristicDiscoveries = 0
        pendingIO = nil
        return .accepted
    }
}

public enum BLEExpectedDisconnectAction: Equatable, Sendable {
    case waitingForDisconnect
    case succeeded(ReconnectPolicy)
    case failed
    case cancelled
    case ignored
}

public struct BLEExpectedDisconnectStateMachine: Sendable {
    private let policy: ExpectedDisconnectPolicy
    private let scope: BLEConnectionScope
    private var isActive = true

    public init(policy: ExpectedDisconnectPolicy, scope: BLEConnectionScope) {
        self.policy = policy
        self.scope = scope
    }

    public mutating func didWrite(scope: BLEConnectionScope) -> BLEExpectedDisconnectAction {
        guard isActive, scope == self.scope else { return .ignored }
        return policy == .none ? .ignored : .waitingForDisconnect
    }

    public mutating func didDisconnect(scope: BLEConnectionScope) -> BLEExpectedDisconnectAction {
        guard isActive, scope == self.scope else { return .ignored }
        isActive = false
        switch policy {
        case .none: return .failed
        case .successThenReconnect: return .succeeded(.armed)
        case .successThenAwaitOTAMode: return .succeeded(.awaitingOTAMode)
        case .successThenDisarmReconnect: return .succeeded(.disarmed)
        }
    }

    public mutating func cancel(scope: BLEConnectionScope) -> BLEExpectedDisconnectAction {
        guard isActive, scope == self.scope else { return .ignored }
        isActive = false
        return .cancelled
    }

    public mutating func centralUnavailable(
        scope: BLEConnectionScope
    ) -> BLEExpectedDisconnectAction {
        guard isActive, scope == self.scope else { return .ignored }
        isActive = false
        return .failed
    }
}

public enum BLECentralState: Equatable, Sendable {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn
}

public enum BLECentralStateResolution: Equatable, Sendable {
    case wait
    case ready
    case failActiveWork
}

public enum BLECentralStatePolicy {
    public static func resolution(
        for state: BLECentralState,
        hasActiveWork: Bool
    ) -> BLECentralStateResolution {
        switch state {
        case .poweredOn: .ready
        case .unknown: .wait
        case .resetting: hasActiveWork ? .failActiveWork : .wait
        case .unsupported, .unauthorized, .poweredOff: .failActiveWork
        }
    }
}

public enum RestoredPeripheralState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case disconnecting
}

public enum RestorationAction: Equatable, Sendable {
    case connect
    case awaitConnection
    case discoverServices
    case terminate
}

public enum RestorationPolicy {
    public static func action(for state: RestoredPeripheralState) -> RestorationAction {
        switch state {
        case .disconnected: .connect
        case .connecting: .awaitConnection
        case .connected: .discoverServices
        case .disconnecting: .terminate
        }
    }
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
