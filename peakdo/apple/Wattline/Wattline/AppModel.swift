import CoreBluetooth
import Foundation
import Observation
import WattlineCore
import WattlineNetwork
import WattlineUI

@MainActor
@Observable
final class AppModel {
    typealias TransportFactory = @MainActor () -> any DeviceTransport
    typealias BrokerPublicationBarrier = @Sendable () async -> Void
    typealias BrokerCompletionBarrier = @Sendable () async -> Void
    typealias ConnectedLifecycleBarrier = @Sendable () async -> Void

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

    enum MaintenanceState: Equatable {
        case idle
        case restarting
        case restartFailed(String)
        case shuttingDown
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
    private(set) var activeTransportKind: AppTransportKind = .bluetooth
    var discoveredDevices: [DiscoveredDevice] = []
    var bluetoothIssue: BluetoothIssue?
    var otaRecoveryDevice: DiscoveredDevice?
    var connectionStatus: ConnectionStatus = .disconnected(nil)
    private(set) var maintenanceState: MaintenanceState = .idle
    private(set) var scanStartsForTesting = 0
    private(set) var reconnectAttemptsForTesting = 0
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
    private(set) var sharedSnapshot: SharedDeviceSnapshot?
    private(set) var lastClockSync: Date?
    private(set) var deviceClockDrift: TimeInterval?

    var clockStatusText: String {
        guard let drift = deviceClockDrift else { return "Drift unavailable" }
        return String(format: "Drift %.1fs", drift)
    }

    var lowBatteryEnabled: Bool { persistence.lowBatteryEnabled }
    var lowBatteryThreshold: Int { persistence.lowBatteryThreshold }
    var systemSurfacePreferences: SystemSurfacePreferences { persistence.systemSurfacePreferences }

    func setLiveActivityCharging(_ enabled: Bool) {
        var preferences = persistence.systemSurfacePreferences
        preferences.liveActivityCharging = enabled
        persistence.systemSurfacePreferences = preferences
    }

    func setLiveActivityDischarging(_ enabled: Bool) {
        var preferences = persistence.systemSurfacePreferences
        preferences.liveActivityDischarging = enabled
        persistence.systemSurfacePreferences = preferences
    }

    func setLowBatteryThreshold(_ threshold: Int) {
        var preferences = persistence.systemSurfacePreferences
        preferences.lowBatteryThreshold = threshold
        persistence.systemSurfacePreferences = preferences
        lowBatteryNotificationCoordinator.setThreshold(preferences.lowBatteryThreshold)
    }

    func setLowBatteryEnabled(_ enabled: Bool) async -> NotificationActionResult {
        let result = await lowBatteryNotificationCoordinator.setEnabled(enabled)
        // Persist only an actually authorized/enabled state; denied authorization
        // must leave the user preference off so a later retry remains possible.
        if result == .success {
            persistence.lowBatteryEnabled = enabled
            var preferences = persistence.systemSurfacePreferences
            preferences.lowBatteryEnabled = enabled
            persistence.systemSurfacePreferences = preferences
        }
        return result
    }

    private(set) var knownDevices: [UUID: CachedIdentity]
    private let persistence: AppPersistence
    private let transportFactory: TransportFactory
    private let brokerPublicationBarrier: BrokerPublicationBarrier
    private let brokerCompletionBarrier: BrokerCompletionBarrier
    private let connectedLifecycleBarrier: ConnectedLifecycleBarrier
    private let notificationAdapter: any NotificationCenterAdapter
    private let maintenanceClock: any DeviceClock
    private let snapshotCoordinator: SnapshotCoordinator?
    private let widgetReloadAdapter: WidgetReloadAdapter?
    private let liveActivityCoordinator: LiveActivityCoordinator
    let routerConnections: RouterConnectionModel
    private var snapshotFlushTask: Task<Void, Never>?
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
    private var brokerContextGeneration: UInt?
    private var brokerContextPeripheralID: UUID?
    private var brokerContextLifecycle: DeviceOperationBroker.ContextLifecycle?
    private var brokerPublicationTask: Task<Void, Never>?
    private(set) var brokerReconnectAttempt: DeviceOperationBroker.ConnectionAttempt?
    private var brokerReconnectScope: DeviceConnectionScope?
    private var brokerReconnectTask: Task<Void, Never>?
    private var restartTimeoutTask: Task<Void, Never>?
    private var restartRecoveryTask: Task<Void, Never>?
    private struct RestartDisconnectKey: Equatable {
        let generation: UInt
        let scope: DeviceConnectionScope
    }
    private struct RestartDisconnectWaiter {
        let id: UUID
        let operationID: UUID
        let key: RestartDisconnectKey
        let continuation: CheckedContinuation<Bool, Never>
        let timeoutTask: Task<Void, Never>
    }
    // Set only by the scoped disconnect event caused by the current restart.
    // This prevents a connected fast-path (or an unrelated write error) from
    // being mistaken for successful restart recovery.
    private var restartDisconnectObserved: RestartDisconnectKey?
    private var restartDisconnectWaiter: RestartDisconnectWaiter?
    private var restartOperationID: UUID?
    private var connectionOperationKey: ConnectionOperationKey?
    private var activeConnectionScope: DeviceConnectionScope?
    private var retiredConnectionScopeIDs: Set<UUID> = []
    private var activeRouterEndpoints: Set<RouterEndpointCapability>?

