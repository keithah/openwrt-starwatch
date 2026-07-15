import CoreBluetooth
import Foundation
import Observation
import WattlineCore

@MainActor
@Observable
final class AppModel {
    typealias TransportFactory = @MainActor () -> any DeviceTransport

    enum Route: Equatable {
        case onboarding
        case scan
        case connected
    }

    enum ConnectionStatus: Equatable {
        case connected
        case reconnecting
        case disconnected(String?)
    }

    enum BluetoothIssue: Equatable {
        case deniedOrRestricted
        case unavailable(String)
    }

    struct CachedIdentity: Codable, Equatable, Sendable {
        let advertisedName: String
        let deviceInformationName: String?
        let macAddress: String?

        var name: String { deviceInformationName ?? advertisedName }

        init(advertisedName: String, deviceInformationName: String?, macAddress: String?) {
            self.advertisedName = advertisedName
            self.deviceInformationName = deviceInformationName
            self.macAddress = macAddress
        }

        private enum CodingKeys: String, CodingKey {
            case advertisedName
            case deviceInformationName
            case macAddress
            case legacyName = "name"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            advertisedName = try container.decodeIfPresent(String.self, forKey: .advertisedName)
                ?? container.decode(String.self, forKey: .legacyName)
            deviceInformationName = try container.decodeIfPresent(String.self, forKey: .deviceInformationName)
            macAddress = try container.decodeIfPresent(String.self, forKey: .macAddress)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(advertisedName, forKey: .advertisedName)
            try container.encodeIfPresent(deviceInformationName, forKey: .deviceInformationName)
            try container.encodeIfPresent(macAddress, forKey: .macAddress)
        }
    }

    struct KnownDevice: Codable, Equatable, Sendable {
        let identifier: UUID
        let identity: CachedIdentity
    }

    static let onboardingCompleteKey = AppPersistence.onboardingCompleteKey
    static let knownDevicesKey = AppPersistence.knownDevicesKey

    var route: Route
    var isDemo = false
    var discoveredDevices: [DiscoveredDevice] = []
    var bluetoothIssue: BluetoothIssue?
    var otaRecoveryDevice: DiscoveredDevice?
    var connectionStatus: ConnectionStatus = .disconnected(nil)
    var connectedName: String?
    var scanMessage: String?

    private(set) var knownDevices: [UUID: CachedIdentity]
    private let persistence: AppPersistence
    private let transportFactory: TransportFactory
    private var transport: (any DeviceTransport)?
    private var eventTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var supersededOperationTask: Task<Void, Never>?
    private var transportGeneration: UInt = 0
    private var operationGeneration: UInt = 0
    private var selectedPeripheralID: UUID?

    init(
        persistence: AppPersistence = AppPersistence(),
        transportFactory: @escaping TransportFactory = { BLETransport() }
    ) {
        self.persistence = persistence
        self.transportFactory = transportFactory
        let onboardingComplete = persistence.onboardingComplete
        route = onboardingComplete ? .scan : .onboarding
        knownDevices = persistence.loadKnownDevices()

        if onboardingComplete {
            startReturningSession()
        }
    }

    var sortedDevices: [DiscoveredDevice] {
        discoveredDevices.sorted { lhs, rhs in
            let lhsKnown = knownDevices[lhs.id] != nil
            let rhsKnown = knownDevices[rhs.id] != nil
            if lhsKnown != rhsKnown { return lhsKnown }
            if lhs.rssi != rhs.rssi { return lhs.rssi > rhs.rssi }
            return lhs.localName.localizedCaseInsensitiveCompare(rhs.localName) == .orderedAscending
        }
    }

    func enterDemo() {
        let demo = DemoTransport(seed: 0x57415454)
        isDemo = true
        connectedName = DemoTransport.identity.name
        connectionStatus = .connected
        let generation = attach(transport: demo)
        route = .connected

        let operation = beginOperation(for: generation, transport: demo)
        operationTask = Task { [weak self] in
            do {
                let identity = try await demo.connectDemo()
                guard let self, self.isCurrent(operation) else { return }
                connectedName = identity.name
            } catch {
                guard let self, self.isCurrent(operation) else { return }
                connectionStatus = .disconnected(String(describing: error))
            }
        }
    }

    func requestBluetoothAfterPriming() {
        persistence.onboardingComplete = true
        isDemo = false
        bluetoothIssue = nil

        // This factory reaches BLETransport only after explicit permission priming on first use.
        attach(transport: transportFactory())
        route = .scan
        startScanning()
    }

    func startScanning() {
        guard let context = beginOperationForCurrentTransport() else { return }
        bluetoothIssue = nil
        operationTask = Task { [weak self] in
            do {
                try await context.transport.startScan()
            } catch {
                guard let self, self.isCurrent(context) else { return }
                presentBluetoothFailure(error)
            }
        }
    }

    func refreshScan() async {
        guard let context = beginOperationForCurrentTransport() else { return }
        discoveredDevices.removeAll()
        scanMessage = nil
        let task = Task { [weak self] in
            await context.transport.stopScan()
            guard let self, self.isCurrent(context) else { return }
            do {
                try await context.transport.startScan()
            } catch {
                guard self.isCurrent(context) else { return }
                self.presentBluetoothFailure(error)
            }
        }
        operationTask = task
        await task.value
    }

