import Foundation
import Observation
import WattlineCore
import WattlineNetwork

enum AppTransportKind: String, CaseIterable, Hashable, Sendable {
    case bluetooth
    case router
    case demo

    var label: String {
        switch self {
        case .bluetooth: "BT"
        case .router: "Router"
        case .demo: "Demo"
        }
    }
}

struct AppDeviceConnectionRecord: Identifiable, Equatable, Sendable {
    let id: String
    let identity: DeviceIdentitySnapshot?
    let bluetoothDevice: DiscoveredDevice?
    let discoveredRouter: DiscoveredRouter?
    let routerHost: RouterHostMetadata?
    let transportOptions: Set<AppTransportKind>
    let preferredTransport: AppTransportKind
}

@MainActor
@Observable
final class RouterConnectionModel {
    static let canonicalClientEndpoints: Set<RouterEndpointCapability> = [
        .controls,
        .usbCLimit,
    ]

    typealias TransportFactory = @MainActor (
        _ endpoint: RouterEndpoint,
        _ credentials: any RouterCredentialProvider
    ) throws -> any DeviceTransport
    typealias EnrollmentClientFactory = @MainActor (
        _ endpoint: RouterEndpoint
    ) throws -> RouterEnrollmentClient

    private(set) var savedHosts: [RouterHostMetadata] = []
    private(set) var discoveredRouters: [DiscoveredRouter] = []
    private(set) var discoveryError: String?
    private(set) var loadError: String?
    private var routerIdentities: [UUID: DeviceIdentitySnapshot] = [:]
    private var discoveryGeneration: UInt64 = 0
    private var discoveryTask: Task<Void, Never>?

    private let hostStore: RouterHostStore
    private let credentialStore: RouterCredentialStore
    private let discovery: RouterDiscovery?
    private let enrollmentClientFactory: EnrollmentClientFactory
    private let transportFactory: TransportFactory

    init(
        hostStore: RouterHostStore,
        credentialStore: RouterCredentialStore,
        discovery: RouterDiscovery? = nil,
        enrollmentClientFactory: @escaping EnrollmentClientFactory,
        transportFactory: @escaping TransportFactory
    ) {
        self.hostStore = hostStore
        self.credentialStore = credentialStore
        self.discovery = discovery
        self.enrollmentClientFactory = enrollmentClientFactory
        self.transportFactory = transportFactory
    }

    static func production(defaults: UserDefaults = .standard) -> RouterConnectionModel {
        let hosts = RouterHostStore(backend: UserDefaultsRouterHostBackend(defaults: defaults))
        let credentials = RouterCredentialStore(backend: KeychainRouterCredentialBackend())
        return RouterConnectionModel(
            hostStore: hosts,
            credentialStore: credentials,
            discovery: RouterDiscovery(source: NWBrowserRouterDiscoverySource()),
            enrollmentClientFactory: { endpoint in
                let session = try RouterURLSessionFactory.make(endpoint: endpoint)
                let baseURL = try RouterURLSessionFactory.baseURL(for: endpoint)
                return RouterEnrollmentClient(
                    httpClient: HTTPClient(baseURL: baseURL, session: session)
                )
            }
        ) { endpoint, credentials in
            let session = try RouterURLSessionFactory.make(endpoint: endpoint)
            let baseURL = try RouterURLSessionFactory.baseURL(for: endpoint)
            return RouterTransport(
                endpoint: endpoint,
                accessLevel: .client,
                credentials: credentials,
                client: HTTPClient(baseURL: baseURL, session: session),
                events: SSEClient(baseURL: baseURL, session: session),
                clock: SystemRouterConnectionClock(),
                backoff: RouterReconnectBackoff(
                    delays: [.seconds(1), .seconds(2), .seconds(5), .seconds(10)]
                )
            )
        }
    }

