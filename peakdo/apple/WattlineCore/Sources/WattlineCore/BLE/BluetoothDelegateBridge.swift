@preconcurrency import CoreBluetooth
import Foundation

public enum BLETransportError: Error, Equatable, Sendable {
    case bluetoothUnavailable(String)
    case peripheralNotFound(UUID)
    case disconnected(String)
    case otaBondRecoveryRequired
    case missingCharacteristic(GATTUUID)
    case operationInProgress
    case invalidResponse
}

final class BluetoothDelegateBridge: NSObject, @unchecked Sendable {
    typealias EventSink = @Sendable (DeviceEvent) -> Void

    private enum PendingIO {
        case command(BLETransactionStateMachine, CheckedContinuation<Data, Error>)
        case write(CheckedContinuation<Void, Error>)
        case read(GATTUUID, CheckedContinuation<Data, Error>)
    }

    private let queue = DispatchQueue(label: "ca.peakdo.wattline.bluetooth")
    private let eventSink: EventSink
    private var central: CBCentralManager!
    private var powerWaiters: [CheckedContinuation<Void, Error>] = []
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var discoveredModes: [UUID: DeviceMode] = [:]
    private var peripheral: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var outstandingCharacteristicDiscoveries = 0
    private var setupReadQueue: [GATTUUID] = []
    private var setupReading: GATTUUID?
    private var pendingIO: PendingIO?
    private let timestampOrigin = DispatchTime.now().uptimeNanoseconds