    @ObservationIgnored
    private(set) lazy var deviceOperationBroker = DeviceOperationBroker(
        clock: maintenanceClock
    ) { [weak self] attempt in
        await self?.startBrokerReconnect(attempt)
    }

    @ObservationIgnored
    private(set) lazy var lowBatteryNotificationCoordinator: LowBatteryNotificationCoordinator = {
        LowBatteryNotificationCoordinator(
            notifications: notificationAdapter,
            broker: deviceOperationBroker,
            peripheralID: { [weak self] in self?.selectedPeripheralID },
            snapshot: { [weak self] in self?.sharedSnapshot },
            capabilities: { [weak self] in self?.capabilities ?? DeviceCapabilities(features: []) },
            threshold: persistence.lowBatteryThreshold
        )
    }()

    init(
        persistence: AppPersistence = AppPersistence(),
        transportFactory: @escaping TransportFactory = { BLETransport() },
        brokerPublicationBarrier: @escaping BrokerPublicationBarrier = {},
        brokerCompletionBarrier: @escaping BrokerCompletionBarrier = {},
        connectedLifecycleBarrier: @escaping ConnectedLifecycleBarrier = {},
        notificationAdapter: any NotificationCenterAdapter = SystemNotificationCenterAdapter(),
        maintenanceClock: any DeviceClock = ContinuousDeviceClock(),
        snapshotCoordinator: SnapshotCoordinator? = SnapshotCoordinator.production(),
        widgetReloadAdapter: WidgetReloadAdapter? = WidgetReloadAdapter(),
        liveActivityAdapter: any LiveActivityAdapter = SystemLiveActivityAdapter(),
        routerConnections: RouterConnectionModel = .production()
    ) {
        self.persistence = persistence
        self.transportFactory = transportFactory
        self.brokerPublicationBarrier = brokerPublicationBarrier
        self.brokerCompletionBarrier = brokerCompletionBarrier
        self.connectedLifecycleBarrier = connectedLifecycleBarrier
        self.notificationAdapter = notificationAdapter
        self.maintenanceClock = maintenanceClock
        self.snapshotCoordinator = snapshotCoordinator
        self.widgetReloadAdapter = widgetReloadAdapter
        self.liveActivityCoordinator = LiveActivityCoordinator(adapter: liveActivityAdapter)
        self.routerConnections = routerConnections
        let onboardingComplete = persistence.onboardingComplete
        route = onboardingComplete ? .scan : .onboarding
        knownDevices = persistence.loadKnownDevices()

        Task { await routerConnections.reloadSavedHosts() }

        if persistence.systemSurfacePreferences.lowBatteryEnabled {
            Task { @MainActor [weak self] in
                await self?.lowBatteryNotificationCoordinator.restoreEnabled()
            }
        }

        if onboardingComplete {
            startReturningSession()
        }
    }

    #if DEBUG
    var hasSnapshotCoordinatorForTesting: Bool { snapshotCoordinator != nil }
    var restartOperationIDForTesting: UUID? { restartOperationID }

    func waitForSnapshotFanOutForTesting() async {
        await snapshotFlushTask?.value
    }
    #endif

    var sortedDevices: [DiscoveredDevice] {
        discoveredDevices.sorted { lhs, rhs in
            let lhsKnown = knownDevices[lhs.id] != nil
            let rhsKnown = knownDevices[rhs.id] != nil
            if lhsKnown != rhsKnown { return lhsKnown }
            if lhs.rssi != rhs.rssi { return lhs.rssi > rhs.rssi }
            return lhs.localName.localizedCaseInsensitiveCompare(rhs.localName) == .orderedAscending
        }
    }

    func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "wattline",
              url.host?.lowercased() == "dashboard" else { return }
        guard route != .onboarding else { return }
        route = .connected
    }

    func enterDemo() {
        let demo = DemoTransport(seed: 0x57415454)
        demoTransport = demo
        isDemo = true
        activeTransportKind = .demo
        activeRouterEndpoints = nil
        snapshotCoordinator?.setDemo(true)
        let generation = attach(transport: demo)
        selectedPeripheralID = DemoTransport.deviceID
        connectionStatus = .reconnecting
        route = .connected

        let operation = beginOperation(for: generation, transport: demo)
        let brokerContext = prepareBrokerContext(
            peripheralID: DemoTransport.deviceID,
            generation: generation
    )

        operationTask = Task { [weak self] in
            do {
                await self?.publishBrokerContext(brokerContext)
                guard let self, self.isCurrent(operation) else { return }
                let scope = await demo.makeConnectionScope(for: DemoTransport.deviceID)
                guard self.isCurrent(operation) else { return }
                let connectionKey = ConnectionOperationKey(
                    transportGeneration: operation.transportGeneration,
                    operationGeneration: operation.operationGeneration,
                    peripheralID: DemoTransport.deviceID,
                    scope: scope
                )
                connectionOperationKey = connectionKey
                try await demo.connect(to: DemoTransport.deviceID, scope: scope)
                guard self.isCurrent(operation) else { return }
                await self.completeConnectionOperation(connectionKey)
            } catch {
                guard let self, self.isCurrent(operation) else { return }
                connectionOperationKey = nil
                connectionStatus = .disconnected(String(describing: error))
            }
        }
    }

