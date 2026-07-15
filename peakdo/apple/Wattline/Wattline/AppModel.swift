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
        let modelNumber: String?
        let hardwareRevision: String?
        let otaFirmwareRevision: String?
        let appFirmwareRevision: String?
        let cid: UInt16?
        let rawFeatures: UInt32?
        let isOTAMode: Bool?

        var name: String { deviceInformationName ?? advertisedName }

        init(
            advertisedName: String,
            deviceInformationName: String?,
            macAddress: String?,
            modelNumber: String? = nil,
            hardwareRevision: String? = nil,
            otaFirmwareRevision: String? = nil,
            appFirmwareRevision: String? = nil,
            cid: UInt16? = nil,
            rawFeatures: UInt32? = nil,
            isOTAMode: Bool? = nil
        ) {
            self.advertisedName = advertisedName
            self.deviceInformationName = deviceInformationName
            self.macAddress = macAddress
            self.modelNumber = modelNumber
            self.hardwareRevision = hardwareRevision
            self.otaFirmwareRevision = otaFirmwareRevision
            self.appFirmwareRevision = appFirmwareRevision
            self.cid = cid
            self.rawFeatures = rawFeatures
            self.isOTAMode = isOTAMode
        }

        private enum CodingKeys: String, CodingKey {
            case advertisedName
            case deviceInformationName
            case macAddress
            case modelNumber
            case hardwareRevision
            case otaFirmwareRevision
            case appFirmwareRevision
            case cid
            case rawFeatures
            case isOTAMode
            case legacyName = "name"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            advertisedName = try container.decodeIfPresent(String.self, forKey: .advertisedName)
                ?? container.decode(String.self, forKey: .legacyName)
            deviceInformationName = try container.decodeIfPresent(String.self, forKey: .deviceInformationName)
            macAddress = try container.decodeIfPresent(String.self, forKey: .macAddress)
            modelNumber = try container.decodeIfPresent(String.self, forKey: .modelNumber)
            hardwareRevision = try container.decodeIfPresent(String.self, forKey: .hardwareRevision)
            otaFirmwareRevision = try container.decodeIfPresent(String.self, forKey: .otaFirmwareRevision)
            appFirmwareRevision = try container.decodeIfPresent(String.self, forKey: .appFirmwareRevision)
            cid = try container.decodeIfPresent(UInt16.self, forKey: .cid)
            rawFeatures = try container.decodeIfPresent(UInt32.self, forKey: .rawFeatures)
            isOTAMode = try container.decodeIfPresent(Bool.self, forKey: .isOTAMode)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(advertisedName, forKey: .advertisedName)
            try container.encodeIfPresent(deviceInformationName, forKey: .deviceInformationName)
            try container.encodeIfPresent(macAddress, forKey: .macAddress)
            try container.encodeIfPresent(modelNumber, forKey: .modelNumber)
            try container.encodeIfPresent(hardwareRevision, forKey: .hardwareRevision)
            try container.encodeIfPresent(otaFirmwareRevision, forKey: .otaFirmwareRevision)
            try container.encodeIfPresent(appFirmwareRevision, forKey: .appFirmwareRevision)
            try container.encodeIfPresent(cid, forKey: .cid)
            try container.encodeIfPresent(rawFeatures, forKey: .rawFeatures)
            try container.encodeIfPresent(isOTAMode, forKey: .isOTAMode)
        }
    }

    struct KnownDevice: Codable, Equatable, Sendable {
        let identifier: UUID
        let identity: CachedIdentity
        let persistedState: PersistedDeviceState?

        init(identifier: UUID, identity: CachedIdentity, persistedState: PersistedDeviceState? = nil) {
            self.identifier = identifier
            self.identity = identity
            self.persistedState = persistedState
        }
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
    var state = DeviceState()
    var capabilities = DeviceCapabilities(features: [])
    var limits: [PowerLimitType: PowerLimitLevel] = [:]
    var limitsRevision: UInt = 0
    var limitsLoading = false
    var limitReadFailures: Set<PowerLimitType> = []
    var pendingLimits: [PowerLimitType] = []
    var toastMessage: String?
    var demoChargerConnected = false

    private(set) var knownDevices: [UUID: CachedIdentity]
    private let persistence: AppPersistence
    private let transportFactory: TransportFactory
    private var transport: (any DeviceTransport)?
    private var session: DeviceSession?
    private var demoTransport: DemoTransport?
    private var eventTask: Task<Void, Never>?
    private var sessionStateTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var supersededOperationTask: Task<Void, Never>?
    private var otaRecoveryTask: Task<Void, Never>?
    private var telemetryPersistenceTask: Task<Void, Never>?
    private var pendingTelemetryPersistence: PendingTelemetryPersistence?
    private var telemetryPersistenceGeneration: UInt = 0
    private var transportGeneration: UInt = 0
    private var operationGeneration: UInt = 0
    private var selectedPeripheralID: UUID?
    private var otaRecoveryPeripheralID: UUID?

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
        demoTransport = demo
        isDemo = true
        let generation = attach(transport: demo)
        connectionStatus = .reconnecting
        route = .connected

        let operation = beginOperation(for: generation, transport: demo)
        operationTask = Task { [weak self] in
            do {
                _ = try await demo.connectDemo()
                guard let self, self.isCurrent(operation) else { return }
            } catch {
                guard let self, self.isCurrent(operation) else { return }
                connectionStatus = .disconnected(String(describing: error))
            }
        }
    }

    func requestBluetoothAfterPriming() {
        persistence.onboardingComplete = true
        isDemo = false
        demoTransport = nil
        capabilities = DeviceCapabilities(features: [])
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
        guard let context = beginOperationForCurrentTransport() else { return }
        operationTask = Task { [weak self] in
            await context.transport.disconnect()
            guard let self, self.isCurrent(context) else { return }
            do {
                try await context.transport.startScan()
            } catch {
                guard self.isCurrent(context) else { return }
                presentBluetoothFailure(error)
            }
        }
    }

    func setDC(_ enabled: Bool) {
        performPortMutation(.setDC(enabled))
    }

    func setTypeCOutput(_ enabled: Bool) {
        performPortMutation(.setTypeCOutput(enabled))
    }

    func refreshTelemetry() async {
        guard let transport else { return }
        do {
            try await transport.refreshTelemetry()
        } catch {
            showToast(String(describing: error))
        }
    }

    func loadLimits() async {
        guard capabilities.hasPowerLimits else { return }
        limitsLoading = true
        defer { limitsLoading = false }
        for type in PowerLimitType.allCases {
            await readLimit(type)
        }
    }

    func setLimit(_ type: PowerLimitType, level: PowerLimitLevel) async {
        await mutateLimit(type, command: .setPowerLimit(type, level: level))
    }

    func resetLimit(_ type: PowerLimitType) async {
        await mutateLimit(type, command: .clearPowerLimit(type))
    }

    func setDemoChargerConnected(_ connected: Bool) {
        guard let demoTransport else { return }
        demoChargerConnected = connected
        Task { await demoTransport.setChargerConnected(connected) }
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
        macAddress: String? = nil,
        modelNumber: String? = nil,
        hardwareRevision: String? = nil,
        otaFirmwareRevision: String? = nil,
        appFirmwareRevision: String? = nil,
        cid: UInt16? = nil,
        rawFeatures: UInt32? = nil,
        isOTAMode: Bool? = nil
    ) {
        knownDevices[deviceID] = CachedIdentity(
            advertisedName: advertisedName,
            deviceInformationName: deviceInformationName,
            macAddress: macAddress,
            modelNumber: modelNumber,
            hardwareRevision: hardwareRevision,
            otaFirmwareRevision: otaFirmwareRevision,
            appFirmwareRevision: appFirmwareRevision,
            cid: cid,
            rawFeatures: rawFeatures,
            isOTAMode: isOTAMode
        )
        persistence.saveKnownDevices(knownDevices)
    }

    private func startReturningSession() {
        let restoredTransport = transportFactory()
        guard let storedID = persistence.lastSuccessfulPeripheralID else {
            attach(transport: restoredTransport)
            startScanning()
            return
        }

        let persisted = persistence.loadPersistedDeviceState(for: storedID)
        let restoredCapabilities = DeviceCapabilities(features: FeatureFlags(
            rawValue: persisted?.resolvedFeaturesRawValue ?? 0
        ))
        let cachedIdentity = knownDevices[storedID]
        let hasTelemetry = persisted?.battery != nil || persisted?.dc != nil || persisted?.typeC != nil
        let restoredState = DeviceState(
            identity: cachedIdentity.map {
                restoredIdentity(identifier: storedID, identity: $0, capabilities: restoredCapabilities)
            },
            connection: .reconnecting,
            freshness: hasTelemetry ? .stale : .loading,
            battery: persisted?.battery?.value,
            dc: persisted?.dc?.value,
            typeC: persisted?.typeC?.value,
            lastTelemetryAt: nil
        )
        let generation = attach(
            transport: restoredTransport,
            initialState: restoredState,
            initialCapabilities: restoredCapabilities
        )

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
    private func attach(
        transport: any DeviceTransport,
        initialState: DeviceState = DeviceState(),
        initialCapabilities: DeviceCapabilities = DeviceCapabilities(features: [])
    ) -> UInt {
        flushPendingTelemetryPersistence()
        telemetryPersistenceTask?.cancel()
        let previousTransport = self.transport
        supersedeCurrentOperation()
        eventTask?.cancel()
        sessionStateTask?.cancel()
        otaRecoveryTask?.cancel()
        otaRecoveryTask = nil
        if let previousTransport {
            Task { await previousTransport.disconnect() }
        }
        transportGeneration &+= 1
        operationGeneration &+= 1
        let generation = transportGeneration
        self.transport = transport
        let session = DeviceSession(transport: transport, initialState: initialState)
        self.session = session
        state = initialState
        capabilities = initialCapabilities
        limits.removeAll()
        limitsRevision = 0
        limitsLoading = false
        limitReadFailures.removeAll()
        pendingLimits.removeAll()
        toastMessage = nil
        demoChargerConnected = false
        otaRecoveryDevice = nil
        otaRecoveryPeripheralID = nil
        sessionStateTask = Task { [weak self] in
            for await nextState in session.states {
                guard !Task.isCancelled,
                      let self,
                      transportGeneration == generation
                else { return }
                applySessionState(nextState)
            }
        }
        let events = transport.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled,
                      let self,
                      self.transportGeneration == generation
                else { return }
                await session.receive(event)
                guard self.transportGeneration == generation else { return }
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
            if otaRecoveryPeripheralID == id {
                connectionStatus = .disconnected(nil)
                route = .scan
                return
            }
            if !isDemo {
                persistence.lastSuccessfulPeripheralID = id
                selectedPeripheralID = id
                if state.identity?.peripheralID != id,
                   let advertisedName = discoveredDevices.first(where: { $0.id == id })?.localName
                    ?? knownDevices[id]?.advertisedName {
                    let existing = knownDevices[id]
                    recordSuccessfulHandshake(
                        deviceID: id,
                        advertisedName: advertisedName,
                        deviceInformationName: existing?.deviceInformationName,
                        macAddress: existing?.macAddress,
                        modelNumber: existing?.modelNumber,
                        hardwareRevision: existing?.hardwareRevision,
                        otaFirmwareRevision: existing?.otaFirmwareRevision,
                        appFirmwareRevision: existing?.appFirmwareRevision,
                        cid: existing?.cid,
                        rawFeatures: existing?.rawFeatures,
                        isOTAMode: existing?.isOTAMode
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
            flushPendingTelemetryPersistence()
            connectionStatus = .disconnected(failure?.message)
            if otaRecoveryPeripheralID != nil {
                route = .scan
            } else if selectedPeripheralID != nil || isDemo {
                route = .connected
            }
        case let .handshakeCompleted(snapshot):
            let isOTAMode = snapshot.mode == .ota
            capabilities = isOTAMode ? DeviceCapabilities(features: []) : snapshot.capabilities
            selectedPeripheralID = snapshot.peripheralID
            let advertisedName = snapshot.advertisedName
                ?? knownDevices[snapshot.peripheralID]?.advertisedName
                ?? "Wattline device"
            if isDemo {
                connectedName = advertisedName
            } else {
                recordSuccessfulHandshake(
                    deviceID: snapshot.peripheralID,
                    advertisedName: advertisedName,
                    deviceInformationName: snapshot.modelNumber,
                    macAddress: snapshot.macAddress,
                    modelNumber: snapshot.modelNumber,
                    hardwareRevision: snapshot.hardwareRevision,
                    otaFirmwareRevision: snapshot.otaFirmwareRevision,
                    appFirmwareRevision: snapshot.appFirmwareRevision,
                    cid: snapshot.cid,
                    rawFeatures: snapshot.rawFeatures,
                    isOTAMode: isOTAMode
                )
                if !isOTAMode {
                    persistence.saveResolvedFeatures(capabilities.features.rawValue, for: snapshot.peripheralID)
                    flushPendingTelemetryPersistence()
                }
                connectedName = knownDevices[snapshot.peripheralID]?.name
            }
            if isOTAMode {
                otaRecoveryPeripheralID = snapshot.peripheralID
                let discovered = discoveredDevices.first { $0.id == snapshot.peripheralID }
                otaRecoveryDevice = DiscoveredDevice(
                    id: snapshot.peripheralID,
                    localName: snapshot.advertisedName ?? discovered?.localName ?? "PeakDo-OTA",
                    rssi: discovered?.rssi ?? -127,
                    mode: .ota
                )
                connectionStatus = .disconnected(nil)
                route = .scan
                beginOTARecoveryScan(generation: generation)
            } else {
                otaRecoveryPeripheralID = nil
            }
        case let .battery(value, _):
            queueTelemetryPersistence { pending, observedAt in
                pending.battery = PersistedObservation(value: value, observedAt: observedAt)
            }
        case let .dc(value, _):
            queueTelemetryPersistence { pending, observedAt in
                pending.dc = PersistedObservation(value: value, observedAt: observedAt)
            }
        case let .typeC(value, _):
            queueTelemetryPersistence { pending, observedAt in
                pending.typeC = PersistedObservation(value: value, observedAt: observedAt)
            }
        case .transactionDepth:
            break
        }
    }

    private func restoredIdentity(
        identifier: UUID,
        identity: CachedIdentity,
        capabilities: DeviceCapabilities
    ) -> DeviceIdentitySnapshot {
        DeviceIdentitySnapshot(
            peripheralID: identifier,
            advertisedName: identity.advertisedName,
            mode: identity.isOTAMode == true ? .ota : .application,
            modelNumber: identity.modelNumber,
            hardwareRevision: identity.hardwareRevision,
            otaFirmwareRevision: identity.otaFirmwareRevision,
            appFirmwareRevision: identity.appFirmwareRevision,
            cid: identity.cid,
            rawFeatures: identity.rawFeatures,
            macAddress: identity.macAddress,
            capabilities: capabilities
        )
    }

    private func queueTelemetryPersistence(
        update: (inout PendingTelemetryPersistence, Date) -> Void
    ) {
        guard !isDemo, let selectedPeripheralID else { return }
        if let pendingTelemetryPersistence,
           pendingTelemetryPersistence.identifier != selectedPeripheralID
            || pendingTelemetryPersistence.transportGeneration != transportGeneration {
            flushPendingTelemetryPersistence()
        }
        if pendingTelemetryPersistence == nil {
            pendingTelemetryPersistence = PendingTelemetryPersistence(
                identifier: selectedPeripheralID,
                transportGeneration: transportGeneration
            )
        }
        update(&pendingTelemetryPersistence!, persistence.currentDate)

        telemetryPersistenceTask?.cancel()
        telemetryPersistenceGeneration &+= 1
        let generation = telemetryPersistenceGeneration
        telemetryPersistenceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
            guard let self, telemetryPersistenceGeneration == generation else { return }
            flushPendingTelemetryPersistence(retainIfDeviceUnknown: true)
        }
    }

    private func flushPendingTelemetryPersistence(retainIfDeviceUnknown: Bool = false) {
        guard let pending = pendingTelemetryPersistence else { return }
        let didSave = persistence.saveTelemetry(
            battery: pending.battery,
            dc: pending.dc,
            typeC: pending.typeC,
            for: pending.identifier
        )
        guard didSave || !retainIfDeviceUnknown else {
            telemetryPersistenceTask = nil
            return
        }
        telemetryPersistenceTask?.cancel()
        telemetryPersistenceTask = nil
        pendingTelemetryPersistence = nil
    }

    private struct PendingTelemetryPersistence {
        let identifier: UUID
        let transportGeneration: UInt
        var battery: PersistedObservation<BatteryStatus>?
        var dc: PersistedObservation<DCPortStatus>?
        var typeC: PersistedObservation<TypeCPortStatus>?

        init(identifier: UUID, transportGeneration: UInt) {
            self.identifier = identifier
            self.transportGeneration = transportGeneration
        }
    }

    private func applySessionState(_ nextState: DeviceState) {
        let newError = nextState.lastError
        let shouldToast = newError != nil && newError != state.lastError
        state = nextState
        if shouldToast, let newError { showToast(newError) }
    }

    private func performPortMutation(_ command: DeviceCommand) {
        guard let session else { return }
        Task { [weak self] in
            do {
                _ = try await session.perform(command)
            } catch {
                guard let self else { return }
                showToast(String(describing: error))
            }
        }
    }

    @discardableResult
    private func readLimit(_ type: PowerLimitType, showError: Bool = true) async -> Bool {
        guard let session else { return false }
        do {
            let outcome = try await session.perform(.getPowerLimit(type))
            guard applyLimitReply(outcome, type: type) else {
                if showError { showToast("Device returned an invalid power-limit value.") }
                return false
            }
            state = await session.state
            return true
        } catch {
            if showError {
                limits[type] = nil
                limitReadFailures.insert(type)
                limitsRevision &+= 1
                showToast(String(describing: error))
            }
            return false
        }
    }

    private func mutateLimit(_ type: PowerLimitType, command: DeviceCommand) async {
        guard let session else { return }
        let confirmedValue = limits[type]
        if !pendingLimits.contains(type) { pendingLimits.append(type) }
        defer { pendingLimits.removeAll { $0 == type } }
        do {
            let outcome = try await session.perform(command)
            guard applyLimitReply(outcome, type: type) else {
                throw LimitReadbackError.invalidValue
            }
            state = await session.state
        } catch {
            showToast(error is LimitReadbackError
                ? "Device returned an invalid power-limit value."
                : String(describing: error))
            if !(await readLimit(type, showError: false)) {
                limits[type] = confirmedValue
                limitReadFailures.remove(type)
                limitsRevision &+= 1
            }
        }
    }

    @discardableResult
    private func applyLimitReply(_ outcome: CommandOutcome, type: PowerLimitType) -> Bool {
        guard case let .reply(reply) = outcome else { return false }
        if reply.result == 0xFF, type == .runtime {
            limits[type] = nil
            limitReadFailures.remove(type)
            limitsRevision &+= 1
            return true
        } else if reply.result == 0,
                  let raw = reply.payload.first,
                  let level = PowerLimitLevel(rawValue: raw) {
            limits[type] = level
            limitReadFailures.remove(type)
            limitsRevision &+= 1
            return true
        }
        limitReadFailures.insert(type)
        return false
    }

    private enum LimitReadbackError: Error {
        case invalidValue
    }

    private func beginOTARecoveryScan(generation: UInt) {
        guard let transport else { return }
        otaRecoveryTask?.cancel()
        otaRecoveryTask = Task { [weak self] in
            await transport.disconnect()
            guard !Task.isCancelled,
                  let self,
                  transportGeneration == generation,
                  otaRecoveryPeripheralID != nil
            else { return }
            do {
                try await transport.startScan()
            } catch {
                guard transportGeneration == generation else { return }
                presentBluetoothFailure(error)
            }
        }
    }

    private func showToast(_ message: String) {
        toastMessage = message
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard self?.toastMessage == message else { return }
            self?.toastMessage = nil
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
        bluetoothIssue = BluetoothFailurePolicy.issue(
            authorization: CBManager.authorization,
            errorDescription: String(describing: error)
        )
    }
}

enum BluetoothFailurePolicy {
    static func issue(
        authorization: CBManagerAuthorization,
        errorDescription: String
    ) -> AppModel.BluetoothIssue {
        switch authorization {
        case .denied, .restricted:
            .deniedOrRestricted
        case .allowedAlways, .notDetermined:
            .unavailable(errorDescription)
        @unknown default:
            .unavailable(errorDescription)
        }
    }
}