    init(restorationIdentifier: String, eventSink: @escaping EventSink) {
        self.eventSink = eventSink
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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard connectContinuation == nil else {
                    continuation.resume(throwing: BLETransportError.operationInProgress)
                    return
                }

                let target = discoveredPeripherals[identifier]
                    ?? central.retrievePeripherals(withIdentifiers: [identifier]).first
                guard let target else {
                    continuation.resume(throwing: BLETransportError.peripheralNotFound(identifier))
                    return
                }

                peripheral = target
                characteristics.removeAll()
                connectContinuation = continuation
                central.connect(target)
            }
        }
    }

    func disconnect() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if let peripheral {
                    central.cancelPeripheralConnection(peripheral)
                }
                continuation.resume()
            }
        }
    }

    func commandTransaction(_ bytes: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            queue.async { [self] in
                guard pendingIO == nil else {
                    continuation.resume(throwing: BLETransportError.operationInProgress)
                    return
                }
                guard let peripheral,
                      let characteristic = characteristics[GATTUUID.command.bluetoothUUID]
                else {
                    continuation.resume(throwing: BLETransportError.missingCharacteristic(.command))
                    return
                }

                var machine = BLETransactionStateMachine(command: bytes)
                do {
                    _ = try machine.start()
                    pendingIO = .command(machine, continuation)
                    peripheral.writeValue(bytes, for: characteristic, type: .withResponse)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func write(_ bytes: Data, to uuid: GATTUUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard pendingIO == nil else {
                    continuation.resume(throwing: BLETransportError.operationInProgress)
                    return
                }
                guard let peripheral, let characteristic = characteristics[uuid.bluetoothUUID] else {
                    continuation.resume(throwing: BLETransportError.missingCharacteristic(uuid))
                    return
                }
                pendingIO = .write(continuation)
                peripheral.writeValue(bytes, for: characteristic, type: .withResponse)
            }
        }
    }

    func read(_ uuid: GATTUUID) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard pendingIO == nil else {
                    continuation.resume(throwing: BLETransportError.operationInProgress)
                    return
                }
                guard let peripheral, let characteristic = characteristics[uuid.bluetoothUUID] else {
                    continuation.resume(throwing: BLETransportError.missingCharacteristic(uuid))
                    return
                }
                pendingIO = .read(uuid, continuation)
                peripheral.readValue(for: characteristic)
            }
        }
    }

    private func waitUntilPoweredOn() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                switch central.state {
                case .poweredOn:
                    continuation.resume()
                case .unknown, .resetting:
                    powerWaiters.append(continuation)
                default:
                    continuation.resume(
                        throwing: BLETransportError.bluetoothUnavailable(String(describing: central.state))
                    )
                }
            }
        }
    }

    private func requestedCharacteristics(for service: CBUUID) -> [CBUUID] {
        switch service {
        case GATTUUID.linkPowerService.bluetoothUUID:
            return [
                GATTUUID.ota, .command, .extendedBatteryInfo, .dcPortStatus,
                .typeCPortStatus, .factoryMode,
            ].map(\.bluetoothUUID)
        case GATTUUID.deviceInformationService.bluetoothUUID:
            return [
                GATTUUID.modelNumber, .firmwareRevision, .hardwareRevision, .softwareRevision,
            ].map(\.bluetoothUUID)
        case GATTUUID.currentTimeService.bluetoothUUID:
            return [GATTUUID.currentTime.bluetoothUUID]
        default:
            return []
        }
    }

    private func beginInitialTelemetryReads() {
        setupReadQueue = [.extendedBatteryInfo, .dcPortStatus, .typeCPortStatus].filter {
            characteristics[$0.bluetoothUUID] != nil
        }
        readNextSetupCharacteristic()
    }

    private func readNextSetupCharacteristic() {
        guard let peripheral else { return }
        guard !setupReadQueue.isEmpty else {
            for uuid in [GATTUUID.extendedBatteryInfo, .dcPortStatus, .typeCPortStatus] {
                if let characteristic = characteristics[uuid.bluetoothUUID],
                   characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate)
                {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
            finishConnection()
            return
        }

        let uuid = setupReadQueue.removeFirst()
        setupReading = uuid
        guard let characteristic = characteristics[uuid.bluetoothUUID] else {
            readNextSetupCharacteristic()
            return
        }
        peripheral.readValue(for: characteristic)
    }

    private func finishConnection() {
        setupReading = nil
        guard let peripheral else { return }
        if let continuation = connectContinuation {
            connectContinuation = nil
            continuation.resume()
        }
        eventSink(.connected(peripheral.identifier))
    }

    private func failPendingOperations(_ error: Error) {
        if let continuation = connectContinuation {
            connectContinuation = nil
            continuation.resume(throwing: error)
        }
        if let pendingIO {
            self.pendingIO = nil
            switch pendingIO {
            case let .command(_, continuation): continuation.resume(throwing: error)
            case let .write(continuation): continuation.resume(throwing: error)
            case let .read(_, continuation): continuation.resume(throwing: error)
            }
        }
    }

    private func connectionFailure(for peripheral: CBPeripheral, error: Error?) -> Error {
        guard let error else { return BLETransportError.disconnected("Connection failed") }
        let mode: OTAConnectionMode = discoveredModes[peripheral.identifier] == .ota
            ? .bootloader
            : .application
        if OTAConnectionPolicy(mode: mode, errorCode: (error as NSError).code).resolution
            == .showBondRecoveryGuidance
        {
            return BLETransportError.otaBondRecoveryRequired
        }
        return error
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
}

extension BluetoothDelegateBridge: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !powerWaiters.isEmpty else { return }
        switch central.state {
        case .poweredOn:
            let waiters = powerWaiters
            powerWaiters.removeAll()
            waiters.forEach { $0.resume() }
        case .unknown, .resetting:
            break
        default:
            let waiters = powerWaiters
            powerWaiters.removeAll()
            let error = BLETransportError.bluetoothUnavailable(String(describing: central.state))
            waiters.forEach { $0.resume(throwing: error) }
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard let mode = DiscoveryPolicy.classify(
            localName: localName,
            cachedPeripheralName: nil
        ), let localName else { return }

        discoveredPeripherals[peripheral.identifier] = peripheral
        discoveredModes[peripheral.identifier] = mode
        eventSink(.discovered(DiscoveredDevice(
            id: peripheral.identifier,
            localName: localName,
            rssi: RSSI.intValue,
            mode: mode
        )))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([
            GATTUUID.linkPowerService.bluetoothUUID,
            GATTUUID.deviceInformationService.bluetoothUUID,
            GATTUUID.currentTimeService.bluetoothUUID,
        ])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let failure = connectionFailure(for: peripheral, error: error)
        failPendingOperations(failure)
        characteristics.removeAll()
        self.peripheral = nil
        eventSink(.disconnected(TransportFailure(message: String(describing: failure))))
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let message = error.map(String.init(describing:)) ?? "Disconnected"
        let failure = BLETransportError.disconnected(message)
        failPendingOperations(failure)
        setupReadQueue.removeAll()
        setupReading = nil
        characteristics.removeAll()
        self.peripheral = nil
        eventSink(.disconnected(error.map { TransportFailure(message: String(describing: $0)) }))
    }

    func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        guard let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first else {
            return
        }
        peripheral = restored
        discoveredPeripherals[restored.identifier] = restored
        restored.delegate = self
        eventSink(.reconnecting(restored.identifier))
        if restored.state == .connected {
            restored.discoverServices([
                GATTUUID.linkPowerService.bluetoothUUID,
                GATTUUID.deviceInformationService.bluetoothUUID,
                GATTUUID.currentTimeService.bluetoothUUID,
            ])
        }
    }
}