    func choose(_ device: DiscoveredDevice) {
        if device.mode == .ota {
            otaRecoveryDevice = device
            return
        }
        selectedPeripheralID = device.id
        connectedName = knownDevices[device.id]?.name ?? device.localName
        guard let context = beginOperationForCurrentTransport() else { return }
        operationTask = Task { [weak self] in
            do {
                await context.transport.stopScan()
                guard let self, self.isCurrent(context) else { return }
                try await context.transport.connect(to: device.id)
            } catch {
                guard let self, self.isCurrent(context) else { return }
                connectionStatus = .disconnected(String(describing: error))
                route = .connected
            }
        }
    }

    func retryConnection() {
        guard let selectedPeripheralID,
              let context = beginOperationForCurrentTransport()
        else { return }
        connectionStatus = .reconnecting
        operationTask = Task { [weak self] in
            do {
                try await context.transport.connect(to: selectedPeripheralID)
            } catch {
                guard let self, self.isCurrent(context) else { return }
                connectionStatus = .disconnected(String(describing: error))
            }
        }
    }

    func returnToScan() {
        selectedPeripheralID = nil
        route = .scan
        connectionStatus = .disconnected(nil)
        startScanning()
    }

    func waitForSupersededLifecycleOperation() async {
        await supersededOperationTask?.value
    }

    /// Records only fields actually observed by the completed setup/identity flow.
    /// DIS name and MAC stay nil until a later handshake exposes them.
    func recordSuccessfulHandshake(
        deviceID: UUID,
        advertisedName: String,
        deviceInformationName: String? = nil,
        macAddress: String? = nil
    ) {
        knownDevices[deviceID] = CachedIdentity(
            advertisedName: advertisedName,
            deviceInformationName: deviceInformationName,
            macAddress: macAddress
        )
        persistence.saveKnownDevices(knownDevices)
    }

    private func startReturningSession() {
        let restoredTransport = transportFactory()
        let generation = attach(transport: restoredTransport)

        guard let storedID = persistence.lastSuccessfulPeripheralID else {
            startScanning()
            return
        }

        selectedPeripheralID = storedID
        connectedName = knownDevices[storedID]?.name
        connectionStatus = .reconnecting
        route = .connected
        let operation = beginOperation(for: generation, transport: restoredTransport)
        operationTask = Task { [weak self] in
            do {
                try await restoredTransport.connect(to: storedID)
            } catch {
                guard let self, self.isCurrent(operation) else { return }
                selectedPeripheralID = nil
                connectionStatus = .disconnected(String(describing: error))
                scanMessage = "Couldn’t reconnect. Scanning for nearby devices."
                route = .scan
                do {
                    try await restoredTransport.startScan()
                } catch {
                    guard self.isCurrent(operation) else { return }
                    presentBluetoothFailure(error)
                }
            }
        }
    }

    @discardableResult
    private func attach(transport: any DeviceTransport) -> UInt {
        supersedeCurrentOperation()
        eventTask?.cancel()
        transportGeneration &+= 1
        operationGeneration &+= 1
        let generation = transportGeneration
        self.transport = transport
        let events = transport.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled,
                      let self,
                      self.transportGeneration == generation
                else { return }
                self.receive(event, generation: generation)
            }
        }
        return generation
    }

    private func receive(_ event: DeviceEvent, generation: UInt) {
        guard transportGeneration == generation else { return }
        switch event {
        case let .discovered(device):
            if let index = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
                discoveredDevices[index] = device
            } else {
                discoveredDevices.append(device)
            }
        case let .connected(id):
            if !isDemo {
                persistence.lastSuccessfulPeripheralID = id
                selectedPeripheralID = id
                if let advertisedName = discoveredDevices.first(where: { $0.id == id })?.localName
                    ?? knownDevices[id]?.advertisedName {
                    let existing = knownDevices[id]
                    recordSuccessfulHandshake(
                        deviceID: id,
                        advertisedName: advertisedName,
                        deviceInformationName: existing?.deviceInformationName,
                        macAddress: existing?.macAddress
                    )
                    connectedName = knownDevices[id]?.name
                }
            }
            scanMessage = nil
            connectionStatus = .connected
            route = .connected
        case let .reconnecting(id):
            selectedPeripheralID = id
            connectionStatus = .reconnecting
            route = .connected
        case let .disconnected(failure):
            connectionStatus = .disconnected(failure?.message)
            if selectedPeripheralID != nil || isDemo { route = .connected }
        case .battery, .dc, .typeC, .transactionDepth:
            break
        }
    }

    private struct OperationContext {
        let transportGeneration: UInt
        let operationGeneration: UInt
        let transport: any DeviceTransport
    }

    private func beginOperationForCurrentTransport() -> OperationContext? {
        guard let transport else { return nil }
        return beginOperation(for: transportGeneration, transport: transport)
    }

    private func beginOperation(
        for generation: UInt,
        transport: any DeviceTransport
    ) -> OperationContext {
        supersedeCurrentOperation()
        operationGeneration &+= 1
        return OperationContext(
            transportGeneration: generation,
            operationGeneration: operationGeneration,
            transport: transport
        )
    }

    private func isCurrent(_ operation: OperationContext) -> Bool {
        !Task.isCancelled
            && operation.transportGeneration == transportGeneration
            && operation.operationGeneration == operationGeneration
    }

    private func supersedeCurrentOperation() {
        guard let operationTask else { return }
        operationTask.cancel()
        supersededOperationTask = operationTask
        self.operationTask = nil
    }

    private func presentBluetoothFailure(_ error: any Error) {
        switch CBManager.authorization {
        case .denied, .restricted:
            bluetoothIssue = .deniedOrRestricted
        case .allowedAlways, .notDetermined:
            bluetoothIssue = .unavailable(String(describing: error))
        @unknown default:
            bluetoothIssue = .unavailable(String(describing: error))
        }
    }
}