    func requestBluetoothAfterPriming() {
        persistence.onboardingComplete = true
        isDemo = false
        snapshotCoordinator?.setDemo(false)
        demoTransport = nil
        activeTransportKind = .bluetooth
        activeRouterEndpoints = nil
        capabilities = DeviceCapabilities(features: [])
        bluetoothIssue = nil

        // This factory reaches BLETransport only after explicit permission priming on first use.
        attach(transport: transportFactory())
        route = .scan
        startScanning()
    }

    func connectViaRouter(
        _ host: RouterHostMetadata,
        endpoints: Set<RouterEndpointCapability> = Set(RouterEndpointCapability.allCases)
    ) {
        do {
            let routerTransport = try routerConnections.makeTransport(for: host)
            isDemo = false
            demoTransport = nil
            snapshotCoordinator?.setDemo(false)
            activeTransportKind = .router
            activeRouterEndpoints = endpoints
            discoveredDevices.removeAll()
            let generation = attach(transport: routerTransport)
            let peripheralID = host.endpoint.peripheralID
            selectedPeripheralID = peripheralID
            connectedName = host.displayName
            connectionStatus = .reconnecting
            route = .connected
            let operation = beginOperation(for: generation, transport: routerTransport)
            let brokerContext = prepareBrokerContext(
                peripheralID: peripheralID,
                generation: generation
            )
            operationTask = Task { [weak self] in
                do {
                    await self?.publishBrokerContext(brokerContext)
                    guard let self, self.isCurrent(operation) else { return }
                    let scope = await routerTransport.makeConnectionScope(for: peripheralID)
                    guard self.isCurrent(operation) else { return }
                    let connectionKey = ConnectionOperationKey(
                        transportGeneration: operation.transportGeneration,
                        operationGeneration: operation.operationGeneration,
                        peripheralID: peripheralID,
                        scope: scope
                    )
                    connectionOperationKey = connectionKey
                    try await routerTransport.connect(to: peripheralID, scope: scope)
                    guard self.isCurrent(operation) else { return }
                    await self.completeConnectionOperation(connectionKey)
                } catch {
                    guard let self, self.isCurrent(operation) else { return }
                    connectionOperationKey = nil
                    connectionStatus = .disconnected(String(describing: error))
                }
            }
        } catch {
            showToast(String(describing: error))
        }
    }