    func startDiscovery() {
        guard discoveryTask == nil, let discovery else { return }
        discoveryGeneration &+= 1
        let generation = discoveryGeneration
        discoveryError = nil
        discoveryTask = Task { [weak self] in
            for await routers in discovery.routers() {
                guard !Task.isCancelled,
                      let self,
                      self.discoveryGeneration == generation
                else { return }
                self.discoveredRouters = routers
            }
            guard !Task.isCancelled,
                  let self,
                  self.discoveryGeneration == generation
            else { return }
            self.discoveryError = "Router discovery stopped. Check Local Network access and try again."
            self.discoveryTask = nil
        }
    }

    func stopDiscovery() {
        discoveryGeneration &+= 1
        discoveryTask?.cancel()
        discoveryTask = nil
        discoveredRouters = []
        discoveryError = nil
    }

    func reloadSavedHosts() async {
        savedHosts = await hostStore.hosts()
        loadError = nil
    }

    @discardableResult
    func saveManualHost(
        address: String,
        displayName: String,
        reachability: RouterHostReachability,
        allowsInsecureWAN: Bool,
        deviceID: String?,
        certificateFingerprint: String?,
        token: String
    ) async throws -> RouterHostMetadata {
        let host = try RouterHostValidator.validate(
            address,
            displayName: displayName,
            reachability: reachability,
            allowsInsecureWAN: allowsInsecureWAN,
            deviceID: deviceID,
            certificateFingerprint: certificateFingerprint
        )
        return try await persist(host: host, token: token)
    }

    @discardableResult
    func enroll(
        payload: RouterPairingPayload,
        displayName: String,
        reachability: RouterHostReachability,
        allowsInsecureWAN: Bool = false,
        label: String
    ) async throws -> RouterHostMetadata {
        let client = try enrollmentClientFactory(payload.enrollmentEndpoint)
        let result = try await client.enroll(
            pin: payload.pin,
            label: label,
            expectedDeviceID: payload.deviceID,
            expectedFingerprint: payload.certificateFingerprint
        )
        var components = URLComponents()
        components.scheme = result.endpoint.scheme
        components.host = result.endpoint.host
        components.port = result.endpoint.port
        guard let address = components.string else {
            throw RouterEnrollmentError.invalidResponse
        }
        let host = try RouterHostValidator.validate(
            address,
            displayName: displayName,
            reachability: reachability,
            allowsInsecureWAN: allowsInsecureWAN,
            deviceID: result.deviceID,
            certificateFingerprint: result.endpoint.certificateFingerprint
        )
        return try await persist(host: host, token: result.token)
    }

    @discardableResult
    func enroll(
        router: DiscoveredRouter,
        pin: String,
        label: String
    ) async throws -> RouterHostMetadata {
        let client = try enrollmentClientFactory(router.endpoint)
        let result = try await client.enroll(
            pin: pin,
            label: label,
            expectedDeviceID: router.deviceID,
            expectedFingerprint: router.certificateFingerprint
        )
        let host = try Self.host(
            result: result,
            displayName: router.serviceName,
            reachability: .lan,
            allowsInsecureWAN: false
        )
        return try await persist(host: host, token: result.token)
    }

    func remove(_ host: RouterHostMetadata) async throws {
        try await credentialStore.deleteToken(for: host.endpoint)
        try await hostStore.remove(id: host.id)
        await reloadSavedHosts()
    }

    func makeTransport(for host: RouterHostMetadata) throws -> any DeviceTransport {
        try transportFactory(host.endpoint, credentialStore)
    }

    private func persist(host: RouterHostMetadata, token: String) async throws -> RouterHostMetadata {
        try await credentialStore.saveToken(token, for: host.endpoint)
        do {
            try await hostStore.save(host)
        } catch {
            try? await credentialStore.deleteToken(for: host.endpoint)
            throw error
        }
        await reloadSavedHosts()
        return host
    }

    private static func host(
        result: RouterEnrollmentResult,
        displayName: String,
        reachability: RouterHostReachability,
        allowsInsecureWAN: Bool
    ) throws -> RouterHostMetadata {
        var components = URLComponents()
        components.scheme = result.endpoint.scheme
        components.host = result.endpoint.host
        components.port = result.endpoint.port
        guard let address = components.string else {
            throw RouterEnrollmentError.invalidResponse
        }
        return try RouterHostValidator.validate(
            address,
            displayName: displayName,
            reachability: reachability,
            allowsInsecureWAN: allowsInsecureWAN,
            deviceID: result.deviceID,
            certificateFingerprint: result.endpoint.certificateFingerprint
        )
    }

