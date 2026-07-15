@preconcurrency import CoreBluetooth
import Foundation

public enum BLETransportError: Error, Equatable, Sendable {
    case bluetoothUnavailable(String)
    case peripheralNotFound(UUID)
    case disconnected(String)
    case otaBondRecoveryRequired
    case missingCharacteristic(GATTUUID)
    case operationInProgress
    case notReady
    case invalidResponse
    case handshakeFailed(String)
}

private final class PeripheralDelegateProxy: NSObject, CBPeripheralDelegate, @unchecked Sendable {
    weak var bridge: BluetoothDelegateBridge?
    let scope: BLEConnectionScope

    init(bridge: BluetoothDelegateBridge, scope: BLEConnectionScope) {
        self.bridge = bridge
        self.scope = scope
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        bridge?.didDiscoverServices(peripheral, scope: scope, error: error)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        bridge?.didDiscoverCharacteristics(
            peripheral,
            service: service,
            scope: scope,
            error: error
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        bridge?.didWrite(peripheral, characteristic: characteristic, scope: scope, error: error)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        bridge?.didUpdate(peripheral, characteristic: characteristic, scope: scope, error: error)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        bridge?.didUpdateNotificationState(
            peripheral,
            characteristic: characteristic,
            scope: scope,
            error: error
        )
    }
}

final class BluetoothDelegateBridge: NSObject, @unchecked Sendable {
    typealias EventSink = @Sendable (DeviceEvent) -> Void
    typealias Settle = @Sendable () async throws -> Void

    private struct Session {
        let scope: BLEConnectionScope
        let peripheral: CBPeripheral
        let proxy: PeripheralDelegateProxy
        var characteristics: [CBUUID: CBCharacteristic] = [:]
        var expectedServices: Set<ObjectIdentifier> = []
        var driver: BLEHandshakeDriver
        var setupAction: (action: BLEHandshakeAction, characteristic: CBCharacteristic)?
    }

    private struct PendingConnect {
        let operationID: UUID
        let scope: BLEConnectionScope
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct Teardown {
        let scope: BLEConnectionScope
        let peripheral: CBPeripheral
        let eventAlreadyEmitted: Bool
    }

    private enum PendingIO {
        case command(
            operationID: UUID,
            scope: BLEConnectionScope,
            characteristic: CBCharacteristic,
            machine: BLETransactionStateMachine,
            continuation: CheckedContinuation<Data, Error>
        )
        case write(
            operationID: UUID,
            scope: BLEConnectionScope,
            characteristic: CBCharacteristic,
            expectation: BLEExpectedDisconnectStateMachine?,
            continuation: CheckedContinuation<Void, Error>
        )
        case read(
            operationID: UUID,
            scope: BLEConnectionScope,
            uuid: GATTUUID,
            characteristic: CBCharacteristic,
            continuation: CheckedContinuation<Data, Error>
        )

        var operationID: UUID {
            switch self {
            case let .command(operationID, _, _, _, _),
                 let .write(operationID, _, _, _, _),
                 let .read(operationID, _, _, _, _):
                operationID
            }
        }

        var scope: BLEConnectionScope {
            switch self {
            case let .command(_, scope, _, _, _),
                 let .write(_, scope, _, _, _),
                 let .read(_, scope, _, _, _):
                scope
            }
        }
    }

    private let queue = DispatchQueue(label: "ca.peakdo.wattline.bluetooth")
    private let eventSink: EventSink
    private let settle: Settle
    private let now: @Sendable () -> Date
    private var central: CBCentralManager!
    private var powerWaiters: [CheckedContinuation<Void, Error>] = []
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var discoveredModes: [UUID: DeviceMode] = [:]
    private var discoveredLocalNames: [UUID: String] = [:]
    private var callbackState = BLEBridgeCallbackStateMachine()
    private var lifecycle = BLESessionLifecycleStateMachine()
    private var session: Session?
    private var teardown: Teardown?
    private var pendingConnect: PendingConnect?
    private var pendingIO: PendingIO?
    private var cancelledOperations: Set<UUID> = []
    private var settleTask: Task<Void, Never>?
    private let timestampOrigin = DispatchTime.now().uptimeNanoseconds