    func startScanning() {
        scanStartsForTesting += 1
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

    func restartDevice() async {
        guard let peripheralID = selectedPeripheralID,
              let scope = activeConnectionScope,
              scope.peripheralID == peripheralID
        else { return }
        let generation = transportGeneration
        let disconnectKey = RestartDisconnectKey(generation: generation, scope: scope)
        let operationID = UUID()
        restartTimeoutTask?.cancel()
        restartRecoveryTask?.cancel()
        restartDisconnectObserved = nil
        cancelRestartDisconnectWaiter()
        restartOperationID = operationID
        maintenanceState = .restarting
        var writeFailure: Error?
        do {
            _ = try await deviceOperationBroker.perform(.restart, generation: generation)
        } catch {
            writeFailure = error
        }
        guard isCurrentRestart(operationID, key: disconnectKey) else { return }
        let observed = await awaitRestartDisconnect(disconnectKey, operationID: operationID)
        if Task.isCancelled {
            cancelRestartOperationIfCurrent(operationID)
            return
        }
        guard isCurrentRestart(operationID, key: disconnectKey) else { return }
        guard observed else {
            restartOperationID = nil
            maintenanceState = .restartFailed(
                writeFailure.map(String.init(describing:)) ?? "Restart timed out. Try again."
            )
            return
        }
        restartRecoveryTask = Task { [weak self] in
            await self?.recoverRestart(disconnectKey, operationID: operationID)
        }
    }

    private func awaitRestartDisconnect(
        _ key: RestartDisconnectKey,
        operationID: UUID
    ) async -> Bool {
        if restartDisconnectObserved == key { return true }
        let waiterID = UUID()
        let cancelWaiter: @MainActor @Sendable () -> Void = { [weak self] in
            self?.resolveRestartDisconnect(waiterID: waiterID, observed: false)
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                cancelRestartDisconnectWaiter()
                let timeoutTask = Task { [weak self, maintenanceClock] in
                    do {
                        try await maintenanceClock.sleep(for: .seconds(1))
                    } catch {
                        return
                    }
                    await MainActor.run {
                        self?.resolveRestartDisconnect(waiterID: waiterID, observed: false)
                    }
                }
                restartDisconnectWaiter = RestartDisconnectWaiter(
                    id: waiterID,
                    operationID: operationID,
                    key: key,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
            }
        } onCancel: {
            Task { @MainActor in cancelWaiter() }
        }
    }

    private func resolveRestartDisconnect(waiterID: UUID, observed: Bool) {
        guard let waiter = restartDisconnectWaiter, waiter.id == waiterID else { return }
        restartDisconnectWaiter = nil
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(returning: observed)
    }

    private func observeRestartDisconnect(scope: DeviceConnectionScope, generation: UInt) {
        guard maintenanceState == .restarting,
              selectedPeripheralID == scope.peripheralID
        else { return }
        let key = RestartDisconnectKey(generation: generation, scope: scope)
        if let restartDisconnectObserved, restartDisconnectObserved != key {
            return
        }
        restartDisconnectObserved = key
        guard let waiter = restartDisconnectWaiter,
              waiter.key == key,
              waiter.operationID == restartOperationID
        else { return }
        resolveRestartDisconnect(waiterID: waiter.id, observed: true)
    }

    private func cancelRestartDisconnectWaiter() {
        guard let waiter = restartDisconnectWaiter else { return }
        resolveRestartDisconnect(waiterID: waiter.id, observed: false)
    }

    private func isCurrentRestart(_ operationID: UUID, key: RestartDisconnectKey) -> Bool {
        restartOperationID == operationID
            && transportGeneration == key.generation
            && selectedPeripheralID == key.scope.peripheralID
            && maintenanceState == .restarting
    }

    private func cancelRestartOperationIfCurrent(_ operationID: UUID) {
        guard restartOperationID == operationID else { return }
        restartOperationID = nil
        cancelRestartDisconnectWaiter()
        if maintenanceState == .restarting { maintenanceState = .idle }
    }

    func retryRestart() async {
        if case .restartFailed = maintenanceState,
           let disconnectKey = restartDisconnectObserved,
           disconnectKey.generation == transportGeneration,
           selectedPeripheralID == disconnectKey.scope.peripheralID,
           activeConnectionScope == nil {
            let operationID = UUID()
            restartRecoveryTask?.cancel()
            restartOperationID = operationID
            maintenanceState = .restarting
            restartRecoveryTask = Task { [weak self] in
                await self?.recoverRestart(disconnectKey, operationID: operationID)
            }
            return
        }
        await restartDevice()
    }

    private func failRestartRecoveryIfCurrent(
        _ message: String,
        disconnectKey: RestartDisconnectKey,
        operationID: UUID
    ) async {
        guard isCurrentRestart(operationID, key: disconnectKey) else { return }
        if let attempt = brokerReconnectAttempt,
           attempt.generation == disconnectKey.generation,
           attempt.peripheralID == disconnectKey.scope.peripheralID {
            await terminalizeBrokerReconnect(attempt, retireScope: true)
        }
        guard isCurrentRestart(operationID, key: disconnectKey) else { return }
        restartOperationID = nil
        maintenanceState = .restartFailed(message)
    }

    private func recoverRestart(_ disconnectKey: RestartDisconnectKey, operationID: UUID) async {
        let generation = disconnectKey.generation
        let peripheralID = disconnectKey.scope.peripheralID
        let deadline = (await maintenanceClock.now) + .seconds(30)
        while !Task.isCancelled,
              transportGeneration == generation,
              selectedPeripheralID == peripheralID,
              restartOperationID == operationID,
              maintenanceState == .restarting {
            // Do not let withConnection reuse the still-connected context. A
            // fresh reconnect is valid only after the expected disconnect event
            // for this exact generation/peripheral has arrived.
            guard restartDisconnectObserved == disconnectKey else {
                do { try await maintenanceClock.sleep(for: .seconds(1)) }
                catch { return }
                continue
            }
            let now = await maintenanceClock.now
            guard isCurrentRestart(operationID, key: disconnectKey) else { return }
            guard now < deadline else {
                await failRestartRecoveryIfCurrent(
                    "Restart timed out. Try again.",
                    disconnectKey: disconnectKey,
                    operationID: operationID
                )
                return
            }
            do {
                _ = try await deviceOperationBroker.withConnection(to: peripheralID, timeout: deadline - now) { _ in () }
                guard transportGeneration == generation,
                      selectedPeripheralID == peripheralID,
                      restartOperationID == operationID,
                      maintenanceState == .restarting
                else { return }
                return
            } catch is CancellationError {
                return
            } catch {
                let retryNow = await maintenanceClock.now
                guard isCurrentRestart(operationID, key: disconnectKey) else { return }
                guard retryNow < deadline else {
                    await failRestartRecoveryIfCurrent(
                        "Restart timed out. Try again.",
                        disconnectKey: disconnectKey,
                        operationID: operationID
                    )
                    return
                }
                do { try await maintenanceClock.sleep(for: min(.seconds(1), deadline - retryNow)) }
                catch { return }
            }
        }
        guard !Task.isCancelled else { return }
        guard transportGeneration == generation,
              selectedPeripheralID == peripheralID,
              restartOperationID == operationID
        else { return }
        if maintenanceState == .restarting {
            await failRestartRecoveryIfCurrent(
                "Restart timed out. Try again.",
                disconnectKey: disconnectKey,
                operationID: operationID
            )
        }
    }

    func shutdownDevice() async {
        guard selectedPeripheralID != nil else { return }
        maintenanceState = .shuttingDown
        do {
            _ = try await deviceOperationBroker.perform(.shutdown, generation: transportGeneration)
            maintenanceState = .idle
            returnToScan()
        } catch {
            // A failed FM write is an ordinary device-operation error: retain the
            // connected route and surface the transport error without presenting it
            // as a restart failure or clearing the selected peripheral.
            maintenanceState = .idle
            connectionStatus = .disconnected(String(describing: error))
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
            otaRecoveryPeripheralID = device.id
            return
        }
        retireActiveConnectionScope()
        selectedPeripheralID = device.id
        connectedName = knownDevices[device.id]?.name ?? device.localName
        guard let context = beginOperationForCurrentTransport() else { return }
        let brokerContext = prepareBrokerContext(
            peripheralID: device.id,
            generation: context.transportGeneration
        )
        operationTask = Task { [weak self] in
            do {
                await self?.publishBrokerContext(brokerContext)
                guard let self, self.isCurrent(context) else { return }
                await context.transport.stopScan()
                guard self.isCurrent(context) else { return }
                let scope = await context.transport.makeConnectionScope(for: device.id)
                guard self.isCurrent(context) else { return }
                let connectionKey = ConnectionOperationKey(
                    transportGeneration: context.transportGeneration,
                    operationGeneration: context.operationGeneration,
                    peripheralID: device.id,
                    scope: scope
                )
                connectionOperationKey = connectionKey
                try await context.transport.connect(to: device.id, scope: scope)
                guard self.isCurrent(context) else { return }
                await self.completeConnectionOperation(connectionKey)
            } catch {
                guard let self, self.isCurrent(context) else { return }
                self.connectionOperationKey = nil
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
        let brokerContext = prepareBrokerContext(
            peripheralID: selectedPeripheralID,
            generation: context.transportGeneration
        )
        operationTask = Task { [weak self] in
            do {
                await self?.publishBrokerContext(brokerContext)
                guard let self, self.isCurrent(context) else { return }
                let scope = await context.transport.makeConnectionScope(for: selectedPeripheralID)
                guard self.isCurrent(context) else { return }
                let connectionKey = ConnectionOperationKey(
                    transportGeneration: context.transportGeneration,
                    operationGeneration: context.operationGeneration,
                    peripheralID: selectedPeripheralID,
                    scope: scope
                )
                connectionOperationKey = connectionKey
                try await context.transport.connect(to: selectedPeripheralID, scope: scope)
                guard self.isCurrent(context) else { return }
                await self.completeConnectionOperation(connectionKey)
            } catch {
                guard let self, self.isCurrent(context) else { return }
                self.connectionOperationKey = nil
                connectionStatus = .disconnected(String(describing: error))
            }
        }
    }

    func returnToScan() {
        restartRecoveryTask?.cancel()
        restartTimeoutTask?.cancel()
        restartOperationID = nil
        cancelRestartDisconnectWaiter()
        if maintenanceState == .restarting { maintenanceState = .idle }
        invalidateBrokerContext()
        connectionOperationKey = nil
        retireActiveConnectionScope()
        selectedPeripheralID = nil
        otaRecoveryPeripheralID = nil
        route = .scan
        connectionStatus = .disconnected(nil)
        let broker = deviceOperationBroker
        let generation = transportGeneration
        let barrier = brokerPublicationBarrier
        brokerPublicationTask = Task {
            await barrier()
            await broker.detach(generation: generation)
        }
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

    func setBypass(_ enabled: Bool) {
        performPortMutation(.setBypass(enabled))
    }

    func syncClock() async {
        do {
            try await deviceOperationBroker.syncClock(generation: transportGeneration)
            lastClockSync = persistence.currentDate
            await refreshClockDrift()
        } catch {
            showToast(String(describing: error))
        }
    }

    func refreshClockDrift() async {
        do {
            guard let date = try await deviceOperationBroker.readClock(generation: transportGeneration) else {
                deviceClockDrift = nil
                return
            }
            deviceClockDrift = abs(date.timeIntervalSince(persistence.currentDate))
        } catch {
            deviceClockDrift = nil
        }
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
            initialCapabilities: restoredCapabilities,
            peripheralID: storedID
        )

        selectedPeripheralID = storedID
        connectedName = knownDevices[storedID]?.name
        connectionStatus = .reconnecting
        route = .connected
        let operation = beginOperation(for: generation, transport: restoredTransport)
        operationTask = Task { [weak self] in
            do {
                let scope = await restoredTransport.makeConnectionScope(for: storedID)
                guard let self, self.isCurrent(operation) else { return }
                let connectionKey = ConnectionOperationKey(
                    transportGeneration: operation.transportGeneration,
                    operationGeneration: operation.operationGeneration,
                    peripheralID: storedID,
                    scope: scope
                )
                connectionOperationKey = connectionKey
                try await restoredTransport.connect(to: storedID, scope: scope)
                guard self.isCurrent(operation) else { return }
                await self.completeConnectionOperation(connectionKey)
            } catch {
                guard let self, self.isCurrent(operation) else { return }
                self.connectionOperationKey = nil
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
        initialCapabilities: DeviceCapabilities = DeviceCapabilities(features: []),
        peripheralID: UUID? = nil
    ) -> UInt {
        restartRecoveryTask?.cancel()
        restartRecoveryTask = nil
        restartOperationID = nil
        cancelRestartDisconnectWaiter()
        if maintenanceState == .restarting { maintenanceState = .idle }
        invalidateBrokerContext()
        flushPendingTelemetryPersistence()
        telemetryPersistenceTask?.cancel()
        let previousTransport = self.transport
        supersedeCurrentOperation()
        eventTask?.cancel()
        sessionStateTask?.cancel()
        otaRecoveryTask?.cancel()
        otaRecoveryTask = nil
        brokerReconnectTask?.cancel()
        brokerReconnectTask = nil
        connectionOperationKey = nil
        activeConnectionScope = nil
        retiredConnectionScopeIDs.removeAll()
        if let previousTransport {
            Task { await previousTransport.disconnect() }
        }
        let previousGeneration = transportGeneration
        transportGeneration &+= 1
        operationGeneration &+= 1
        let generation = transportGeneration
        self.transport = transport
        let session = DeviceSession(transport: transport, initialState: initialState)
        self.session = session
        let brokerContext = peripheralID.flatMap {
            prepareBrokerContext(peripheralID: $0, generation: generation)
        }
        let broker = deviceOperationBroker
        let barrier = brokerPublicationBarrier
        brokerPublicationTask = Task {
            await barrier()
            if previousGeneration != 0 {
                await broker.detach(generation: previousGeneration)
            }
            if let brokerContext {
                await broker.attach(brokerContext)
            }
        }
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
                let ownerControlsConnectedPresentation = self.ownerControlsConnectedPresentation(
                    for: event,
                    generation: generation
                )
                guard self.acceptsTransportEvent(event, generation: generation) else { continue }
                if case .disconnected = event {
                    await self.deviceOperationBroker.markDisconnected(generation: generation)
                }
                await session.receive(event)
                guard self.transportGeneration == generation else { return }
                if case let .disconnected(scope, _) = event {
                    self.observeRestartDisconnect(scope: scope, generation: generation)
                }
                await self.receive(
                    event,
                    generation: generation,
                    ownerControlsConnectedPresentation: ownerControlsConnectedPresentation
                )
            }
        }
        return generation
    }

    private func prepareBrokerContext(
        peripheralID: UUID,
        generation: UInt
    ) -> DeviceOperationBroker.Context? {
        guard transportGeneration == generation,
              let transport,
              let session
        else { return nil }
        if brokerContextGeneration != generation || brokerContextPeripheralID != peripheralID {
            invalidateBrokerContext()
            brokerContextGeneration = generation
            brokerContextPeripheralID = peripheralID
            brokerContextLifecycle = .init()
        }
        guard let brokerContextLifecycle else { return nil }
        return .init(
            generation: generation,
            peripheralID: peripheralID,
            transport: transport,
            session: session,
            lifecycle: brokerContextLifecycle
        )
    }

    private func publishBrokerContext(_ context: DeviceOperationBroker.Context?) async {
        guard let context else { return }
        await brokerPublicationBarrier()
        guard context.lifecycle.isActive else { return }
        await deviceOperationBroker.attach(context)
    }

    private func invalidateBrokerContext() {
        if let brokerReconnectScope {
            retiredConnectionScopeIDs.insert(brokerReconnectScope.sessionID)
            if activeConnectionScope == brokerReconnectScope {
                activeConnectionScope = nil
            }
        }
        brokerContextLifecycle?.invalidate()
        brokerContextGeneration = nil
        brokerContextPeripheralID = nil
        brokerContextLifecycle = nil
        brokerReconnectAttempt = nil
        brokerReconnectScope = nil
        brokerReconnectTask?.cancel()
        brokerReconnectTask = nil
    }

    private func startBrokerReconnect(_ attempt: DeviceOperationBroker.ConnectionAttempt) async {
        if let currentAttempt = brokerReconnectAttempt, currentAttempt != attempt {
            await terminalizeBrokerReconnect(currentAttempt, retireScope: true)
        }
        brokerReconnectTask?.cancel()
        let task = Task { [weak self] in
            await self?.requestBrokerReconnect(attempt)
            return
        }
        brokerReconnectTask = task
        await task.value
    }

    private func completeConnectionOperation(_ key: ConnectionOperationKey) async {
        guard connectionOperationKey == key, isCurrent(key) else { return }
        activeConnectionScope = key.scope
        if let session {
            await connectedLifecycleBarrier()
            guard connectionOperationKey == key, isCurrent(key) else { return }
            await session.receive(.connected(key.scope))
        }
        guard connectionOperationKey == key, isCurrent(key) else { return }

        let context = prepareBrokerContext(
            peripheralID: key.peripheralID,
            generation: key.transportGeneration
        )
        await publishBrokerContext(context)
        guard connectionOperationKey == key, isCurrent(key) else { return }
        await deviceOperationBroker.markConnected(
            peripheralID: key.peripheralID,
            generation: key.transportGeneration
        )
        guard connectionOperationKey == key, isCurrent(key) else { return }
        connectionOperationKey = nil
        establishConnectedPresentation(scope: key.scope)
    }

    private func isCurrent(_ key: ConnectionOperationKey) -> Bool {
        transportGeneration == key.transportGeneration
            && operationGeneration == key.operationGeneration
            && selectedPeripheralID == key.peripheralID
            && !retiredConnectionScopeIDs.contains(key.scope.sessionID)
            && (activeConnectionScope == nil || activeConnectionScope == key.scope)
    }

    private func requestBrokerReconnect(_ attempt: DeviceOperationBroker.ConnectionAttempt) async {
        reconnectAttemptsForTesting += 1
        guard transportGeneration == attempt.generation,
              selectedPeripheralID == attempt.peripheralID,
              let transport
        else {
            await deviceOperationBroker.handleConnectionEvent(.terminal, attempt: attempt)
            return
        }

        brokerReconnectAttempt = attempt
        let scope = await transport.makeConnectionScope(for: attempt.peripheralID)
        guard isCurrentBrokerReconnect(attempt, scope: nil) else { return }
        brokerReconnectScope = scope
        let brokerContext = prepareBrokerContext(
            peripheralID: attempt.peripheralID,
            generation: attempt.generation
        )
        await publishBrokerContext(brokerContext)
        guard isCurrentBrokerReconnect(attempt, scope: scope) else { return }
        connectionStatus = .reconnecting
        route = .connected
        do {
            try await transport.connect(to: attempt.peripheralID, scope: scope)
            guard isCurrentBrokerReconnect(attempt, scope: scope) else { return }
            activeConnectionScope = scope
            await brokerCompletionBarrier()
            guard isCurrentBrokerReconnect(attempt, scope: scope),
                  activeConnectionScope == scope
            else {
                await terminalizeBrokerReconnect(attempt, retireScope: true)
                return
            }
            if let session {
                await connectedLifecycleBarrier()
                guard isCurrentBrokerReconnect(attempt, scope: scope),
                      activeConnectionScope == scope
                else {
                    await terminalizeBrokerReconnect(attempt, retireScope: true)
                    return
                }
                await session.receive(.connected(scope))
            }
            guard isCurrentBrokerReconnect(attempt, scope: scope),
                  activeConnectionScope == scope
            else {
                await terminalizeBrokerReconnect(attempt, retireScope: true)
                return
            }
            await deviceOperationBroker.handleConnectionEvent(.connected, attempt: attempt)
            let brokerIsReady = await deviceOperationBroker.hasConnectedContext
            guard brokerIsReady,
                  isCurrentBrokerReconnect(attempt, scope: scope),
                  activeConnectionScope == scope
            else {
                await terminalizeBrokerReconnect(attempt, retireScope: true)
                return
            }
            brokerReconnectAttempt = nil
            brokerReconnectScope = nil
            brokerReconnectTask = nil
            establishConnectedPresentation(scope: scope)
        } catch {
            guard brokerReconnectAttempt == attempt else { return }
            connectionStatus = .disconnected(String(describing: error))
            await terminalizeBrokerReconnect(attempt, retireScope: true)
        }
    }

    private func isCurrentBrokerReconnect(
        _ attempt: DeviceOperationBroker.ConnectionAttempt,
        scope: DeviceConnectionScope?
    ) -> Bool {
        guard !Task.isCancelled,
              transportGeneration == attempt.generation,
              selectedPeripheralID == attempt.peripheralID,
              brokerReconnectAttempt == attempt
        else { return false }
        guard let scope else { return brokerReconnectScope == nil }
        return brokerReconnectScope == scope
            && !retiredConnectionScopeIDs.contains(scope.sessionID)
            && (activeConnectionScope == nil || activeConnectionScope == scope)
    }

    private func terminalizeBrokerReconnect(
        _ attempt: DeviceOperationBroker.ConnectionAttempt,
        retireScope: Bool
    ) async {
        guard brokerReconnectAttempt == attempt else { return }
        let scope = brokerReconnectScope
        brokerReconnectAttempt = nil
        brokerReconnectScope = nil
        let task = brokerReconnectTask
        brokerReconnectTask = nil
        if retireScope, let scope {
            retiredConnectionScopeIDs.insert(scope.sessionID)
            if activeConnectionScope == scope {
                activeConnectionScope = nil
            }
        }
        task?.cancel()
        await deviceOperationBroker.handleConnectionEvent(.terminal, attempt: attempt)
    }

    private func ownerControlsConnectedPresentation(
        for event: DeviceEvent,
        generation: UInt
    ) -> Bool {
        guard case let .connected(scope) = event,
              transportGeneration == generation
        else { return false }
        let directOwner = connectionOperationKey.map {
            $0.transportGeneration == generation && $0.scope == scope
        } ?? false
        let reconnectOwner = brokerReconnectAttempt.map {
            $0.generation == generation
                && $0.peripheralID == scope.peripheralID
                && brokerReconnectScope == scope
        } ?? false
        return directOwner || reconnectOwner
    }

    private func canPresentUnownedConnectedEvent(
        scope: DeviceConnectionScope,
        generation: UInt
    ) -> Bool {
        guard transportGeneration == generation,
              !retiredConnectionScopeIDs.contains(scope.sessionID),
              activeConnectionScope == scope,
              selectedPeripheralID == scope.peripheralID
                || otaRecoveryPeripheralID == scope.peripheralID
        else { return false }
        return !ownerControlsConnectedPresentation(for: .connected(scope), generation: generation)
    }

    private func acceptsTransportEvent(_ event: DeviceEvent, generation: UInt) -> Bool {
        guard transportGeneration == generation else { return false }
        switch event {
        case let .reconnecting(scope):
            guard !retiredConnectionScopeIDs.contains(scope.sessionID),
                  activeConnectionScope == nil,
                  selectedPeripheralID == scope.peripheralID
                    || otaRecoveryPeripheralID == scope.peripheralID
            else { return activeConnectionScope == scope }
            activeConnectionScope = scope
        case let .connected(scope):
            guard authorizeInitialScope(scope) else { return false }
        case let .handshakeCompleted(snapshot, scope):
            guard snapshot.peripheralID == scope.peripheralID,
                  authorizeInitialScope(scope)
            else { return false }
        case let .disconnected(scope, _):
            guard activeConnectionScope == scope else { return false }
            retiredConnectionScopeIDs.insert(scope.sessionID)
            activeConnectionScope = nil
            if connectionOperationKey?.scope == scope { connectionOperationKey = nil }
            if brokerReconnectScope == scope { brokerReconnectScope = nil }
        case .discovered, .battery, .dc, .typeC, .transactionDepth:
            break
        }
        return true
    }

    private func retireActiveConnectionScope() {
        if let activeConnectionScope {
            retiredConnectionScopeIDs.insert(activeConnectionScope.sessionID)
        }
        activeConnectionScope = nil
    }

    private func authorizeInitialScope(_ scope: DeviceConnectionScope) -> Bool {
        if let activeConnectionScope { return activeConnectionScope == scope }
        guard !retiredConnectionScopeIDs.contains(scope.sessionID) else { return false }
        let hasDirectConnect = connectionOperationKey?.scope == scope
        let hasBrokerAttempt = brokerReconnectAttempt?.peripheralID == scope.peripheralID
            && brokerReconnectScope == scope
        let hasOTARecovery = otaRecoveryPeripheralID == scope.peripheralID
        guard hasDirectConnect || hasBrokerAttempt || hasOTARecovery else { return false }
        activeConnectionScope = scope
        return true
    }

    private func receive(
        _ event: DeviceEvent,
        generation: UInt,
        ownerControlsConnectedPresentation: Bool = false
    ) async {
        guard transportGeneration == generation else { return }
        switch event {
        case let .discovered(device):
            if let index = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
                discoveredDevices[index] = device
            } else {
                discoveredDevices.append(device)
            }
        case let .connected(scope):
            let id = scope.peripheralID
            if otaRecoveryPeripheralID == id {
                guard canPresentUnownedConnectedEvent(scope: scope, generation: generation) else { return }
                connectionStatus = .disconnected(nil)
                route = .scan
                return
            }
            guard !ownerControlsConnectedPresentation,
                  canPresentUnownedConnectedEvent(scope: scope, generation: generation)
            else { return }
            let brokerContext = prepareBrokerContext(peripheralID: id, generation: generation)
            await publishBrokerContext(brokerContext)
            guard canPresentUnownedConnectedEvent(scope: scope, generation: generation) else { return }
            await deviceOperationBroker.markConnected(peripheralID: id, generation: generation)
            guard canPresentUnownedConnectedEvent(scope: scope, generation: generation) else { return }
            establishConnectedPresentation(scope: scope)
        case let .reconnecting(scope):
            let id = scope.peripheralID
            selectedPeripheralID = id
            connectionStatus = .reconnecting
            route = .connected
        case let .disconnected(scope, failure):
            if let attempt = brokerReconnectAttempt,
               attempt.generation == generation,
               attempt.peripheralID == scope.peripheralID {
                await terminalizeBrokerReconnect(attempt, retireScope: false)
            }
            flushPendingTelemetryPersistence()
            connectionStatus = .disconnected(failure?.message)
            if otaRecoveryPeripheralID != nil {
                route = .scan
            } else if selectedPeripheralID != nil || isDemo {
                route = .connected
            }
        case let .handshakeCompleted(snapshot, _):
            let isOTAMode = snapshot.mode == .ota
            if activeTransportKind == .router {
                routerConnections.record(identity: snapshot)
            }
            if isOTAMode {
                capabilities = DeviceCapabilities(features: [])
            } else if let activeRouterEndpoints {
                capabilities = RouterConnectionModel.capabilities(
                    for: snapshot,
                    endpoints: activeRouterEndpoints
                )
            } else {
                capabilities = snapshot.capabilities
            }
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

    private func establishConnectedPresentation(scope: DeviceConnectionScope) {
        let id = scope.peripheralID
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
        if maintenanceState == .restarting,
           let restartDisconnectObserved,
           restartDisconnectObserved.generation == transportGeneration,
           restartDisconnectObserved.scope != scope {
            restartOperationID = nil
            restartTimeoutTask?.cancel()
            restartTimeoutTask = nil
            restartRecoveryTask?.cancel()
            restartRecoveryTask = nil
            maintenanceState = .idle
        }
        route = .connected
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

    #if DEBUG
    func waitForTelemetryPersistenceForTesting() async {
        let task = telemetryPersistenceTask
        await task?.value
    }
    #endif

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

    func applySessionState(_ nextState: DeviceState) {
        let newError = nextState.lastError
        let shouldToast = newError != nil && newError != state.lastError
        state = nextState
        if shouldToast, let newError { showToast(newError) }
        guard let snapshotCoordinator else { return }
        let generation = transportGeneration
        let identity = nextState.identity
        let capabilities = self.capabilities
        snapshotFlushTask?.cancel()
        snapshotFlushTask = Task { [weak self] in
            guard let self else { return }
            let fanOut = await snapshotCoordinator.receive(
                state: nextState,
                identity: identity,
                capabilities: capabilities,
                generation: generation
            )
            if let fanOut {
                self.sharedSnapshot = fanOut.snapshot
                self.widgetReloadAdapter?.apply(fanOut.decision)
                await self.lowBatteryNotificationCoordinator.receive(fanOut.snapshot)
                let preferences = self.persistence.systemSurfacePreferences
                await self.liveActivityCoordinator.consume(
                    fanOut.snapshot,
                    now: Date(),
                    preferences: LiveActivityPreferences(
                        chargingEnabled: preferences.liveActivityCharging,
                        dischargingEnabled: preferences.liveActivityDischarging
                    )
                )
            }
            // Yield once so same-turn battery/DC/Type-C callbacks coalesce in the coordinator.
            await Task.yield()
            guard fanOut != nil, !Task.isCancelled, self.transportGeneration == generation else { return }
            await snapshotCoordinator.flushPendingWrites()
        }
    }

    private func performPortMutation(_ command: DeviceCommand) {
        Task { [weak self] in
            do {
                guard let self else { return }
                _ = try await deviceOperationBroker.perform(command, generation: transportGeneration)
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

    private struct ConnectionOperationKey: Equatable {
        let transportGeneration: UInt
        let operationGeneration: UInt
        let peripheralID: UUID
        let scope: DeviceConnectionScope
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