    func record(identity: DeviceIdentitySnapshot) {
        routerIdentities[identity.peripheralID] = identity
    }

    func records(bluetooth identities: [DeviceIdentitySnapshot]) -> [AppDeviceConnectionRecord] {
        var records = identities.map { identity in
            AppDeviceConnectionRecord(
                id: "ble:\(identity.peripheralID.uuidString)",
                identity: identity,
                bluetoothDevice: nil,
                discoveredRouter: nil,
                routerHost: nil,
                transportOptions: [.bluetooth],
                preferredTransport: .bluetooth
            )
        }

        for host in savedHosts {
            let matchingIndex = records.firstIndex { record in
                if let routerIdentity = routerIdentities[host.endpoint.peripheralID],
                   DeviceIdentityDeduplicator.merge(
                       ble: record.identity,
                       router: routerIdentity
                   ) != nil {
                    return true
                }
                guard let hostMAC = DeviceIdentityDeduplicator.normalizedMAC(host.deviceID),
                      let deviceMAC = DeviceIdentityDeduplicator.normalizedMAC(record.identity?.macAddress)
                else { return false }
                return hostMAC == deviceMAC
            }
            if let matchingIndex {
                let existing = records[matchingIndex]
                records[matchingIndex] = AppDeviceConnectionRecord(
                    id: existing.id,
                    identity: existing.identity,
                    bluetoothDevice: existing.bluetoothDevice,
                    discoveredRouter: existing.discoveredRouter,
                    routerHost: host,
                    transportOptions: [.bluetooth, .router],
                    preferredTransport: .bluetooth
                )
            } else {
                records.append(AppDeviceConnectionRecord(
                    id: "router:\(host.id.uuidString)",
                    identity: routerIdentities[host.endpoint.peripheralID],
                    bluetoothDevice: nil,
                    discoveredRouter: nil,
                    routerHost: host,
                    transportOptions: [.router],
                    preferredTransport: .router
                ))
            }
        }
        return records
    }

    func scanRecords(
        bluetooth devices: [DiscoveredDevice],
        identities: [UUID: AppModel.CachedIdentity]
    ) -> [AppDeviceConnectionRecord] {
        var records = devices.map { device in
            AppDeviceConnectionRecord(
                id: "ble:\(device.id.uuidString)",
                identity: identities[device.id].map { Self.snapshot(for: device, cached: $0) },
                bluetoothDevice: device,
                discoveredRouter: nil,
                routerHost: nil,
                transportOptions: [.bluetooth],
                preferredTransport: .bluetooth
            )
        }

        for router in discoveredRouters {
            let routerIdentity = Self.snapshot(for: router)
            let host = savedHosts.first { Self.matches($0, router: router) }
            if let index = records.firstIndex(where: { record in
                guard let identity = record.identity else { return false }
                return DeviceIdentityDeduplicator.merge(ble: identity, router: routerIdentity) != nil
            }) {
                let existing = records[index]
                records[index] = AppDeviceConnectionRecord(
                    id: existing.id,
                    identity: existing.identity,
                    bluetoothDevice: existing.bluetoothDevice,
                    discoveredRouter: router,
                    routerHost: host,
                    transportOptions: [.bluetooth, .router],
                    preferredTransport: .bluetooth
                )
            } else {
                records.append(AppDeviceConnectionRecord(
                    id: "router-discovered:\(router.deviceID)",
                    identity: routerIdentity,
                    bluetoothDevice: nil,
                    discoveredRouter: router,
                    routerHost: host,
                    transportOptions: [.router],
                    preferredTransport: .router
                ))
            }
        }

        for host in savedHosts where !records.contains(where: { $0.routerHost?.id == host.id }) {
            if let index = records.firstIndex(where: { record in
                guard let hostMAC = DeviceIdentityDeduplicator.normalizedMAC(host.deviceID),
                      let deviceMAC = DeviceIdentityDeduplicator.normalizedMAC(record.identity?.macAddress)
                else { return false }
                return hostMAC == deviceMAC
            }) {
                let existing = records[index]
                records[index] = AppDeviceConnectionRecord(
                    id: existing.id,
                    identity: existing.identity,
                    bluetoothDevice: existing.bluetoothDevice,
                    discoveredRouter: existing.discoveredRouter,
                    routerHost: host,
                    transportOptions: [.bluetooth, .router],
                    preferredTransport: .bluetooth
                )
            } else {
                records.append(AppDeviceConnectionRecord(
                    id: "router-saved:\(host.id.uuidString)",
                    identity: routerIdentities[host.endpoint.peripheralID],
                    bluetoothDevice: nil,
                    discoveredRouter: nil,
                    routerHost: host,
                    transportOptions: [.router],
                    preferredTransport: .router
                ))
            }
        }

        return records.sorted { lhs, rhs in
            if lhs.preferredTransport != rhs.preferredTransport {
                return lhs.preferredTransport == .bluetooth
            }
            return Self.displayName(for: lhs)
                .localizedCaseInsensitiveCompare(Self.displayName(for: rhs)) == .orderedAscending
        }
    }