extension BluetoothDelegateBridge: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            failPendingOperations(error)
            return
        }
        let services = peripheral.services ?? []
        outstandingCharacteristicDiscoveries = services.count
        guard outstandingCharacteristicDiscoveries > 0 else {
            failPendingOperations(BLETransportError.missingCharacteristic(.command))
            return
        }
        for service in services {
            peripheral.discoverCharacteristics(requestedCharacteristics(for: service.uuid), for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            failPendingOperations(error)
            return
        }
        for characteristic in service.characteristics ?? [] {
            characteristics[characteristic.uuid] = characteristic
        }
        outstandingCharacteristicDiscoveries -= 1
        if outstandingCharacteristicDiscoveries == 0 {
            guard characteristics[GATTUUID.command.bluetoothUUID] != nil else {
                failPendingOperations(BLETransportError.missingCharacteristic(.command))
                return
            }
            beginInitialTelemetryReads()
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let pendingIO else { return }
        if let error {
            self.pendingIO = nil
            switch pendingIO {
            case let .command(_, continuation): continuation.resume(throwing: error)
            case let .write(continuation): continuation.resume(throwing: error)
            case let .read(_, continuation): continuation.resume(throwing: error)
            }
            return
        }

        switch pendingIO {
        case let .command(currentMachine, continuation):
            guard characteristic.uuid == GATTUUID.command.bluetoothUUID else { return }
            var machine = currentMachine
            do {
                _ = try machine.didWrite()
                self.pendingIO = .command(machine, continuation)
                peripheral.readValue(for: characteristic)
            } catch {
                self.pendingIO = nil
                continuation.resume(throwing: error)
            }
        case let .write(continuation):
            self.pendingIO = nil
            continuation.resume()
        case .read:
            break
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let uuid = GATTUUID.allCases.first { $0.bluetoothUUID == characteristic.uuid }

        if let setupReading, setupReading.bluetoothUUID == characteristic.uuid {
            self.setupReading = nil
            if let value = characteristic.value, error == nil {
                emitTelemetry(uuid: setupReading, value: value)
            }
            readNextSetupCharacteristic()
            return
        }

        guard let pendingIO else {
            if let uuid, let value = characteristic.value, error == nil {
                emitTelemetry(uuid: uuid, value: value)
            }
            return
        }

        switch pendingIO {
        case let .command(currentMachine, continuation):
            guard characteristic.uuid == GATTUUID.command.bluetoothUUID else {
                if let uuid, let value = characteristic.value, error == nil {
                    emitTelemetry(uuid: uuid, value: value)
                }
                return
            }
            self.pendingIO = nil
            var machine = currentMachine
            if let error {
                continuation.resume(throwing: error)
            } else if let value = characteristic.value {
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
            break
        case let .read(expectedUUID, continuation):
            guard characteristic.uuid == expectedUUID.bluetoothUUID else {
                if let uuid, let value = characteristic.value, error == nil {
                    emitTelemetry(uuid: uuid, value: value)
                }
                return
            }
            self.pendingIO = nil
            if let error {
                continuation.resume(throwing: error)
            } else if let value = characteristic.value {
                emitTelemetry(uuid: expectedUUID, value: value)
                continuation.resume(returning: value)
            } else {
                continuation.resume(throwing: BLETransportError.invalidResponse)
            }
        }
    }
}
