import Foundation
import Observation
import WattlineCore
import WattlineNetwork
import WattlineUI

@MainActor
@Observable
final class RouterAdministrationModel {
    typealias PairingExpirySleep = @MainActor @Sendable (Date) async throws -> Void
    typealias DevicePairingClientFactory = (RouterEndpoint) throws -> RouterDevicePairingClient

    enum AdminAccess: Equatable {
        case locked
        case verifying
        case unlocked
    }

    enum HistoryLoadState: Equatable {
        case neverLoaded
        case initialLoading
        case loaded
        case failed
        case refreshing
    }

    enum RulesLoadState: Equatable {
        case neverLoaded
        case initialLoading
        case loaded
        case failed
        case refreshing
        case stale
    }

    enum PairingDisplayState: Equatable {
        case unknown
        case loading
        case open
        case closed
        case expired
        case failed

        var canOpenPairing: Bool { self == .closed || self == .expired }
        var canRefresh: Bool { self == .unknown || self == .expired || self == .failed }
    }

    enum SettingsSaveOutcome: Equatable {
        case accepted
        case rejected
        case failed
        case stale
    }

    private(set) var host: RouterHostMetadata?
    private(set) var access: AdminAccess = .locked
    private(set) var adminError: String?
    private(set) var history: [RouterHistorySample] = []
    private(set) var historyFetchedAt: Date?
    private(set) var historyError: String?
    private(set) var historyLoadState: HistoryLoadState = .neverLoaded
    private(set) var rules: [RouterRuleDocument] = []
    private(set) var rulesFetchedAt: Date?
    private(set) var rulesError: String?
    private(set) var rulesLoadState: RulesLoadState = .neverLoaded
    private(set) var pairingStatus: RouterPairingMode?
    private(set) var pairingQRPNG: Data?
    private(set) var pairingError: String?
    private(set) var pairingDisplayState: PairingDisplayState = .unknown
    private(set) var isPairingQRLoading = false
    private(set) var tokens: [RouterTokenMetadata] = []
    private(set) var tokensError: String?
    private(set) var settings: RouterSettings?
    private(set) var settingsError: String?
    private(set) var settingsRestartRequired = false
    private(set) var isSettingsLoading = false
    private(set) var isSettingsSaving = false
    private(set) var validatedReplacement: RouterReplacementCandidate?
    private(set) var replacementValidationError: String?
    private(set) var isReplacementValidationRunning = false
    private(set) var tlsError: String?
    private(set) var tlsRestartRequired = false
    private(set) var isTLSRotationRunning = false
    private(set) var isTLSPromotionRunning = false
    private(set) var tlsPromotionRecoveryAvailable = false
    private(set) var devicePairingStatus: RouterDevicePairingStatus?
    private(set) var devicePairingError: String?
    private(set) var isDevicePairingRunning = false
    private(set) var advancedIdentity: RouterDeviceDTO?
    private(set) var advancedValues = RouterAdvancedValues()
    private(set) var advancedError: String?
    private(set) var isAdvancedLoading = false
    private(set) var isAdvancedMutationRunning = false

    private let connections: RouterConnectionModel
    private let adminClient: RouterAdministrationClient
    private let historyClientFactory: (RouterEndpoint) throws -> RouterHistoryClient
    private let endpointMigrationValidator: RouterEndpointMigrationValidator
    private let now: () -> Date
    private let advancedPostRefreshIsCancelled: @MainActor () -> Bool
    private let pairingExpirySleep: PairingExpirySleep
    private let devicePairingClientFactory: DevicePairingClientFactory?
    private let usesDemoServices: Bool
    private var demoState: RouterAdministrationDemo?
    private var sessionGeneration: UInt64 = 0
    private var adminOperationGeneration: UInt64 = 0
    private var historyRequestGeneration: UInt64 = 0
    private var rulesRequestGeneration: UInt64 = 0
    private var pairingSecretGeneration: UInt64 = 0
    private var pairingStatusRequestGeneration: UInt64 = 0
    private var pairingQRRequestGeneration: UInt64 = 0
    private var tokenRequestGeneration: UInt64 = 0
    private var settingsLoadGeneration: UInt64 = 0
    private var settingsSaveGeneration: UInt64 = 0
    private var replacementRequestGeneration: UInt64 = 0
    private var tlsRequestGeneration: UInt64 = 0
    private var devicePairingGeneration: UInt64 = 0
    private var advancedLoadGeneration: UInt64 = 0
    private var advancedMutationGeneration: UInt64 = 0
    private var unsupportedAdvancedSurfaces: Set<RouterAdvancedSurface> = []
    private var advancedServerGate: RouterAdvancedServerGate = .allowed
    private var devicePairingClient: RouterDevicePairingClient?
    private var pairingExpiryTask: Task<Void, Never>?

    var isDevicePairingBusy: Bool {
        isDevicePairingRunning
            || devicePairingStatus?.stage == .scanning
            || devicePairingStatus?.stage == .pairing
    }

    var advancedVisibility: RouterAdvancedVisibility {
        guard let settings else {
            return RouterAdvancedVisibility(
                surfaces: [],
                showsEnableAdvancedAffordance: false
            )
        }
        let rawFeatures = FeatureFlags(rawValue: advancedIdentity?.featuresRaw ?? 0)
        let operationFeatures = advancedIdentity?.features
        return RouterAdvancedVisibility.evaluate(RouterAdvancedVisibilityInput(
            adminVerified: access == .unlocked,
            advanced: settings.advanced,
            mode: advancedIdentity?.mode == "app" ? .application : .ota,
            hasRunningMode: operationFeatures?.runningMode == true,
            hasBarrierFree: operationFeatures?.barrierFree == true,
            hasUSBFirmware: operationFeatures?.usbFirmware == true,
            hasBLEPIN: operationFeatures?.blePIN == true,
            hasBypassControl: rawFeatures.contains(.dcBypassControl),
            currentTimeAvailable: advancedIdentity?.available.currentTime == true,
            dcAvailable: advancedIdentity?.available.dc == true,
            usbAvailable: advancedIdentity?.available.usbc == true,
            unsupported: unsupportedAdvancedSurfaces,
            serverGate: advancedServerGate
        ))
    }
    private var settingsRestartRequiredHosts: Set<UUID> = []
    private var validatedReplacementLease: ValidatedReplacementLease?

    private struct ValidatedReplacementLease {
        let proof: ValidatedRouterReplacement
        let source: RouterHostMetadata
        let candidate: RouterHostMetadata
        let draft: RouterSettingsDraft
        let draftPatch: RouterSettingsDraftPatch
        let networkPatch: RouterSettingsPatch
    }