    init(
        restorationIdentifier: String,
        settle: @escaping Settle = { try await Task.sleep(for: .seconds(2)) },
        now: @escaping @Sendable () -> Date = Date.init,
        eventSink: @escaping EventSink
    ) {
        self.eventSink = eventSink
        self.settle = settle
        self.now = now
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: queue,
            options: [CBCentralManagerOptionRestoreIdentifierKey: restorationIdentifier]
        )
    }

    func startScan() async throws {
        try await waitUntilPoweredOn()
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                central.scanForPeripherals(
                    withServices: [GATTUUID.linkPowerService.bluetoothUUID],
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
                )
                continuation.resume()
            }
        }
    }

    func stopScan() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                central.stopScan()
                continuation.resume()
            }
        }
    }

    func connect(to identifier: UUID) async throws {
        try await waitUntilPoweredOn()
        let operationID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    guard cancelledOperations.remove(operationID) == nil else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    guard session == nil,
                          teardown == nil,
                          pendingConnect == nil,
                          lifecycle.canBeginConnection
                    else {
                        continuation.resume(throwing: BLETransportError.operationInProgress)
                        return
                    }
                    let target = discoveredPeripherals[identifier]
                        ?? central.retrievePeripherals(withIdentifiers: [identifier]).first
                    guard let target else {
                        continuation.resume(throwing: BLETransportError.peripheralNotFound(identifier))
                        return
                    }
                    guard let scope = beginSession(for: target) else {
                        continuation.resume(throwing: BLETransportError.operationInProgress)
                        return
                    }
                    pendingConnect = PendingConnect(
                        operationID: operationID,
                        scope: scope,
                        continuation: continuation
                    )
                    central.connect(target)
                }
            }
        } onCancel: {
            self.cancel(operationID: operationID)
        }
    }

    func disconnect() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if let session { central.cancelPeripheralConnection(session.peripheral) }
                continuation.resume()
            }
        }
    }

    func commandTransaction(_ bytes: Data) async throws -> Data {
        let operationID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard cancelledOperations.remove(operationID) == nil else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    guard pendingIO == nil else {
                        continuation.resume(throwing: BLETransportError.operationInProgress)
                        return
                    }
                    guard let session else {
                        continuation.resume(throwing: BLETransportError.notReady)
                        return
                    }
                    guard lifecycle.externalIOAdmission(scope: session.scope) == .allowed else {
                        continuation.resume(throwing: BLETransportError.notReady)
                        return
                    }
                    guard let characteristic = session.characteristics[GATTUUID.command.bluetoothUUID] else {
                        continuation.resume(throwing: BLETransportError.missingCharacteristic(.command))
                        return
                    }
                    var machine = BLETransactionStateMachine(command: bytes)
                    do {
                        _ = try machine.start()
                        callbackState.expectWrite(
                            scope: session.scope,
                            characteristic: .command,
                            followedByRead: true
                        )
                        pendingIO = .command(
                            operationID: operationID,
                            scope: session.scope,
                            characteristic: characteristic,
                            machine: machine,
                            continuation: continuation
                        )
                        session.peripheral.writeValue(bytes, for: characteristic, type: .withResponse)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            self.cancel(operationID: operationID)
        }
    }

    func write(
        _ bytes: Data,
        to uuid: GATTUUID,
        disconnectPolicy: ExpectedDisconnectPolicy
    ) async throws {
        let operationID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    guard cancelledOperations.remove(operationID) == nil else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    guard pendingIO == nil else {
                        continuation.resume(throwing: BLETransportError.operationInProgress)
                        return
                    }
                    guard let session else {
                        continuation.resume(throwing: BLETransportError.notReady)
                        return
                    }
                    guard lifecycle.externalIOAdmission(scope: session.scope) == .allowed else {
                        continuation.resume(throwing: BLETransportError.notReady)
                        return
                    }
                    guard let characteristic = session.characteristics[uuid.bluetoothUUID] else {
                        continuation.resume(throwing: BLETransportError.missingCharacteristic(uuid))
                        return
                    }
                    let expectation = disconnectPolicy == .none
                        ? nil
                        : BLEExpectedDisconnectStateMachine(
                            policy: disconnectPolicy,
                            scope: session.scope
                        )
                    callbackState.expectWrite(
                        scope: session.scope,
                        characteristic: uuid,
                        followedByRead: false
                    )
                    pendingIO = .write(
                        operationID: operationID,
                        scope: session.scope,
                        characteristic: characteristic,
                        expectation: expectation,
                        continuation: continuation
                    )
                    // The expected-disconnect state is stored before the write can trigger a disconnect.
                    session.peripheral.writeValue(bytes, for: characteristic, type: .withResponse)
                }
            }
        } onCancel: {
            self.cancel(operationID: operationID)
        }
    }

    func read(_ uuid: GATTUUID) async throws -> Data {
        let operationID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard cancelledOperations.remove(operationID) == nil else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    guard pendingIO == nil else {
                        continuation.resume(throwing: BLETransportError.operationInProgress)
                        return
                    }
                    guard let session else {
                        continuation.resume(throwing: BLETransportError.notReady)
                        return
                    }
                    guard lifecycle.externalIOAdmission(scope: session.scope) == .allowed else {
                        continuation.resume(throwing: BLETransportError.notReady)
                        return
                    }
                    guard let characteristic = session.characteristics[uuid.bluetoothUUID] else {
                        continuation.resume(throwing: BLETransportError.missingCharacteristic(uuid))
                        return
                    }
                    callbackState.expectUpdate(scope: session.scope, characteristic: uuid)
                    pendingIO = .read(
                        operationID: operationID,
                        scope: session.scope,
                        uuid: uuid,
                        characteristic: characteristic,
                        continuation: continuation
                    )
                    session.peripheral.readValue(for: characteristic)
                }
            }
        } onCancel: {
            self.cancel(operationID: operationID)
        }
    }

    private func cancel(operationID: UUID) {
        queue.async { [self] in
            if let pendingConnect, pendingConnect.operationID == operationID {
                self.pendingConnect = nil
                if session?.scope == pendingConnect.scope {
                    beginTeardown(scope: pendingConnect.scope, eventAlreadyEmitted: false)
                }
                pendingConnect.continuation.resume(throwing: CancellationError())
                return
            }
            if let pendingIO, pendingIO.operationID == operationID {
                self.pendingIO = nil
                callbackState.clearIO(scope: pendingIO.scope)
                if case let .write(_, scope, _, currentExpectation?, _) = pendingIO {
                    var expectation = currentExpectation
                    _ = expectation.cancel(scope: scope)
                }
                beginTeardown(scope: pendingIO.scope, eventAlreadyEmitted: false)
                resume(pendingIO, throwing: CancellationError())
                return
            }
            cancelledOperations.insert(operationID)
        }
    }

    private func waitUntilPoweredOn() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                switch centralState(central.state) {
                case .poweredOn:
                    continuation.resume()
                case .unknown:
                    powerWaiters.append(continuation)
                case .resetting, .unsupported, .unauthorized, .poweredOff:
                    continuation.resume(
                        throwing: BLETransportError.bluetoothUnavailable(String(describing: central.state))
                    )
                }
            }
        }
    }

    @discardableResult
    private func beginSession(for peripheral: CBPeripheral) -> BLEConnectionScope? {
        guard lifecycle.canBeginConnection, teardown == nil else { return nil }
        let scope = callbackState.beginConnection(peripheralID: peripheral.identifier)
        guard lifecycle.beginConnection(scope: scope) else { return nil }
        let proxy = PeripheralDelegateProxy(bridge: self, scope: scope)
        peripheral.delegate = proxy
        let advertisedName = HandshakeAdvertisementPolicy.advertisedName(
            freshLocalName: discoveredLocalNames.removeValue(forKey: peripheral.identifier)
        )
        session = Session(
            scope: scope,
            peripheral: peripheral,
            proxy: proxy,
            driver: BLEHandshakeDriver(
                scope: scope,
                advertisedName: advertisedName,
                now: now
            )
        )
        discoveredPeripherals[peripheral.identifier] = peripheral
        return scope
    }

    private func beginSettle(scope: BLEConnectionScope) {
        settleTask?.cancel()
        settleTask = Task { [weak self, settle] in
            do {
                try await settle()
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                queue.async { [self] in
                    guard session?.scope == scope, callbackState.activeScope == scope else { return }
                    settleTask = nil
                    failSetup(scope: scope, error: error)
                }
                return
            }
            guard !Task.isCancelled, let self else { return }
            queue.async { [self] in
                guard session?.scope == scope, callbackState.activeScope == scope else { return }
                settleTask = nil
                guard var session else { return }
                let action = session.driver.settleCompleted(scope: scope)
                self.session = session
                enactHandshakeAction(action, scope: scope)
            }
        }
    }

    private func startHandshake(scope: BLEConnectionScope) {
        guard var session, session.scope == scope else { return }
        let action = session.driver.start()
        self.session = session
        enactHandshakeAction(action, scope: scope)
    }

    private func beginServiceDiscovery(scope: BLEConnectionScope) {
        guard let session, session.scope == scope else { return }
        callbackState.expectServiceDiscovery(scope: scope)
        session.peripheral.discoverServices([
            GATTUUID.linkPowerService.bluetoothUUID,
            GATTUUID.deviceInformationService.bluetoothUUID,
            GATTUUID.currentTimeService.bluetoothUUID,
        ])
    }

    private func requestedCharacteristics(for service: CBUUID) -> [CBUUID] {
        switch service {
        case GATTUUID.linkPowerService.bluetoothUUID:
            [GATTUUID.ota, .command, .extendedBatteryInfo, .dcPortStatus, .typeCPortStatus, .factoryMode]
                .map(\.bluetoothUUID)
        case GATTUUID.deviceInformationService.bluetoothUUID:
            [GATTUUID.modelNumber, .firmwareRevision, .hardwareRevision, .softwareRevision]
                .map(\.bluetoothUUID)
        case GATTUUID.currentTimeService.bluetoothUUID:
            [GATTUUID.currentTime.bluetoothUUID]
        default:
            []
        }
    }

    private func enactHandshakeAction(
        _ action: BLEHandshakeAction?,
        scope: BLEConnectionScope
    ) {
        guard let action, var session, session.scope == scope else { return }
        switch action {
        case .settle:
            beginSettle(scope: scope)
        case .discoverServices:
            beginServiceDiscovery(scope: scope)
        case let .write(bytes, uuid, readAfterWrite):
            guard let characteristic = session.characteristics[uuid.bluetoothUUID] else {
                failSetup(scope: scope, error: BLETransportError.missingCharacteristic(uuid))
                return
            }
            session.setupAction = (action, characteristic)
            self.session = session
            callbackState.expectWrite(
                scope: scope,
                characteristic: uuid,
                followedByRead: readAfterWrite
            )
            session.peripheral.writeValue(bytes, for: characteristic, type: .withResponse)
        case let .read(uuid):
            guard let characteristic = session.characteristics[uuid.bluetoothUUID] else {
                failSetup(scope: scope, error: BLETransportError.missingCharacteristic(uuid))
                return
            }
            session.setupAction = (action, characteristic)
            self.session = session
            callbackState.expectUpdate(scope: scope, characteristic: uuid)
            session.peripheral.readValue(for: characteristic)
        case let .subscribe(uuid):
            guard let characteristic = session.characteristics[uuid.bluetoothUUID] else {
                failSetup(scope: scope, error: BLETransportError.missingCharacteristic(uuid))
                return
            }
            session.setupAction = (action, characteristic)
            self.session = session
            callbackState.expectNotification(scope: scope, characteristic: uuid)
            session.peripheral.setNotifyValue(true, for: characteristic)
        case let .publish(snapshot):
            eventSink(.handshakeCompleted(snapshot))
            let next = session.driver.eventEmitted(scope: scope)
            self.session = session
            enactHandshakeAction(next, scope: scope)
        case .connected:
            finishConnection(scope: scope)
        case let .fail(failure):
            failSetup(scope: scope, error: BLETransportError.handshakeFailed(String(describing: failure)))
        }
    }

    private func finishConnection(scope: BLEConnectionScope) {
        guard let session, session.scope == scope else { return }
        guard lifecycle.didFinishSetup(scope: scope) else { return }
        if let pendingConnect, pendingConnect.scope == scope {
            self.pendingConnect = nil
            pendingConnect.continuation.resume()
        }
        eventSink(.connected(session.peripheral.identifier))
    }

    private func terminateSession(scope: BLEConnectionScope) {
        guard let session, session.scope == scope else { return }
        _ = callbackState.didDisconnect(scope: scope)
        _ = lifecycle.terminate(scope: scope)
        session.peripheral.delegate = nil
        settleTask?.cancel()
        settleTask = nil
        self.session = nil
    }

    private func completeDisconnectedSession(scope: BLEConnectionScope) {
        guard let session, session.scope == scope else { return }
        _ = callbackState.didDisconnect(scope: scope)
        _ = lifecycle.didDisconnect(scope: scope)
        session.peripheral.delegate = nil
        settleTask?.cancel()
        settleTask = nil
        self.session = nil
    }

    private func beginTeardown(
        scope: BLEConnectionScope,
        cancelPeripheral: Bool = true,
        eventAlreadyEmitted: Bool
    ) {
        guard let session, session.scope == scope, lifecycle.beginTeardown(scope: scope) else { return }
        settleTask?.cancel()
        settleTask = nil
        if cancelPeripheral {
            central.cancelPeripheralConnection(session.peripheral)
        }
        teardown = Teardown(
            scope: scope,
            peripheral: session.peripheral,
            eventAlreadyEmitted: eventAlreadyEmitted
        )
        _ = callbackState.didDisconnect(scope: scope)
        session.peripheral.delegate = nil
        self.session = nil
    }

    private func failActive(scope: BLEConnectionScope, error: Error) {
        guard session?.scope == scope else { return }
        if let pendingConnect, pendingConnect.scope == scope {
            self.pendingConnect = nil
            pendingConnect.continuation.resume(throwing: error)
        }
        if let pendingIO, pendingIO.scope == scope {
            self.pendingIO = nil
            if case var .write(_, _, _, expectation?, _) = pendingIO {
                _ = expectation.centralUnavailable(scope: scope)
            }
            resume(pendingIO, throwing: error)
        }
        terminateSession(scope: scope)
    }

    private func failSetup(scope: BLEConnectionScope, error: Error) {
        guard session?.scope == scope else { return }
        var continuation: CheckedContinuation<Void, Error>?
        if let pendingConnect, pendingConnect.scope == scope {
            self.pendingConnect = nil
            continuation = pendingConnect.continuation
        }
        eventSink(.disconnected(TransportFailure(message: String(describing: error))))
        beginTeardown(scope: scope, eventAlreadyEmitted: true)
        continuation?.resume(throwing: error)
    }

    private func resume(_ pendingIO: PendingIO, throwing error: Error) {
        switch pendingIO {
        case let .command(_, _, _, _, continuation): continuation.resume(throwing: error)
        case let .write(_, _, _, _, continuation): continuation.resume(throwing: error)
        case let .read(_, _, _, _, continuation): continuation.resume(throwing: error)
        }
    }

    private func connectionFailure(for peripheral: CBPeripheral, error: Error?) -> Error {
        guard let error else { return BLETransportError.disconnected("Connection failed") }
        let mode: OTAConnectionMode = discoveredModes[peripheral.identifier] == .ota
            ? .bootloader
            : .application
        return OTAConnectionPolicy(mode: mode, errorCode: (error as NSError).code).resolution
            == .showBondRecoveryGuidance
            ? BLETransportError.otaBondRecoveryRequired
            : error
    }

    private func emitTelemetry(uuid: GATTUUID, value: Data) {
        let elapsed = DispatchTime.now().uptimeNanoseconds - timestampOrigin
        let timestamp = Duration.nanoseconds(Int64(clamping: elapsed))
        do {
            switch uuid {
            case .extendedBatteryInfo:
                eventSink(.battery(try BatteryStatus(frame: value), timestamp: timestamp))
            case .dcPortStatus:
                eventSink(.dc(try DCPortStatus(frame: value), timestamp: timestamp))
            case .typeCPortStatus:
                eventSink(.typeC(try TypeCPortStatus(frame: value), timestamp: timestamp))
            default:
                break
            }
        } catch {
            // A malformed notification is ignored; the next valid frame remains usable.
        }
    }

    private func enact(_ reconnectPolicy: ReconnectPolicy, peripheral: CBPeripheral) {
        switch reconnectPolicy {
        case .armed:
            eventSink(.reconnecting(peripheral.identifier))
            if beginSession(for: peripheral) != nil {
                central.connect(peripheral)
            }
        case .awaitingOTAMode:
            central.scanForPeripherals(
                withServices: [GATTUUID.linkPowerService.bluetoothUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
        case .disarmed:
            break
        }
    }

    private func centralState(_ state: CBManagerState) -> BLECentralState {
        switch state {
        case .unknown: .unknown
        case .resetting: .resetting
        case .unsupported: .unsupported
        case .unauthorized: .unauthorized
        case .poweredOff: .poweredOff
        case .poweredOn: .poweredOn
        @unknown default: .unsupported
        }
    }

    private func restoredState(_ state: CBPeripheralState) -> RestoredPeripheralState {
        switch state {
        case .disconnected: .disconnected
        case .connecting: .connecting
        case .connected: .connected
        case .disconnecting: .disconnecting
        @unknown default: .disconnecting
        }
    }
}

extension BluetoothDelegateBridge: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = centralState(central.state)
        let hasActiveWork = !powerWaiters.isEmpty
            || pendingConnect != nil
            || pendingIO != nil
            || session != nil
            || teardown != nil
        switch BLECentralStatePolicy.resolution(for: state, hasActiveWork: hasActiveWork) {
        case .ready:
            let waiters = powerWaiters
            powerWaiters.removeAll()
            waiters.forEach { $0.resume() }
        case .wait:
            break
        case .failActiveWork:
            let error = BLETransportError.bluetoothUnavailable(String(describing: central.state))
            let waiters = powerWaiters
            powerWaiters.removeAll()
            waiters.forEach { $0.resume(throwing: error) }
            if let scope = session?.scope {
                failActive(scope: scope, error: error)
                eventSink(.disconnected(TransportFailure(message: String(describing: error))))
            }
            if let teardown {
                self.teardown = nil
                _ = lifecycle.terminate(scope: teardown.scope)
            }
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard let mode = DiscoveryPolicy.classify(localName: localName, cachedPeripheralName: nil),
              let localName
        else { return }
        discoveredPeripherals[peripheral.identifier] = peripheral
        discoveredModes[peripheral.identifier] = mode
        discoveredLocalNames[peripheral.identifier] = localName
        eventSink(.discovered(DiscoveredDevice(
            id: peripheral.identifier,
            localName: localName,
            rssi: RSSI.intValue,
            mode: mode
        )))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let session,
              session.peripheral === peripheral,
              session.scope == callbackState.activeScope,
              peripheral.state == .connected,
              lifecycle.didConnect(scope: session.scope)
        else { return }
        startHandshake(scope: session.scope)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        if let teardown, teardown.peripheral === peripheral {
            self.teardown = nil
            _ = lifecycle.didDisconnect(scope: teardown.scope)
            if !teardown.eventAlreadyEmitted {
                eventSink(.disconnected(error.map { TransportFailure(message: String(describing: $0)) }))
            }
            return
        }
        guard let session,
              session.peripheral === peripheral,
              session.scope == callbackState.activeScope,
              peripheral.state == .disconnected
        else { return }
        let failure = connectionFailure(for: peripheral, error: error)
        failActive(scope: session.scope, error: failure)
        eventSink(.disconnected(TransportFailure(message: String(describing: failure))))
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        if let teardown,
           teardown.peripheral === peripheral,
           peripheral.state == .disconnected
        {
            self.teardown = nil
            _ = lifecycle.didDisconnect(scope: teardown.scope)
            if !teardown.eventAlreadyEmitted {
                eventSink(.disconnected(error.map { TransportFailure(message: String(describing: $0)) }))
            }
            return
        }
        guard let session,
              session.peripheral === peripheral,
              session.scope == callbackState.activeScope,
              peripheral.state == .disconnected
        else { return }
        let scope = session.scope
        let pendingConnect = self.pendingConnect
        let pendingIO = self.pendingIO
        if pendingConnect?.scope == scope { self.pendingConnect = nil }
        if pendingIO?.scope == scope { self.pendingIO = nil }

        var expectedAction: BLEExpectedDisconnectAction?
        if case var .write(_, _, _, expectation?, _) = pendingIO {
            expectedAction = expectation.didDisconnect(scope: scope)
        }
        completeDisconnectedSession(scope: scope)

        let transportFailure = error.map { TransportFailure(message: String(describing: $0)) }
        eventSink(.disconnected(transportFailure))

        if let pendingConnect, pendingConnect.scope == scope {
            pendingConnect.continuation.resume(
                throwing: BLETransportError.disconnected(error.map(String.init(describing:)) ?? "Disconnected")
            )
        }
        if let pendingIO, pendingIO.scope == scope {
            if case let .succeeded(policy) = expectedAction,
               case let .write(_, _, _, _, continuation) = pendingIO
            {
                continuation.resume()
                enact(policy, peripheral: peripheral)
            } else {
                resume(
                    pendingIO,
                    throwing: BLETransportError.disconnected(
                        error.map(String.init(describing:)) ?? "Disconnected"
                    )
                )
            }
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard session == nil,
              teardown == nil,
              lifecycle.canBeginConnection,
              let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first
        else { return }
        guard let scope = beginSession(for: restored) else { return }
        eventSink(.reconnecting(restored.identifier))
        switch RestorationPolicy.action(for: restoredState(restored.state)) {
        case .connect:
            central.connect(restored)
        case .awaitConnection:
            break
        case .discoverServices:
            if lifecycle.didConnect(scope: scope) {
                startHandshake(scope: scope)
            }
        case .terminate:
            beginTeardown(
                scope: scope,
                cancelPeripheral: false,
                eventAlreadyEmitted: false
            )
        }
    }
}

private extension BluetoothDelegateBridge {
    func didDiscoverServices(
        _ peripheral: CBPeripheral,
        scope: BLEConnectionScope,
        error: Error?
    ) {
        guard let session,
              session.peripheral === peripheral,
              callbackState.didDiscoverServices(scope: scope) == .accepted
        else { return }
        if let error {
            failSetup(scope: scope, error: error)
            return
        }
        let services = peripheral.services ?? []
        guard !services.isEmpty else {
            failSetup(scope: scope, error: BLETransportError.missingCharacteristic(.command))
            return
        }
        var updated = session
        updated.expectedServices = Set(services.map { ObjectIdentifier($0) })
        self.session = updated
        callbackState.expectCharacteristicDiscoveries(scope: scope, count: services.count)
        for service in services {
            peripheral.discoverCharacteristics(requestedCharacteristics(for: service.uuid), for: service)
        }
    }

    func didDiscoverCharacteristics(
        _ peripheral: CBPeripheral,
        service: CBService,
        scope: BLEConnectionScope,
        error: Error?
    ) {
        guard var session,
              session.peripheral === peripheral,
              session.expectedServices.contains(ObjectIdentifier(service)),
              callbackState.didDiscoverCharacteristics(scope: scope) == .accepted
        else { return }
        session.expectedServices.remove(ObjectIdentifier(service))
        self.session = session
        if let error {
            failSetup(scope: scope, error: error)
            return
        }
        for characteristic in service.characteristics ?? [] {
            session.characteristics[characteristic.uuid] = characteristic
        }
        self.session = session
        if callbackState.outstandingCharacteristicDiscoveries == 0 {
            guard session.characteristics[GATTUUID.ota.bluetoothUUID] != nil else {
                failSetup(scope: scope, error: BLETransportError.missingCharacteristic(.ota))
                return
            }
            let available = Set(session.characteristics.keys.compactMap { uuid in
                GATTUUID.allCases.first(where: { $0.bluetoothUUID == uuid })
            })
            var updated = session
            let action = updated.driver.characteristicsDiscovered(
                scope: scope,
                available: available
            )
            self.session = updated
            enactHandshakeAction(action, scope: scope)
        }
    }

    func didWrite(
        _ peripheral: CBPeripheral,
        characteristic: CBCharacteristic,
        scope: BLEConnectionScope,
        error: Error?
    ) {
        if var session,
           session.scope == scope,
           session.peripheral === peripheral,
           let setup = session.setupAction,
           setup.characteristic === characteristic,
           let uuid = GATTUUID.allCases.first(where: { $0.bluetoothUUID == characteristic.uuid }),
           callbackState.didWrite(scope: scope, characteristic: uuid) == .accepted
        {
            if error != nil { callbackState.clearIO(scope: scope) }
            session.setupAction = nil
            let action = session.driver.writeCompleted(
                scope: scope,
                uuid: uuid,
                succeeded: error == nil
            )
            self.session = session
            enactHandshakeAction(action, scope: scope)
            return
        }

        guard let pendingIO, pendingIO.scope == scope else { return }
        let expectedCharacteristic: CBCharacteristic
        let uuid: GATTUUID
        switch pendingIO {
        case let .command(_, _, characteristic, _, _):
            expectedCharacteristic = characteristic
            uuid = .command
        case let .write(_, _, characteristic, _, _):
            expectedCharacteristic = characteristic
            guard let mapped = GATTUUID.allCases.first(where: { $0.bluetoothUUID == characteristic.uuid }) else {
                return
            }
            uuid = mapped
        case .read:
            return
        }
        guard expectedCharacteristic === characteristic,
              session?.peripheral === peripheral,
              callbackState.didWrite(scope: scope, characteristic: uuid) == .accepted
        else { return }
        if let error {
            self.pendingIO = nil
            resume(pendingIO, throwing: error)
            return
        }
        switch pendingIO {
        case let .command(operationID, scope, characteristic, currentMachine, continuation):
            var machine = currentMachine
            do {
                _ = try machine.didWrite()
                self.pendingIO = .command(
                    operationID: operationID,
                    scope: scope,
                    characteristic: characteristic,
                    machine: machine,
                    continuation: continuation
                )
                peripheral.readValue(for: characteristic)
            } catch {
                self.pendingIO = nil
                continuation.resume(throwing: error)
            }
        case let .write(operationID, scope, characteristic, expectation, continuation):
            if var expectation {
                _ = expectation.didWrite(scope: scope)
                self.pendingIO = .write(
                    operationID: operationID,
                    scope: scope,
                    characteristic: characteristic,
                    expectation: expectation,
                    continuation: continuation
                )
            } else {
                self.pendingIO = nil
                continuation.resume()
            }
        case .read:
            break
        }
    }

    func didUpdate(
        _ peripheral: CBPeripheral,
        characteristic: CBCharacteristic,
        scope: BLEConnectionScope,
        error: Error?
    ) {
        guard var session, session.scope == scope, session.peripheral === peripheral else { return }

        if let setup = session.setupAction,
           setup.characteristic === characteristic,
           let uuid = GATTUUID.allCases.first(where: { $0.bluetoothUUID == characteristic.uuid }),
           callbackState.didUpdate(scope: scope, characteristic: uuid) == .accepted
        {
            session.setupAction = nil
            if error == nil,
               let value = characteristic.value,
               [.extendedBatteryInfo, .dcPortStatus, .typeCPortStatus].contains(uuid)
            {
                emitTelemetry(uuid: uuid, value: value)
            }
            let action = session.driver.readCompleted(
                scope: scope,
                uuid: uuid,
                value: error == nil ? characteristic.value : nil
            )
            self.session = session
            enactHandshakeAction(action, scope: scope)
            return
        }

        guard let pendingIO, pendingIO.scope == scope else {
            if let uuid = GATTUUID.allCases.first(where: { $0.bluetoothUUID == characteristic.uuid }),
               session.characteristics[uuid.bluetoothUUID] === characteristic,
               let value = characteristic.value,
               error == nil
            {
                emitTelemetry(uuid: uuid, value: value)
            }
            return
        }

        switch pendingIO {
        case let .command(_, _, expected, currentMachine, continuation):
            guard expected === characteristic,
                  callbackState.didUpdate(scope: scope, characteristic: .command) == .accepted
            else { return }
            self.pendingIO = nil
            if let error {
                continuation.resume(throwing: error)
            } else if let value = characteristic.value {
                var machine = currentMachine
                do {
                    guard case let .complete(response) = try machine.didUpdate(value: value) else {
                        throw BLETransportError.invalidResponse
                    }
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            } else {
                continuation.resume(throwing: BLETransportError.invalidResponse)
            }
        case .write:
            return
        case let .read(_, _, uuid, expected, continuation):
            guard expected === characteristic,
                  callbackState.didUpdate(scope: scope, characteristic: uuid) == .accepted
            else { return }
            self.pendingIO = nil
            if let error {
                continuation.resume(throwing: error)
            } else if let value = characteristic.value {
                emitTelemetry(uuid: uuid, value: value)
                continuation.resume(returning: value)
            } else {
                continuation.resume(throwing: BLETransportError.invalidResponse)
            }
        }
    }

    func didUpdateNotificationState(
        _ peripheral: CBPeripheral,
        characteristic: CBCharacteristic,
        scope: BLEConnectionScope,
        error: Error?
    ) {
        guard var session,
              session.scope == scope,
              session.peripheral === peripheral,
              let setup = session.setupAction,
              setup.characteristic === characteristic,
              case let .subscribe(expectedUUID) = setup.action,
              let uuid = GATTUUID.allCases.first(where: { $0.bluetoothUUID == characteristic.uuid }),
              uuid == expectedUUID,
              callbackState.didUpdateNotification(scope: scope, characteristic: uuid) == .accepted
        else { return }
        session.setupAction = nil
        let action = session.driver.notificationStateUpdated(
            scope: scope,
            uuid: uuid,
            succeeded: error == nil,
            isNotifying: characteristic.isNotifying
        )
        self.session = session
        enactHandshakeAction(action, scope: scope)
    }
}