    private static func snapshot(
        for device: DiscoveredDevice,
        cached: AppModel.CachedIdentity
    ) -> DeviceIdentitySnapshot {
        let features = cached.rawFeatures.map(FeatureFlags.init(rawValue:))
        return DeviceIdentitySnapshot(
            peripheralID: device.id,
            advertisedName: cached.advertisedName,
            mode: device.mode,
            modelNumber: cached.modelNumber,
            hardwareRevision: cached.hardwareRevision,
            otaFirmwareRevision: cached.otaFirmwareRevision,
            appFirmwareRevision: cached.appFirmwareRevision,
            cid: cached.cid,
            rawFeatures: cached.rawFeatures,
            macAddress: cached.macAddress,
            capabilities: CapabilityResolver.resolve(
                features: features,
                cid: cached.cid,
                model: cached.modelNumber
            )
        )
    }

    private static func snapshot(for router: DiscoveredRouter) -> DeviceIdentitySnapshot {
        let features = router.features.map(FeatureFlags.init(rawValue:))
        return DeviceIdentitySnapshot(
            peripheralID: router.endpoint.peripheralID,
            advertisedName: router.serviceName,
            mode: .application,
            modelNumber: router.model,
            cid: router.cid,
            rawFeatures: router.features,
            macAddress: router.deviceID,
            capabilities: CapabilityResolver.resolve(
                features: features,
                cid: router.cid,
                model: router.model
            )
        )
    }

    private static func matches(_ host: RouterHostMetadata, router: DiscoveredRouter) -> Bool {
        if let hostMAC = DeviceIdentityDeduplicator.normalizedMAC(host.deviceID) {
            return hostMAC == router.deviceID
        }
        return host.endpoint.peripheralID == router.endpoint.peripheralID
    }

    private static func displayName(for record: AppDeviceConnectionRecord) -> String {
        record.bluetoothDevice?.localName
            ?? record.routerHost?.displayName
            ?? record.discoveredRouter?.serviceName
            ?? "Wattline"
    }

    static func capabilities(
        for identity: DeviceIdentitySnapshot,
        endpoints: Set<RouterEndpointCapability>
    ) -> DeviceCapabilities {
        var features = identity.capabilities.features
        if !endpoints.contains(.controls) {
            features.subtract([.dcControl, .usbOutputControl, .dcBypassControl, .shutdown])
        }
        if !endpoints.contains(.usbCLimit) {
            features.remove(.usbPowerLimit)
        }
        // The documented client API exposes no schedule endpoints.
        features.remove(.dcScheduler)
        return DeviceCapabilities(features: features)
    }
}

private final class UserDefaultsRouterHostBackend: RouterHostKeyValueStore, @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func data(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    func set(_ data: Data, forKey key: String) {
        defaults.set(data, forKey: key)
    }

    func removeValue(forKey key: String) {
        defaults.removeObject(forKey: key)
    }
}