    var replacementCandidates: [RouterHostMetadata] {
        connections.savedHosts
            .filter { $0.id != host?.id }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    init(
        connections: RouterConnectionModel,
        adminClient: RouterAdministrationClient,
        historyClientFactory: @escaping (RouterEndpoint) throws -> RouterHistoryClient,
        endpointMigrationValidator: RouterEndpointMigrationValidator,
        devicePairingClientFactory: DevicePairingClientFactory? = nil,
        now: @escaping () -> Date = { Date() },
        advancedPostRefreshIsCancelled: @escaping @MainActor () -> Bool = {
            Task.isCancelled
        },
        pairingExpirySleep: @escaping PairingExpirySleep = { deadline in
            let remaining = max(0, deadline.timeIntervalSinceNow)
            try await Task.sleep(for: .seconds(remaining))
        },
        demoState: RouterAdministrationDemo? = nil,
        usesDemoServices: Bool = false
    ) {
        self.connections = connections
        self.adminClient = adminClient
        self.historyClientFactory = historyClientFactory
        self.endpointMigrationValidator = endpointMigrationValidator
        self.devicePairingClientFactory = devicePairingClientFactory
        self.now = now
        self.advancedPostRefreshIsCancelled = advancedPostRefreshIsCancelled
        self.pairingExpirySleep = pairingExpirySleep
        self.demoState = demoState
        self.usesDemoServices = usesDemoServices
        if let demoState { publishDemo(demoState) }
    }

    static func production(
        connections: RouterConnectionModel,
        httpFactory: @escaping RouterAdministrationClient.HTTPFactory = {
            try HTTPClient(endpoint: $0)
        }
    ) -> RouterAdministrationModel {
        let credentials = connections.credentialStore
        return RouterAdministrationModel(
            connections: connections,
            adminClient: RouterAdministrationClient(
                credentials: credentials,
                httpFactory: httpFactory
            ),
            historyClientFactory: { endpoint in
                RouterHistoryClient(
                    httpClient: try httpFactory(endpoint),
                    credentials: credentials,
                    endpoint: endpoint
                )
            },
            endpointMigrationValidator: .production(
                hostStore: connections.hostStore,
                credentials: credentials
            ),
            devicePairingClientFactory: { endpoint in
                RouterDevicePairingClient(
                    endpoint: endpoint,
                    credentials: credentials,
                    http: try httpFactory(endpoint),
                    clock: SystemRouterConnectionClock()
                )
            }
        )
    }

    static func demo(
        credentials: any RouterCredentialBackend = RouterAdministrationDemoCredentialBackend(),
        hosts: any RouterHostKeyValueStore = RouterAdministrationDemoHostBackend(),
        now: Date = Date(timeIntervalSince1970: 1_721_260_800)
    ) -> RouterAdministrationModel {
        let connections = RouterConnectionModel.demo(credentials: credentials, hosts: hosts)
        return demo(connections: connections, now: now)
    }

    static func demo(
        connections: RouterConnectionModel,
        now: Date = Date(timeIntervalSince1970: 1_721_260_800)
    ) -> RouterAdministrationModel {
        let fixture = try? RouterAdministrationDemo.fixture(now: now)
        let unavailable: @Sendable (RouterEndpoint) throws -> any RouterHTTPClient = { _ in
            throw RouterAdministrationDemoError.externalAccess
        }
        return RouterAdministrationModel(
            connections: connections,
            adminClient: RouterAdministrationClient(
                credentials: connections.credentialStore,
                httpFactory: unavailable
            ),
            historyClientFactory: { _ in
                throw RouterAdministrationDemoError.externalAccess
            },
            endpointMigrationValidator: RouterEndpointMigrationValidator(
                hostStore: connections.hostStore,
                credentials: connections.credentialStore,
                httpFactory: unavailable
            ),
            now: { now },
            demoState: fixture,
            usesDemoServices: true
        )
    }

    func begin(host: RouterHostMetadata) async {
        if usesDemoServices {
            if let demoState { publishDemo(demoState) }
            return
        }
        _ = await beginSession(host: host)
    }

    func open(host: RouterHostMetadata) async {
        if usesDemoServices {
            if let demoState { publishDemo(demoState) }
            return
        }
        let generation = await beginSession(host: host)
        guard !Task.isCancelled, sessionGeneration == generation else { return }
        await reloadHistory()
    }

    private func beginSession(host: RouterHostMetadata) async -> UInt64 {
        sessionGeneration &+= 1
        devicePairingGeneration &+= 1
        if let devicePairingClient { await devicePairingClient.cancel() }
        devicePairingClient = nil
        devicePairingStatus = nil
        devicePairingError = nil
        isDevicePairingRunning = false
        adminOperationGeneration &+= 1
        let session = sessionGeneration
        let adminOperation = adminOperationGeneration
        clearPairingSecrets()
        pairingError = nil
        self.host = host
        access = .locked
        adminError = nil
        history = []
        historyFetchedAt = nil
        historyError = nil
        historyLoadState = .neverLoaded
        clearRulesState()
        tokenRequestGeneration &+= 1
        tokens = []
        tokensError = nil
        clearSettingsState()
        if let devicePairingClientFactory {
            do {
                devicePairingClient = try devicePairingClientFactory(host.endpoint)
            } catch {
                devicePairingError = "Could not prepare Link-Power pairing."
            }
        }
        do {
            try await adminClient.attach(endpoint: host.endpoint)
        } catch {
            guard sessionGeneration == session,
                  adminOperationGeneration == adminOperation
            else { return session }
            adminError = "Could not prepare a connection to this router."
            return session
        }
        guard sessionGeneration == session,
              adminOperationGeneration == adminOperation
        else { return session }
        access = .verifying
        do {
            try await adminClient.verifyStoredAdministrator()
            guard sessionGeneration == session,
                  adminOperationGeneration == adminOperation
            else { return session }
            publishVerifiedAdministrationBoundary(for: host)
        } catch {
            guard sessionGeneration == session,
                  adminOperationGeneration == adminOperation
            else { return session }
            access = .locked
        }
        return session
    }

    func end() async {
        if usesDemoServices {
            clearPairingSecrets()
            return
        }
        sessionGeneration &+= 1
        devicePairingGeneration &+= 1
        if let devicePairingClient { await devicePairingClient.cancel() }
        devicePairingClient = nil
        devicePairingStatus = nil
        devicePairingError = nil
        isDevicePairingRunning = false
        adminOperationGeneration &+= 1
        host = nil
        access = .locked
        adminError = nil
        history = []
        historyFetchedAt = nil
        historyError = nil
        historyLoadState = .neverLoaded
        clearRulesState()
        tokenRequestGeneration &+= 1
        tokens = []
        tokensError = nil
        clearSettingsState()
        clearPairingSecrets()
        pairingError = nil
        await adminClient.detach()
    }

    func refreshDevicePairing() async {
        guard !usesDemoServices else { return }
        await performDevicePairing { client, _ in try await client.status() }
    }

    func scanForLinkPower() async {
        guard !usesDemoServices else { return }
        await performDevicePairing { client, progress in
            try await client.scan(progress: progress)
        }
    }

    func pairLinkPower(mac: String, pin: String) async {
        if var demoState {
            demoState.devicePairingStatus = RouterDevicePairingStatus(
                stage: .paired,
                target: mac,
                devices: demoState.devicePairingStatus.devices.map {
                    RouterPairableDevice(
                        mac: $0.mac,
                        name: $0.name,
                        rssi: $0.rssi,
                        paired: $0.mac == mac || $0.paired
                    )
                },
                error: nil
            )
            self.demoState = demoState
            devicePairingStatus = demoState.devicePairingStatus
            return
        }
        guard !usesDemoServices else { return }
        // Deliberately capture no PIN in model state; the view clears its local
        // secure entry before this asynchronous dispatch.
        await performDevicePairing { client, progress in
            try await client.pair(mac: mac, pin: pin, progress: progress)
        }
    }

    func unpairLinkPower(mac: String) async {
        if var demoState {
            demoState.devicePairingStatus = RouterDevicePairingStatus(
                stage: .idle,
                target: nil,
                devices: demoState.devicePairingStatus.devices.map {
                    RouterPairableDevice(
                        mac: $0.mac,
                        name: $0.name,
                        rssi: $0.rssi,
                        paired: $0.mac == mac ? false : $0.paired
                    )
                },
                error: nil
            )
            self.demoState = demoState
            devicePairingStatus = demoState.devicePairingStatus
            return
        }
        guard !usesDemoServices else { return }
        await performDevicePairing { client, progress in
            try await client.unpair(mac: mac, progress: progress)
        }
    }

    @discardableResult
    func reloadAdvanced() async -> Bool {
        if let demoState {
            advancedIdentity = demoState.identity
            advancedValues = demoState.advancedValues
            return true
        }
        guard !usesDemoServices else { return false }
        guard host != nil, access == .unlocked else { return false }
        advancedLoadGeneration &+= 1
        let request = advancedLoadGeneration
        let session = sessionGeneration
        let adminOperation = adminOperationGeneration
        isAdvancedLoading = true
        advancedError = nil
        let result: AdvancedResult<(RouterSettings, RouterDeviceDTO)> = await performAdvanced {
            let settings = try await $0.settings()
            let identity = try await $0.advancedIdentity()
            return (settings, identity)
        }
        guard isCurrentAdvancedLoad(
            session: session,
            adminOperation: adminOperation,
            request: request
        ) else { return false }
        isAdvancedLoading = false
        switch result {
        case let .success((authoritativeSettings, identity)):
            settings = authoritativeSettings
            advancedServerGate = .allowed
            if authoritativeSettings.advanced {
                advancedIdentity = identity
            } else {
                clearAdvancedState()
            }
            return true
        case .advancedDisabled:
            advancedServerGate = .advancedDisabled
            clearAdvancedValues()
        case .capabilityUnsupported, .failure:
            advancedError = "Could not load advanced device controls."
        case .stale:
            break
        }
        return false
    }

    func loadAdvancedBypassThreshold() async {
        guard !usesDemoServices else { return }
        await performAdvancedSurface(.bypassThreshold) { try await $0.bypassThreshold() } publish: {
            self.publishAdvancedValue(.bypassThreshold($0.volts))
        }
    }

    func setAdvancedBypassThreshold(volts: Double) async {
        if var demoState {
            demoState.advancedValues = RouterAdvancedValues(
                bypassThresholdVolts: volts,
                clock: demoState.advancedValues.clock,
                runningMode: demoState.advancedValues.runningMode,
                barrierFreeEnabled: demoState.advancedValues.barrierFreeEnabled,
                usbFirmware: demoState.advancedValues.usbFirmware,
                blePINUpdated: demoState.advancedValues.blePINUpdated
            )
            self.demoState = demoState
            advancedValues = demoState.advancedValues
            return
        }
        guard !usesDemoServices else { return }
        await performAdvancedSurface(.bypassThreshold) {
            try await $0.setBypassThreshold(volts: volts)
        } publish: {
            self.publishAdvancedValue(.bypassThreshold($0.volts))
        }
    }

    func loadAdvancedClock() async {
        guard !usesDemoServices else { return }
        await performAdvancedSurface(.clock) { try await $0.deviceClock() } publish: {
            self.publishAdvancedValue(.clock(Self.clockValue($0)))
        }
    }

    func syncAdvancedClock() async {
        if var demoState {
            demoState.advancedValues = RouterAdvancedValues(
                bypassThresholdVolts: demoState.advancedValues.bypassThresholdVolts,
                clock: RouterAdvancedClockValue(
                    available: true,
                    deviceTime: ISO8601DateFormatter().string(from: now()),
                    systemTime: ISO8601DateFormatter().string(from: now()),
                    driftSeconds: 0
                ),
                runningMode: demoState.advancedValues.runningMode,
                barrierFreeEnabled: demoState.advancedValues.barrierFreeEnabled,
                usbFirmware: demoState.advancedValues.usbFirmware,
                blePINUpdated: demoState.advancedValues.blePINUpdated
            )
            self.demoState = demoState
            advancedValues = demoState.advancedValues
            return
        }
        guard !usesDemoServices else { return }
        await performAdvancedSurface(.clock) { client in
            _ = try await client.syncDeviceClock()
            return try await client.deviceClock()
        } publish: {
            self.publishAdvancedValue(.clock(Self.clockValue($0)))
        }
    }

    func setAdvancedRunningMode(
        _ mode: UInt8,
        confirmation: RouterAdvancedConfirmation?
    ) async {
        guard confirmation == .runningMode else { return }
        if var demoState {
            demoState.advancedValues = RouterAdvancedValues(
                bypassThresholdVolts: demoState.advancedValues.bypassThresholdVolts,
                clock: demoState.advancedValues.clock,
                runningMode: mode,
                barrierFreeEnabled: demoState.advancedValues.barrierFreeEnabled,
                usbFirmware: demoState.advancedValues.usbFirmware,
                blePINUpdated: demoState.advancedValues.blePINUpdated
            )
            self.demoState = demoState
            advancedValues = demoState.advancedValues
            return
        }
        guard !usesDemoServices else { return }
        await performAdvancedSurface(.runningMode) { try await $0.setRunningMode(mode) } publish: {
            self.publishAdvancedValue(.runningMode($0.mode))
        }
    }

    func loadAdvancedBarrierFree() async {
        guard !usesDemoServices else { return }
        await performAdvancedSurface(.barrierFree) { try await $0.barrierFree() } publish: {
            self.publishAdvancedValue(.barrierFree($0.enabled))
        }
    }

    func setAdvancedBarrierFree(_ enabled: Bool) async {
        if var demoState {
            demoState.advancedValues = RouterAdvancedValues(
                bypassThresholdVolts: demoState.advancedValues.bypassThresholdVolts,
                clock: demoState.advancedValues.clock,
                runningMode: demoState.advancedValues.runningMode,
                barrierFreeEnabled: enabled,
                usbFirmware: demoState.advancedValues.usbFirmware,
                blePINUpdated: demoState.advancedValues.blePINUpdated
            )
            self.demoState = demoState
            advancedValues = demoState.advancedValues
            return
        }
        guard !usesDemoServices else { return }
        await performAdvancedSurface(.barrierFree) {
            try await $0.setBarrierFree(enabled)
        } publish: {
            self.publishAdvancedValue(.barrierFree($0.enabled))
        }
    }

    func loadAdvancedUSBFirmware() async {
        guard !usesDemoServices else { return }
        await performAdvancedSurface(.usbFirmware) { try await $0.usbFirmwareVersion() } publish: {
            self.publishAdvancedValue(.usbFirmware(RouterAdvancedUSBFirmwareValue(
                raw: $0.raw,
                major: $0.major,
                minor: $0.minor,
                patch: $0.patch
            )))
        }
    }

    func setAdvancedBLEPIN(
        _ pin: String,
        confirmation: RouterAdvancedConfirmation?
    ) async {
        guard confirmation == .blePIN else { return }
        if var demoState {
            demoState.advancedValues = RouterAdvancedValues(
                bypassThresholdVolts: demoState.advancedValues.bypassThresholdVolts,
                clock: demoState.advancedValues.clock,
                runningMode: demoState.advancedValues.runningMode,
                barrierFreeEnabled: demoState.advancedValues.barrierFreeEnabled,
                usbFirmware: demoState.advancedValues.usbFirmware,
                blePINUpdated: true
            )
            self.demoState = demoState
            advancedValues = demoState.advancedValues
            return
        }
        guard !usesDemoServices else { return }
        // The secret is captured only by this call and is never assigned to model state.
        await performAdvancedSurface(.blePIN) { try await $0.setBLEPIN(pin) } publish: {
            self.publishAdvancedValue(.blePINUpdated($0.updated))
        }
    }

    func reloadHistory() async {
        guard !usesDemoServices else { return }
        guard let host else { return }
        let generation = sessionGeneration
        historyRequestGeneration &+= 1
        let requestGeneration = historyRequestGeneration
        historyError = nil
        historyLoadState = historyFetchedAt == nil ? .initialLoading : .refreshing
        do {
            let client = try historyClientFactory(host.endpoint)
            let samples = try await client.fetch()
            guard sessionGeneration == generation,
                  historyRequestGeneration == requestGeneration
            else { return }
            history = samples
            historyFetchedAt = now()
            historyError = nil
            historyLoadState = .loaded
        } catch {
            guard sessionGeneration == generation,
                  historyRequestGeneration == requestGeneration
            else { return }
            historyError = "Could not load router history."
            historyLoadState = .failed
        }
    }

    func reloadRules() async {
        guard !usesDemoServices else { return }
        guard host != nil else { return }
        rulesRequestGeneration &+= 1
        let request = rulesRequestGeneration
        let session = sessionGeneration
        rulesError = nil
        rulesLoadState = rulesFetchedAt == nil ? .initialLoading : .refreshing
        do {
            let authoritativeRules = try await adminClient.rules()
            guard !Task.isCancelled,
                  sessionGeneration == session,
                  rulesRequestGeneration == request
            else { return }
            publishRules(authoritativeRules)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  sessionGeneration == session,
                  rulesRequestGeneration == request
            else { return }
            rulesError = "Could not load automation rules. Try again."
            rulesLoadState = rulesFetchedAt == nil ? .failed : .stale
        }
    }

    func createRule(
        _ rule: RouterRule,
        confirmation: RouterRuleConfirmation?
    ) async {
        if var demoState {
            guard rule.name != RouterPowerLossPreset.reservedName,
                  ruleConfirmationAllowsMutation(rule, confirmation: confirmation),
                  !demoState.rules.contains(where: { Self.ruleName($0) == rule.name })
            else { return }
            demoState.rules.append(.known(rule))
            self.demoState = demoState
            publishRules(demoState.rules)
            return
        }
        guard !usesDemoServices else { return }
        guard rule.name != RouterPowerLossPreset.reservedName,
              ruleConfirmationAllowsMutation(rule, confirmation: confirmation),
              !rules.contains(where: { Self.ruleName($0) == rule.name })
        else { return }
        await mutateRules { try await $0.createRule(rule) }
    }

    func updateRule(
        named name: String,
        rule: RouterRule,
        confirmation: RouterRuleConfirmation?
    ) async {
        if var demoState {
            guard rule.name == name,
                  name != RouterPowerLossPreset.reservedName,
                  ruleConfirmationAllowsMutation(rule, confirmation: confirmation),
                  let index = demoState.rules.firstIndex(where: { Self.ruleName($0) == name }),
                  case .known = demoState.rules[index]
            else { return }
            demoState.rules[index] = .known(rule)
            self.demoState = demoState
            publishRules(demoState.rules)
            return
        }
        guard !usesDemoServices else { return }
        guard rule.name == name,
              name != RouterPowerLossPreset.reservedName,
              rule.name != RouterPowerLossPreset.reservedName,
              rules.contains(where: {
            guard Self.ruleName($0) == name, case .known = $0 else { return false }
            return true
        }),
        !rules.contains(where: {
            let existingName = Self.ruleName($0)
            return existingName == rule.name && existingName != name
        }),
        ruleConfirmationAllowsMutation(rule, confirmation: confirmation)
        else { return }
        await mutateRules { try await $0.updateRule(named: name, rule: rule) }
    }

    func deleteRule(named name: String) async {
        if var demoState {
            guard name != RouterPowerLossPreset.reservedName,
                  let index = demoState.rules.firstIndex(where: { Self.ruleName($0) == name }),
                  case .known = demoState.rules[index]
            else { return }
            demoState.rules.remove(at: index)
            self.demoState = demoState
            publishRules(demoState.rules)
            return
        }
        guard !usesDemoServices else { return }
        guard name != RouterPowerLossPreset.reservedName,
              rules.contains(where: {
            guard Self.ruleName($0) == name, case .known = $0 else { return false }
            return true
        }) else { return }
        await mutateRules { try await $0.deleteRule(named: name) }
    }

    func savePowerLossPreset(
        enabled: Bool,
        hold: RouterRuleDuration,
        confirmShutdown: Bool,
        confirmation: RouterRuleConfirmation?
    ) async {
        guard host != nil, access == .unlocked else { return }
        let document = rules.first {
            Self.ruleName($0) == RouterPowerLossPreset.reservedName
        }
        let preset = RouterPowerLossPreset(document: document)
        do {
            if var demoState {
                let updated: RouterRule
                if preset.isCompatible {
                    guard confirmation == .shutdown else { return }
                    updated = try preset.updating(
                        enabled: enabled,
                        hold: hold,
                        confirmShutdown: confirmShutdown
                    )
                } else {
                    guard confirmation == .resetPowerLossPreset else { return }
                    updated = try preset.reset(
                        enabled: enabled,
                        hold: hold,
                        confirmed: true
                    )
                }
                demoState.rules.removeAll {
                    Self.ruleName($0) == RouterPowerLossPreset.reservedName
                }
                demoState.rules.insert(.known(updated), at: 0)
                self.demoState = demoState
                publishRules(demoState.rules)
                return
            }
            guard !usesDemoServices else { return }
            if preset.isCompatible {
                guard confirmation == .shutdown else { return }
                let updated = try preset.updating(
                    enabled: enabled,
                    hold: hold,
                    confirmShutdown: confirmShutdown
                )
                await mutateRules {
                    try await $0.updateRule(
                        named: RouterPowerLossPreset.reservedName,
                        rule: updated
                    )
                }
            } else {
                guard confirmation == .resetPowerLossPreset else { return }
                let reset = try preset.reset(
                    enabled: enabled,
                    hold: hold,
                    confirmed: true
                )
                if document == nil {
                    await mutateRules { try await $0.createRule(reset) }
                } else {
                    await mutateRules {
                        try await $0.updateRule(
                            named: RouterPowerLossPreset.reservedName,
                            rule: reset
                        )
                    }
                }
            }
        } catch {
            rulesError = "The rule could not be saved."
        }
    }

    func unlock(token: String) async {
        if usesDemoServices {
            access = .unlocked
            adminError = nil
            return
        }
        guard let host,
              access != .verifying,
              !isTLSRotationRunning,
              !isTLSPromotionRunning
        else { return }
        adminOperationGeneration &+= 1
        let session = sessionGeneration
        let adminOperation = adminOperationGeneration
        clearPairingSecrets()
        access = .verifying
        adminError = nil
        do {
            try await adminClient.verifyAdministrator(token: token)
            guard sessionGeneration == session,
                  adminOperationGeneration == adminOperation
            else { return }
            publishVerifiedAdministrationBoundary(for: host)
        } catch is CancellationError {
            guard sessionGeneration == session,
                  adminOperationGeneration == adminOperation
            else { return }
            access = .locked
            clearPairingSecrets()
            clearSettingsState()
        } catch {
            guard sessionGeneration == session,
                  adminOperationGeneration == adminOperation
            else { return }
            access = .locked
            clearPairingSecrets()
            clearSettingsState()
            adminError = Self.unlockMessage(for: error)
        }
    }

    func lock() async {
        if usesDemoServices {
            access = .locked
            return
        }
        guard host != nil,
              !isTLSRotationRunning,
              !isTLSPromotionRunning
        else { return }
        adminOperationGeneration &+= 1
        access = .locked
        adminError = nil
        clearPairingSecrets()
        clearSettingsState()
        try? await adminClient.clearAdministratorCredential()
    }

    func reloadSettings() async {
        guard !usesDemoServices else { return }
        settingsLoadGeneration &+= 1
        let request = settingsLoadGeneration
        isSettingsLoading = true
        settingsError = nil
        let result = await performAdmin({ client in
            try await client.settings()
        }, isCurrent: { [weak self] in
            self?.settingsLoadGeneration == request
        })
        guard settingsLoadGeneration == request else { return }
        isSettingsLoading = false
        switch result {
        case let .success(value):
            settings = value
            settingsError = nil
            if !value.advanced {
                clearAdvancedState()
            }
            invalidateReplacementValidation()
        case let .failure(message):
            settingsError = message
        case .stale:
            break
        }
    }

    @discardableResult
    func saveSettings(
        _ patch: RouterSettingsPatch,
        draft: RouterSettingsDraft? = nil,
        draftPatch: RouterSettingsDraftPatch? = nil,
        replacement: RouterHostMetadata? = nil,
        requiresValidatedReplacement: Bool = false
    ) async -> SettingsSaveOutcome {
        if var demoState {
            guard access == .unlocked, !isSettingsSaving else { return .stale }
            do {
                demoState.settings = try RouterAdministrationDemo.applying(
                    patch,
                    to: demoState.settings
                )
                self.demoState = demoState
                settings = demoState.settings
                settingsError = nil
                settingsRestartRequired = false
                invalidateReplacementValidation()
                return .accepted
            } catch {
                settingsError = "The demo configuration could not be updated."
                return .failed
            }
        }
        guard !usesDemoServices else { return .stale }
        guard let source = host,
              access == .unlocked,
              !isSettingsSaving
        else { return .stale }
        let session = sessionGeneration
        let adminOperation = adminOperationGeneration
        settingsSaveGeneration &+= 1
        let request = settingsSaveGeneration
        settingsLoadGeneration &+= 1
        isSettingsLoading = false
        isSettingsSaving = true
        settingsError = nil
        defer {
            if settingsSaveGeneration == request {
                isSettingsSaving = false
            }
        }

        let replacementLease: ValidatedReplacementLease?
        if requiresValidatedReplacement {
            guard let draft,
                  let draftPatch,
                  let replacement,
                  let lease = validatedReplacementLease,
                  lease.source == source,
                  lease.candidate == replacement,
                  lease.draft == draft,
                  lease.draftPatch == draftPatch,
                  lease.networkPatch == patch,
                  connections.savedHosts.contains(replacement)
            else {
                isSettingsSaving = false
                settingsError = "Verify this exact replacement endpoint and configuration again."
                invalidateReplacementValidation()
                return .rejected
            }
            replacementLease = lease
        } else {
            replacementLease = nil
        }

        invalidateReplacementValidation()
        let replacementConsumptionGeneration = replacementRequestGeneration
        if let replacementLease {
            do {
                let value = try await endpointMigrationValidator.updateSettings(
                    patch,
                    using: adminClient,
                    validation: replacementLease.proof,
                    source: source,
                    candidate: replacementLease.candidate,
                    expectedDeviceID: source.deviceID ?? "",
                    isCurrent: { [weak self] in
                        guard let self else { return false }
                        return self.sessionGeneration == session
                            && self.adminOperationGeneration == adminOperation
                            && self.settingsSaveGeneration == request
                            && self.replacementRequestGeneration
                                == replacementConsumptionGeneration
                            && self.host == source
                            && self.access == .unlocked
                    }
                )
                guard sessionGeneration == session,
                      adminOperationGeneration == adminOperation,
                      settingsSaveGeneration == request,
                      replacementRequestGeneration == replacementConsumptionGeneration,
                      host == source,
                      access == .unlocked
                else { return .stale }
                publishSettingsSave(value, source: source)
                return .accepted
            } catch is CancellationError {
                return .stale
            } catch RouterEndpointMigrationError.candidateChanged {
                guard sessionGeneration == session,
                      adminOperationGeneration == adminOperation,
                      settingsSaveGeneration == request,
                      replacementRequestGeneration == replacementConsumptionGeneration,
                      host == source,
                      access == .unlocked
                else { return .stale }
                settingsError = "Verify this exact replacement endpoint and configuration again."
                invalidateReplacementValidation()
                return .rejected
            } catch {
                guard sessionGeneration == session,
                      adminOperationGeneration == adminOperation,
                      settingsSaveGeneration == request,
                      replacementRequestGeneration == replacementConsumptionGeneration,
                      host == source,
                      access == .unlocked
                else { return .stale }
                if handleAdminFailure(error) {
                    try? await adminClient.clearAdministratorCredential()
                    return .stale
                }
                settingsError = "The request failed. Try again."
                return .failed
            }
        }

        let result = await performAdmin({ client in
            try await client.updateSettings(patch)
        }, isCurrent: { [weak self] in
            self?.settingsSaveGeneration == request
        })
        guard settingsSaveGeneration == request else { return .stale }
        switch result {
        case let .success(value):
            publishSettingsSave(value, source: source)
            return .accepted
        case let .failure(message):
            settingsError = message
            return .failed
        case .stale:
            return .stale
        }
    }

    func rotateTLS() async {
        if usesDemoServices {
            guard host?.scheme == "https", access == .unlocked else { return }
            tlsError = nil
            tlsRestartRequired = true
            return
        }
        guard let source = host,
              source.scheme == "https",
              source.certificateFingerprint != nil,
              access == .unlocked,
              !isTLSRotationRunning,
              !isTLSPromotionRunning
        else { return }
        tlsRequestGeneration &+= 1
        let request = tlsRequestGeneration
        let session = sessionGeneration
        let adminOperation = adminOperationGeneration
        isTLSRotationRunning = true
        tlsError = nil
        do {
            let response = try await adminClient.rotateTLS()
            let staged = try await connections.stageTLSCertificateFingerprint(
                response.sha256,
                for: source
            )
            guard isCurrentTLSOperation(
                source: source,
                session: session,
                adminOperation: adminOperation,
                request: request
            ) else { return }
            host = staged
            invalidateReplacementValidation()
            tlsRestartRequired = response.restartRequired
            isTLSRotationRunning = false
        } catch is CancellationError {
            guard isCurrentTLSOperation(
                source: source,
                session: session,
                adminOperation: adminOperation,
                request: request
            ) else { return }
            isTLSRotationRunning = false
        } catch {
            guard isCurrentTLSOperation(
                source: source,
                session: session,
                adminOperation: adminOperation,
                request: request
            ) else { return }
            isTLSRotationRunning = false
            if handleAdminFailure(error) {
                try? await adminClient.clearAdministratorCredential()
            } else {
                tlsError = "The certificate rotation failed. Try again."
            }
        }
    }

    func promoteStagedTLSPin(administratorToken: String? = nil) async {
        if usesDemoServices {
            tlsError = nil
            tlsRestartRequired = false
            tlsPromotionRecoveryAvailable = false
            return
        }
        guard let source = host,
              source.scheme == "https",
              source.stagedCertificateFingerprint != nil,
              access != .verifying,
              !isTLSRotationRunning,
              !isTLSPromotionRunning
        else { return }
        let operationAccess = access
        tlsRequestGeneration &+= 1
        let request = tlsRequestGeneration
        let session = sessionGeneration
        let adminOperation = adminOperationGeneration
        isTLSPromotionRunning = true
        tlsError = nil
        tlsPromotionRecoveryAvailable = false
        do {
            let promoted: RouterHostMetadata
            if let administratorToken {
                promoted = try await connections.promoteStagedTLSPin(
                    for: source.id,
                    administratorToken: administratorToken
                )
            } else {
                promoted = try await connections.promoteStagedTLSPin(for: source.id)
            }
            guard isCurrentTLSOperation(
                source: source,
                session: session,
                adminOperation: adminOperation,
                request: request,
                expectedAccess: operationAccess
            ) else { return }
            do {
                try await adminClient.attach(endpoint: promoted.endpoint)
            } catch {
                guard isCurrentTLSOperation(
                    source: source,
                    session: session,
                    adminOperation: adminOperation,
                    request: request,
                    expectedAccess: operationAccess
                ) else { return }
                host = promoted
                invalidateReplacementValidation()
                access = .locked
                tlsRestartRequired = false
                isTLSPromotionRunning = false
                tlsPromotionRecoveryAvailable = false
                settingsRestartRequiredHosts.remove(source.id)
                settingsRestartRequired = false
                tlsError = "The pin was promoted, but administration must be reopened."
                return
            }
            guard isCurrentTLSOperation(
                source: source,
                session: session,
                adminOperation: adminOperation,
                request: request,
                expectedAccess: operationAccess
            ) else { return }
            host = promoted
            invalidateReplacementValidation()
            tlsRestartRequired = false
            isTLSPromotionRunning = false
            tlsPromotionRecoveryAvailable = false
            settingsRestartRequiredHosts.remove(source.id)
            settingsRestartRequired = false
        } catch {
            guard isCurrentTLSOperation(
                source: source,
                session: session,
                adminOperation: adminOperation,
                request: request,
                expectedAccess: operationAccess
            ) else { return }
            isTLSPromotionRunning = false
            if administratorToken != nil {
                tlsPromotionRecoveryAvailable = true
                tlsError = "The administrator token could not verify the new certificate."
            } else if Self.offersTransientTLSRecovery(error) {
                tlsPromotionRecoveryAvailable = true
                tlsError = "Enter an administrator token to verify the new certificate."
            } else {
                tlsError = "The new certificate could not be verified."
            }
        }
    }

    func validateReplacement(
        _ candidate: RouterHostMetadata,
        draft: RouterSettingsDraft,
        draftPatch: RouterSettingsDraftPatch,
        patch: RouterSettingsPatch
    ) async {
        if usesDemoServices {
            invalidateReplacementValidation()
            replacementValidationError = "Demo mode does not migrate real router endpoints."
            return
        }
        guard let source = host,
              access == .unlocked,
              let expectedDeviceID = source.deviceID,
              connections.savedHosts.contains(candidate),
              replacementCandidates.contains(candidate)
        else {
            invalidateReplacementValidation()
            replacementValidationError = "Select a known router endpoint."
            return
        }
        replacementRequestGeneration &+= 1
        let request = replacementRequestGeneration
        let session = sessionGeneration
        validatedReplacement = nil
        validatedReplacementLease = nil
        replacementValidationError = nil
        isReplacementValidationRunning = true
        defer {
            if replacementRequestGeneration == request {
                isReplacementValidationRunning = false
            }
        }
        do {
            let validated = try await endpointMigrationValidator.validate(
                candidate: candidate,
                expectedDeviceID: expectedDeviceID
            )
            guard sessionGeneration == session,
                  replacementRequestGeneration == request,
                  host == source,
                  access == .unlocked
            else { return }
            guard connections.savedHosts.contains(candidate) else {
                validatedReplacement = nil
                validatedReplacementLease = nil
                replacementValidationError = "Save and verify this replacement endpoint again."
                return
            }
            validatedReplacement = RouterReplacementCandidate(
                scheme: validated.endpoint.scheme,
                host: validated.endpoint.host,
                port: validated.endpoint.port,
                certificateFingerprint: validated.endpoint.certificateFingerprint,
                reachability: Self.routeReachability(candidate.reachability),
                isSaved: true,
                hasClientCredential: true,
                validation: .verified(deviceID: validated.deviceID),
                validatedPatch: draftPatch
            )
            validatedReplacementLease = ValidatedReplacementLease(
                proof: validated,
                source: source,
                candidate: candidate,
                draft: draft,
                draftPatch: draftPatch,
                networkPatch: patch
            )
            replacementValidationError = nil
        } catch {
            guard sessionGeneration == session,
                  replacementRequestGeneration == request,
                  host == source,
                  access == .unlocked
            else { return }
            validatedReplacement = nil
            validatedReplacementLease = nil
            replacementValidationError = "Could not verify this replacement endpoint."
        }
    }

    func invalidateReplacementValidation() {
        replacementRequestGeneration &+= 1
        validatedReplacement = nil
        validatedReplacementLease = nil
        replacementValidationError = nil
        isReplacementValidationRunning = false
    }

    func reloadTokens() async {
        guard !usesDemoServices else { return }
        guard host != nil, access == .unlocked else { return }
        tokenRequestGeneration &+= 1
        let requestGeneration = tokenRequestGeneration
        tokensError = nil
        let result = await performAdmin({ client in
            try await client.tokens()
        }, isCurrent: { [weak self] in
            self?.tokenRequestGeneration == requestGeneration
        })
        guard tokenRequestGeneration == requestGeneration else { return }
        publishTokenResult(result)
    }

    func isCurrentClient(_ token: RouterTokenMetadata) -> Bool {
        guard let currentID = host?.tokenID else { return false }
        return currentID == token.id
    }

    func revoke(_ token: RouterTokenMetadata) async {
        if var demoState {
            guard !token.bootstrap else { return }
            demoState.tokens.removeAll { $0.id == token.id }
            self.demoState = demoState
            tokens = demoState.tokens
            return
        }
        guard !usesDemoServices else { return }
        guard !token.bootstrap, host != nil, access == .unlocked else { return }
        let wasCurrentClient = isCurrentClient(token)
        let revokedHost = host
        let session = sessionGeneration
        let adminOperation = adminOperationGeneration
        tokenRequestGeneration &+= 1
        let requestGeneration = tokenRequestGeneration
        tokensError = nil
        let adminAttachment: RouterAdministrationAttachmentLease
        do {
            adminAttachment = try await adminClient.attachmentLease()
        } catch {
            guard isCurrentTokenOperation(
                session: session,
                adminOperation: adminOperation,
                request: requestGeneration
            ) else { return }
            tokensError = "The request failed. Try again."
            return
        }
        let revokedClientLease: RouterCredentialLease?
        if wasCurrentClient, let revokedHost {
            do {
                revokedClientLease = try await connections.clientCredentialLease(
                    for: revokedHost
                )
            } catch {
                guard isCurrentTokenOperation(
                    session: session,
                    adminOperation: adminOperation,
                    request: requestGeneration
                ) else { return }
                tokensError = "The request failed. Try again."
                return
            }
        } else {
            revokedClientLease = nil
        }
        guard isCurrentAdminEndpoint(
            session: session,
            adminOperation: adminOperation,
            endpoint: revokedHost?.endpoint
        ) else { return }
        let authoritativeList: [RouterTokenMetadata]?
        let readbackFailure: RouterTokenRevocationReadbackError.Cause?
        do {
            authoritativeList = try await adminClient.revokeTokenAndReload(
                id: token.id,
                attachment: adminAttachment
            )
            readbackFailure = nil
        } catch let error as RouterTokenRevocationReadbackError {
            // The actor validated the DELETE before attempting the failed
            // authoritative readback, so conditional local cleanup must still
            // run even when this presentation operation is now stale.
            authoritativeList = nil
            readbackFailure = error.cause
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentTokenOperation(
                session: session,
                adminOperation: adminOperation,
                request: requestGeneration
            ) else { return }
            if handleAdminFailure(error) {
                try? await adminClient.clearAdministratorCredential()
            } else {
                tokensError = "The request failed. Try again."
            }
            return
        }

        var clientCleanupFailed = false
        if let revokedHost, let revokedClientLease {
            do {
                try await connections.returnToEnrollment(
                    revokedHost,
                    ifCurrent: revokedClientLease
                )
            } catch {
                clientCleanupFailed = true
            }
        }

        guard isCurrentAdminEndpoint(
            session: session,
            adminOperation: adminOperation,
            endpoint: revokedHost?.endpoint
        ) else { return }

        guard isCurrentTokenOperation(
            session: session,
            adminOperation: adminOperation,
            request: requestGeneration
        ) else { return }
        if let authoritativeList {
            tokens = authoritativeList
            tokensError = clientCleanupFailed ? Self.clientCleanupFailureMessage : nil
        } else if readbackFailure == .invalidAdministratorToken {
            if handleAdminFailure(RouterAdministrationError.invalidAdministratorToken) {
                try? await adminClient.clearAdministratorCredential()
            }
        } else if readbackFailure == .cancelled {
            if clientCleanupFailed {
                tokensError = Self.clientCleanupFailureMessage
            }
        } else if clientCleanupFailed {
            tokensError = Self.clientCleanupFailureMessage
        } else {
            tokensError = "The token was revoked, but the updated client list could not be loaded."
        }
    }

    func reloadPairingMode() async {
        if let demoState {
            publishPairingStatus(RouterPairingMode(
                open: demoState.pairingMode.open,
                expiresAt: demoState.pairingMode.expiresAt,
                pin: nil
            ))
            return
        }
        guard !usesDemoServices else { return }
        await performPairingStatusAdmin { client in
            try await client.pairingMode()
        } apply: { [weak self] status in
            self?.publishPairingStatus(status)
        }
    }

    func openPairing() async {
        if var demoState {
            let status = RouterPairingMode(
                open: true,
                expiresAt: now().addingTimeInterval(300),
                pin: nil
            )
            demoState.pairingMode = status
            self.demoState = demoState
            publishPairingStatus(status)
            return
        }
        guard !usesDemoServices else { return }
        await performPairingStatusAdmin { client in
            try await client.openPairingMode()
        } apply: { [weak self] status in
            self?.publishPairingStatus(status)
        }
    }

    func closePairing() async {
        if var demoState {
            let status = RouterPairingMode(open: false, expiresAt: .distantPast, pin: nil)
            demoState.pairingMode = status
            self.demoState = demoState
            publishPairingStatus(status)
            return
        }
        guard !usesDemoServices else { return }
        await performPairingStatusAdmin { client in
            try await client.closePairingMode()
        } apply: { [weak self] in
            self?.publishPairingStatus(RouterPairingMode(
                open: false,
                expiresAt: .distantPast,
                pin: nil
            ))
        }
    }

    func loadPairingQR() async {
        guard !usesDemoServices else { return }
        guard pairingStatus?.open == true else { return }
        pairingQRRequestGeneration &+= 1
        let requestGeneration = pairingQRRequestGeneration
        isPairingQRLoading = true
        pairingError = nil
        let result = await performPairingAdmin({ client in
            try await client.pairingQRCodePNG()
        }, isCurrent: { [weak self] in
            self?.pairingQRRequestGeneration == requestGeneration
        })
        guard pairingQRRequestGeneration == requestGeneration else { return }
        isPairingQRLoading = false
        switch result {
        case let .success(png):
            guard pairingStatus?.open == true else { return }
            pairingQRPNG = png
            pairingError = nil
        case let .failure(message):
            pairingError = message
        case .stale:
            break
        }
    }

    func clearPairingSecrets() {
        invalidatePairingSecrets(displayState: .unknown)
    }

    func expirePairingSecretsIfNeeded() {
        guard let status = pairingStatus,
              status.open,
              status.expiresAt <= now()
        else { return }
        expirePairingSecrets()
    }

    func pairingDidEnterBackground() {
        clearPairingSecrets()
        pairingError = nil
    }

    func pairingDidBecomeActive() async {
        await reloadPairingMode()
    }

    private func publishPairingStatus(_ status: RouterPairingMode) {
        pairingExpiryTask?.cancel()
        pairingExpiryTask = nil
        pairingSecretGeneration &+= 1
        pairingQRRequestGeneration &+= 1
        isPairingQRLoading = false
        pairingQRPNG = nil
        guard status.open else {
            pairingStatus = status
            pairingDisplayState = .closed
            return
        }
        guard status.expiresAt > now() else {
            pairingStatus = nil
            pairingDisplayState = .expired
            return
        }
        pairingStatus = status
        pairingDisplayState = .open
        schedulePairingExpiry(at: status.expiresAt)
    }

    private func schedulePairingExpiry(at deadline: Date) {
        let secretGeneration = pairingSecretGeneration
        let sleep = pairingExpirySleep
        pairingExpiryTask = Task { [weak self] in
            do {
                try await sleep(deadline)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  pairingSecretGeneration == secretGeneration,
                  pairingStatus?.open == true,
                  pairingStatus?.expiresAt == deadline,
                  deadline <= now()
            else { return }
            expirePairingSecrets()
        }
    }

    private func expirePairingSecrets() {
        invalidatePairingSecrets(displayState: .expired)
        pairingError = nil
    }

    private func invalidatePairingSecrets(displayState: PairingDisplayState) {
        pairingExpiryTask?.cancel()
        pairingExpiryTask = nil
        pairingSecretGeneration &+= 1
        pairingQRRequestGeneration &+= 1
        pairingStatus = nil
        pairingQRPNG = nil
        isPairingQRLoading = false
        pairingDisplayState = displayState
    }

    private enum AdminResult<Value> {
        case success(Value)
        case failure(String)
        case stale
    }

    private enum AdvancedResult<Value> {
        case success(Value)
        case advancedDisabled
        case capabilityUnsupported
        case failure
        case stale
    }

    private enum AdvancedValueUpdate {
        case bypassThreshold(Double)
        case clock(RouterAdvancedClockValue)
        case runningMode(UInt8)
        case barrierFree(Bool)
        case usbFirmware(RouterAdvancedUSBFirmwareValue)
        case blePINUpdated(Bool)
    }

    private func publishTokenResult(_ result: AdminResult<[RouterTokenMetadata]>) {
        switch result {
        case let .success(list):
            tokens = list
            tokensError = nil
        case let .failure(message):
            tokensError = message
        case .stale:
            break
        }
    }

    private func isCurrentTokenOperation(
        session: UInt64,
        adminOperation: UInt64,
        request: UInt64
    ) -> Bool {
        sessionGeneration == session
            && adminOperationGeneration == adminOperation
            && tokenRequestGeneration == request
            && access == .unlocked
    }

    private func isCurrentAdminEndpoint(
        session: UInt64,
        adminOperation: UInt64,
        endpoint: RouterEndpoint?
    ) -> Bool {
        sessionGeneration == session
            && adminOperationGeneration == adminOperation
            && host?.endpoint == endpoint
            && access == .unlocked
    }

    private func isCurrentTLSOperation(
        source: RouterHostMetadata,
        session: UInt64,
        adminOperation: UInt64,
        request: UInt64,
        expectedAccess: AdminAccess = .unlocked
    ) -> Bool {
        sessionGeneration == session
            && adminOperationGeneration == adminOperation
            && tlsRequestGeneration == request
            && host == source
            && access == expectedAccess
    }

    private static let clientCleanupFailureMessage =
        "Token was revoked, but this device's local client credential could not be removed."

    private func performDevicePairing(
        _ operation: (
            RouterDevicePairingClient,
            @escaping RouterDevicePairingProgress
        ) async throws -> RouterDevicePairingStatus
    ) async {
        guard let client = devicePairingClient, host != nil else { return }
        let session = sessionGeneration
        let generation = devicePairingGeneration
        guard !isDevicePairingRunning else { return }
        isDevicePairingRunning = true
        devicePairingError = nil
        defer {
            if sessionGeneration == session, devicePairingGeneration == generation {
                isDevicePairingRunning = false
            }
        }
        do {
            let progress: RouterDevicePairingProgress = { [weak self, weak client] status in
                guard let self, let client else { return }
                await self.publishDevicePairingProgress(
                    status,
                    client: client,
                    session: session,
                    generation: generation
                )
            }
            let status = try await operation(client, progress)
            guard sessionGeneration == session,
                  devicePairingGeneration == generation,
                  devicePairingClient === client
            else { return }
            devicePairingStatus = status
            devicePairingError = status.stage == .error
                ? "Link-Power pairing failed."
                : nil
        } catch is CancellationError {
            return
        } catch RouterDevicePairingError.timedOut {
            guard sessionGeneration == session, devicePairingGeneration == generation else { return }
            devicePairingError = "Link-Power pairing timed out."
        } catch let RouterDevicePairingError.operationInProgress(status) {
            guard sessionGeneration == session, devicePairingGeneration == generation else { return }
            devicePairingStatus = status
        } catch {
            guard sessionGeneration == session, devicePairingGeneration == generation else { return }
            devicePairingError = "Could not complete Link-Power pairing."
        }
    }

    private func publishDevicePairingProgress(
        _ status: RouterDevicePairingStatus,
        client: RouterDevicePairingClient,
        session: UInt64,
        generation: UInt64
    ) {
        guard !Task.isCancelled,
              sessionGeneration == session,
              devicePairingGeneration == generation,
              devicePairingClient === client
        else { return }
        devicePairingStatus = status
        devicePairingError = status.stage == .error
            ? "Link-Power pairing failed."
            : nil
    }

    private func performAdvanced<Value>(
        _ operation: (RouterAdministrationClient) async throws -> Value
    ) async -> AdvancedResult<Value> {
        guard host != nil, access == .unlocked else { return .stale }
        let session = sessionGeneration
        let adminOperation = adminOperationGeneration
        do {
            let value = try await operation(adminClient)
            guard !Task.isCancelled,
                  sessionGeneration == session,
                  adminOperationGeneration == adminOperation,
                  access == .unlocked
            else { return .stale }
            return .success(value)
        } catch is CancellationError {
            return .stale
        } catch NetworkError.api(403, .advancedDisabled, _) {
            guard !Task.isCancelled,
                  sessionGeneration == session,
                  adminOperationGeneration == adminOperation,
                  access == .unlocked
            else { return .stale }
            return .advancedDisabled
        } catch NetworkError.api(409, .capabilityUnsupported, _) {
            guard !Task.isCancelled,
                  sessionGeneration == session,
                  adminOperationGeneration == adminOperation,
                  access == .unlocked
            else { return .stale }
            return .capabilityUnsupported
        } catch {
            guard !Task.isCancelled,
                  sessionGeneration == session,
                  adminOperationGeneration == adminOperation,
                  access == .unlocked
            else { return .stale }
            if handleAdminFailure(error) {
                try? await adminClient.clearAdministratorCredential()
                return .stale
            }
            return .failure
        }
    }

    private func performAdvancedSurface<Value>(
        _ surface: RouterAdvancedSurface,
        operation: (RouterAdministrationClient) async throws -> Value,
        publish: (Value) -> Void
    ) async {
        guard advancedVisibility.surfaces.contains(surface),
              !isAdvancedMutationRunning
        else { return }
        advancedMutationGeneration &+= 1
        let request = advancedMutationGeneration
        let session = sessionGeneration
        let adminOperation = adminOperationGeneration
        isAdvancedMutationRunning = true
        defer {
            if advancedMutationGeneration == request {
                isAdvancedMutationRunning = false
            }
        }
        advancedError = nil
        let result = await performAdvanced(operation)
        guard isCurrentAdvancedMutation(
            session: session,
            adminOperation: adminOperation,
            request: request
        ) else { return }
        switch result {
        case let .success(value):
            publish(value)
        case .advancedDisabled:
            advancedServerGate = .advancedDisabled
            clearAdvancedValues()
            await reloadSettings()
        case .capabilityUnsupported:
            let refreshed = await reloadAdvanced()
            guard !advancedPostRefreshIsCancelled(),
                  isCurrentAdvancedMutation(
                session: session,
                adminOperation: adminOperation,
                request: request
            ) else { return }
            if refreshed, settings?.advanced == true {
                unsupportedAdvancedSurfaces.insert(surface)
            }
        case .failure:
            advancedError = "The advanced device request failed. Try again."
        case .stale:
            break
        }
    }

    private func isCurrentAdvancedLoad(
        session: UInt64,
        adminOperation: UInt64,
        request: UInt64
    ) -> Bool {
        sessionGeneration == session
            && adminOperationGeneration == adminOperation
            && advancedLoadGeneration == request
            && access == .unlocked
    }

    private func isCurrentAdvancedMutation(
        session: UInt64,
        adminOperation: UInt64,
        request: UInt64
    ) -> Bool {
        sessionGeneration == session
            && adminOperationGeneration == adminOperation
            && advancedMutationGeneration == request
            && access == .unlocked
    }

    private func publishAdvancedValue(_ update: AdvancedValueUpdate) {
        switch update {
        case let .bypassThreshold(value):
            advancedValues = RouterAdvancedValues(
                bypassThresholdVolts: value,
                clock: advancedValues.clock,
                runningMode: advancedValues.runningMode,
                barrierFreeEnabled: advancedValues.barrierFreeEnabled,
                usbFirmware: advancedValues.usbFirmware,
                blePINUpdated: advancedValues.blePINUpdated
            )
        case let .clock(value):
            advancedValues = RouterAdvancedValues(
                bypassThresholdVolts: advancedValues.bypassThresholdVolts,
                clock: value,
                runningMode: advancedValues.runningMode,
                barrierFreeEnabled: advancedValues.barrierFreeEnabled,
                usbFirmware: advancedValues.usbFirmware,
                blePINUpdated: advancedValues.blePINUpdated
            )
        case let .runningMode(value):
            advancedValues = RouterAdvancedValues(
                bypassThresholdVolts: advancedValues.bypassThresholdVolts,
                clock: advancedValues.clock,
                runningMode: value,
                barrierFreeEnabled: advancedValues.barrierFreeEnabled,
                usbFirmware: advancedValues.usbFirmware,
                blePINUpdated: advancedValues.blePINUpdated
            )
        case let .barrierFree(value):
            advancedValues = RouterAdvancedValues(
                bypassThresholdVolts: advancedValues.bypassThresholdVolts,
                clock: advancedValues.clock,
                runningMode: advancedValues.runningMode,
                barrierFreeEnabled: value,
                usbFirmware: advancedValues.usbFirmware,
                blePINUpdated: advancedValues.blePINUpdated
            )
        case let .usbFirmware(value):
            advancedValues = RouterAdvancedValues(
                bypassThresholdVolts: advancedValues.bypassThresholdVolts,
                clock: advancedValues.clock,
                runningMode: advancedValues.runningMode,
                barrierFreeEnabled: advancedValues.barrierFreeEnabled,
                usbFirmware: value,
                blePINUpdated: advancedValues.blePINUpdated
            )
        case let .blePINUpdated(value):
            advancedValues = RouterAdvancedValues(
                bypassThresholdVolts: advancedValues.bypassThresholdVolts,
                clock: advancedValues.clock,
                runningMode: advancedValues.runningMode,
                barrierFreeEnabled: advancedValues.barrierFreeEnabled,
                usbFirmware: advancedValues.usbFirmware,
                blePINUpdated: value
            )
        }
    }

    private static func clockValue(_ value: RouterDeviceClockStatus) -> RouterAdvancedClockValue {
        RouterAdvancedClockValue(
            available: value.available,
            deviceTime: value.deviceTime,
            systemTime: value.systemTime,
            driftSeconds: value.driftSeconds
        )
    }

    private func clearAdvancedValues() {
        advancedValues = RouterAdvancedValues()
    }

    private func clearAdvancedState() {
        advancedLoadGeneration &+= 1
        advancedMutationGeneration &+= 1
        advancedIdentity = nil
        clearAdvancedValues()
        advancedError = nil
        isAdvancedLoading = false
        isAdvancedMutationRunning = false
        unsupportedAdvancedSurfaces = []
        advancedServerGate = .allowed
    }

    private func performAdmin<Value>(
        _ operation: (RouterAdministrationClient) async throws -> Value,
        isCurrent: () -> Bool = { true },
        onInvalidAdministrator: () -> Void = {}
    ) async -> AdminResult<Value> {
        guard host != nil, access == .unlocked else { return .stale }
        let session = sessionGeneration
        let adminOperation = adminOperationGeneration
        do {
            let value = try await operation(adminClient)
            guard !Task.isCancelled,
                  sessionGeneration == session,
                  adminOperationGeneration == adminOperation,
                  access == .unlocked,
                  isCurrent()
            else { return .stale }
            return .success(value)
        } catch is CancellationError {
            return .stale
        } catch {
            guard !Task.isCancelled,
                  sessionGeneration == session,
                  adminOperationGeneration == adminOperation,
                  access == .unlocked,
                  isCurrent()
            else { return .stale }
            if handleAdminFailure(error) {
                onInvalidAdministrator()
                try? await adminClient.clearAdministratorCredential()
                return .stale
            }
            return .failure("The request failed. Try again.")
        }
    }

    private func mutateRules(
        _ operation: (RouterAdministrationClient) async throws -> RouterRuleMutationResult
    ) async {
        guard host != nil, access == .unlocked else { return }
        rulesRequestGeneration &+= 1
        let request = rulesRequestGeneration
        rulesError = nil
        var invalidAdministrator = false
        let result = await performAdmin(
            operation,
            isCurrent: { [weak self] in
                self?.rulesRequestGeneration == request
            },
            onInvalidAdministrator: {
                invalidAdministrator = true
            }
        )
        guard rulesRequestGeneration == request else { return }
        switch result {
        case let .success(mutation):
            publishRules(mutation.rules)
        case let .failure(message):
            rulesError = message
            rulesLoadState = .stale
        case .stale:
            if invalidAdministrator,
               access == .locked,
               adminError == "The administrator session is no longer valid." {
                rulesError = "Unlock administration and refresh rules before editing again."
                rulesLoadState = .stale
            }
        }
    }

    private func publishRules(_ authoritativeRules: [RouterRuleDocument]) {
        rules = authoritativeRules
        rulesFetchedAt = now()
        rulesError = nil
        rulesLoadState = .loaded
    }

    private func ruleConfirmationAllowsMutation(
        _ rule: RouterRule,
        confirmation: RouterRuleConfirmation?
    ) -> Bool {
        !rule.actions.contains(.shutdown) || confirmation == .shutdown
    }

    private static func ruleName(_ document: RouterRuleDocument) -> String? {
        switch document {
        case let .known(rule): rule.name
        case let .unknown(raw): raw.name
        }
    }

    private func performPairingAdmin<Value>(
        _ operation: (RouterAdministrationClient) async throws -> Value,
        isCurrent: () -> Bool = { true }
    ) async -> AdminResult<Value> {
        let secretGeneration = pairingSecretGeneration
        let result = await performAdmin(
            operation,
            isCurrent: {
                pairingSecretGeneration == secretGeneration && isCurrent()
            }
        )
        guard pairingSecretGeneration == secretGeneration else {
            return .stale
        }
        return result
    }

    private func performPairingStatusAdmin<Value>(
        _ operation: (RouterAdministrationClient) async throws -> Value,
        apply: (Value) -> Void
    ) async {
        guard host != nil, access == .unlocked else { return }
        pairingStatusRequestGeneration &+= 1
        let requestGeneration = pairingStatusRequestGeneration
        invalidatePairingSecrets(displayState: .loading)
        pairingError = nil
        let result = await performPairingAdmin(operation) {
            pairingStatusRequestGeneration == requestGeneration
        }
        guard pairingStatusRequestGeneration == requestGeneration else { return }
        switch result {
        case let .success(value):
            apply(value)
            pairingError = nil
        case let .failure(message):
            invalidatePairingSecrets(displayState: .failed)
            pairingError = message
        case .stale:
            break
        }
    }

    private func handleAdminFailure(_ error: Error) -> Bool {
        guard (error as? RouterAdministrationError) == .invalidAdministratorToken else {
            return false
        }
        adminOperationGeneration &+= 1
        access = .locked
        clearPairingSecrets()
        clearSettingsState()
        adminError = "The administrator session is no longer valid."
        return true
    }

    private func publishVerifiedAdministrationBoundary(for host: RouterHostMetadata) {
        access = .unlocked
        settingsRestartRequiredHosts.remove(host.id)
        settingsRestartRequired = false
    }

    private func publishSettingsSave(
        _ value: RouterSettingsUpdateResult,
        source: RouterHostMetadata
    ) {
        settings = value.settings
        if !value.settings.advanced {
            clearAdvancedState()
        }
        if value.restartRequired {
            settingsRestartRequiredHosts.insert(source.id)
        }
        settingsRestartRequired = settingsRestartRequiredHosts.contains(source.id)
    }

    private static func offersTransientTLSRecovery(_ error: Error) -> Bool {
        if (error as? RouterTLSPromotionError) == .missingCredential {
            return true
        }
        if let administration = error as? RouterAdministrationError {
            return administration == .invalidAdministratorToken
                || administration == .clientTokenRejected
        }
        guard let network = error as? NetworkError else { return false }
        switch network {
        case .unauthorized:
            return true
        case let .api(status, code, _):
            return status == 401 || (status == 403 && code == .adminRequired)
        case let .httpStatus(status, _):
            return status == 401 || status == 403
        default:
            return false
        }
    }

    private func clearSettingsState() {
        settingsLoadGeneration &+= 1
        settingsSaveGeneration &+= 1
        settings = nil
        settingsError = nil
        settingsRestartRequired = host.map { settingsRestartRequiredHosts.contains($0.id) } ?? false
        isSettingsLoading = false
        isSettingsSaving = false
        invalidateReplacementValidation()
        tlsRequestGeneration &+= 1
        tlsError = nil
        tlsRestartRequired = false
        isTLSRotationRunning = false
        isTLSPromotionRunning = false
        tlsPromotionRecoveryAvailable = false
        clearAdvancedState()
    }

    private func clearRulesState() {
        rulesRequestGeneration &+= 1
        rules = []
        rulesFetchedAt = nil
        rulesError = nil
        rulesLoadState = .neverLoaded
    }

    private func publishDemo(_ demo: RouterAdministrationDemo) {
        host = demo.host
        access = .unlocked
        adminError = nil
        history = demo.history
        historyFetchedAt = now()
        historyError = nil
        historyLoadState = .loaded
        rules = demo.rules
        rulesFetchedAt = now()
        rulesError = nil
        rulesLoadState = .loaded
        pairingStatus = demo.pairingMode
        pairingDisplayState = demo.pairingMode.open ? .open : .closed
        pairingQRPNG = nil
        pairingError = nil
        tokens = demo.tokens
        tokensError = nil
        settings = demo.settings
        settingsError = nil
        devicePairingStatus = demo.devicePairingStatus
        devicePairingError = nil
        advancedIdentity = demo.identity
        advancedValues = demo.advancedValues
        advancedError = nil
    }

    private static func unlockMessage(for error: Error) -> String {
        switch error {
        case RouterAdministrationError.invalidAdministratorToken:
            "That administrator token was rejected."
        case RouterAdministrationError.clientTokenRejected:
            "That is a managed client token. Administration needs the bootstrap administrator token."
        default:
            "Could not verify the administrator token. Try again."
        }
    }

    private static func routeReachability(
        _ reachability: RouterHostReachability
    ) -> RouterSettingsRouteReachability {
        switch reachability {
        case .lan: .lan
        case .vpn: .vpn
        case .wan: .wan
        }
    }
}

struct RouterAdministrationPresentation: Equatable {
    enum Section: Equatable {
        case clientEnrollment
        case apiClients
        case routerConfiguration
    }

    let showsHistory: Bool
    let showsClientSections: Bool
    let showsAdministratorSections: Bool
    let showsUnlockField: Bool
    let visibleSections: [Section]

    init(access: RouterAdministrationModel.AdminAccess) {
        showsHistory = true
        showsClientSections = true
        showsAdministratorSections = access == .unlocked
        showsUnlockField = access != .unlocked
        visibleSections = access == .unlocked
            ? [.clientEnrollment, .apiClients, .routerConfiguration]
            : []
    }
}
