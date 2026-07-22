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
    let routerClientCredentialAvailability: RouterClientCredentialAvailability

    init(
        id: String,
        identity: DeviceIdentitySnapshot?,
        bluetoothDevice: DiscoveredDevice?,
        discoveredRouter: DiscoveredRouter?,
        routerHost: RouterHostMetadata?,
        transportOptions: Set<AppTransportKind>,
        preferredTransport: AppTransportKind,
        routerClientCredentialAvailability: RouterClientCredentialAvailability = .unknown
    ) {
        self.id = id
        self.identity = identity
        self.bluetoothDevice = bluetoothDevice
        self.discoveredRouter = discoveredRouter
        self.routerHost = routerHost
        self.transportOptions = transportOptions
        self.preferredTransport = preferredTransport
        self.routerClientCredentialAvailability = routerClientCredentialAvailability
    }
}

enum RouterClientCredentialAvailability: Equatable, Sendable {
    case available
    case enrollmentRequired
    case unknown
}

final class GoodCloudAdministrationHTTPRegistry: @unchecked Sendable {
    typealias DirectFactory = @Sendable (RouterEndpoint) throws -> any RouterHTTPClient
    typealias PreferredFactory = @Sendable (
        RouterEndpoint,
        GoodCloudAssociation,
        any GoodCloudRelayProvisioning
    ) throws -> any RouterHTTPClient

    private struct Configuration: Sendable {
        let association: GoodCloudAssociation
        let provisioner: any GoodCloudRelayProvisioning
    }

    private let lock = NSLock()
    private let directFactory: DirectFactory
    private let preferredFactory: PreferredFactory
    private var configurationsByEndpointID: [UUID: Configuration] = [:]

    init(
        directFactory: @escaping DirectFactory,
        preferredFactory: @escaping PreferredFactory
    ) {
        self.directFactory = directFactory
        self.preferredFactory = preferredFactory
    }

    func update(
        hosts: [RouterHostMetadata],
        associations: [GoodCloudAssociation],
        provisioner: (any GoodCloudRelayProvisioning)?
    ) {
        guard let provisioner else {
            lock.withLock { configurationsByEndpointID = [:] }
            return
        }
        let endpointsByHostID = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0.endpoint) })
        let configurations = Dictionary(uniqueKeysWithValues: associations.compactMap { association in
            endpointsByHostID[association.hostID].map {
                ($0.peripheralID, Configuration(association: association, provisioner: provisioner))
            }
        })
        lock.withLock { configurationsByEndpointID = configurations }
    }

    func client(for endpoint: RouterEndpoint) throws -> any RouterHTTPClient {
        let configuration = lock.withLock { configurationsByEndpointID[endpoint.peripheralID] }
        guard let configuration else {
            return try directFactory(endpoint)
        }
        return try preferredFactory(
            endpoint,
            configuration.association,
            configuration.provisioner
        )
    }
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
    typealias TLSPromotionHTTPFactory = RouterTLSPinPromoter.HTTPFactory
    struct GoodCloudAccountDependencies: Sendable {
        let account: any GoodCloudAccountServing
        let provisioner: any GoodCloudRelayProvisioning

        init(
            account: any GoodCloudAccountServing,
            provisioner: any GoodCloudRelayProvisioning
        ) {
            self.account = account
            self.provisioner = provisioner
        }
    }
    typealias PreferredTransportFactory = @MainActor (
        _ endpoint: RouterEndpoint,
        _ credentials: any RouterCredentialProvider,
        _ association: GoodCloudAssociation,
        _ provisioner: any GoodCloudRelayProvisioning
    ) throws -> any DeviceTransport
    typealias GoodCloudAssociationLoader = @Sendable () async -> [GoodCloudAssociation]

    private(set) var savedHosts: [RouterHostMetadata] = []
    private(set) var discoveredRouters: [DiscoveredRouter] = []
    private(set) var discoveryError: String?
    private(set) var loadError: String?
    private var routerIdentities: [UUID: DeviceIdentitySnapshot] = [:]
    private var clientCredentialAvailability: [UUID: RouterClientCredentialAvailability] = [:]
    private var clientCredentialAvailabilityVersions: [UUID: UInt64] = [:]
    private var discoveryGeneration: UInt64 = 0
    private var discoveryTask: Task<Void, Never>?

    let hostStore: RouterHostStore
    let credentialStore: RouterCredentialStore
    private let discovery: RouterDiscovery?
    private let tlsPinPromoter: RouterTLSPinPromoter
    private let enrollmentClientFactory: EnrollmentClientFactory
    private let transportFactory: TransportFactory
    let administrationHTTPFactory: RouterAdministrationClient.HTTPFactory
    let goodCloudAccount: GoodCloudAccountDependencies?
    let goodCloudAssociations: GoodCloudAssociationStore?
    private let goodCloudAssociationLoader: GoodCloudAssociationLoader?
    private let preferredTransportFactory: PreferredTransportFactory?
    private let goodCloudAdministrationHTTPRegistry: GoodCloudAdministrationHTTPRegistry?
    private var goodCloudSessionIsAuthenticated = false
    private var goodCloudAssociationsByHostID: [UUID: GoodCloudAssociation] = [:]
    private var goodCloudRefreshGeneration: UInt64 = 0

    init(
        hostStore: RouterHostStore,
        credentialStore: RouterCredentialStore,
        discovery: RouterDiscovery? = nil,
        tlsPromotionHTTPFactory: @escaping TLSPromotionHTTPFactory = { endpoint in
            HTTPClient(
                baseURL: try RouterURLSessionFactory.baseURL(for: endpoint),
                session: try RouterURLSessionFactory.makeMigration(endpoint: endpoint)
            )
        },
        enrollmentClientFactory: @escaping EnrollmentClientFactory,
        transportFactory: @escaping TransportFactory,
        goodCloudAccount: GoodCloudAccountDependencies? = nil,
        goodCloudAssociations: GoodCloudAssociationStore? = nil,
        goodCloudAssociationLoader: GoodCloudAssociationLoader? = nil,
        preferredTransportFactory: PreferredTransportFactory? = nil,
        administrationHTTPFactory: @escaping RouterAdministrationClient.HTTPFactory = {
            try HTTPClient(endpoint: $0)
        },
        goodCloudAdministrationHTTPRegistry: GoodCloudAdministrationHTTPRegistry? = nil
    ) {
        self.hostStore = hostStore
        self.credentialStore = credentialStore
        self.discovery = discovery
        tlsPinPromoter = RouterTLSPinPromoter(
            hostStore: hostStore,
            credentials: credentialStore,
            httpFactory: tlsPromotionHTTPFactory
        )
        self.enrollmentClientFactory = enrollmentClientFactory
        self.transportFactory = transportFactory
        self.administrationHTTPFactory = administrationHTTPFactory
        self.goodCloudAccount = goodCloudAccount
        self.goodCloudAssociations = goodCloudAssociations
        if let goodCloudAssociationLoader {
            self.goodCloudAssociationLoader = goodCloudAssociationLoader
        } else if let goodCloudAssociations {
            self.goodCloudAssociationLoader = {
                await goodCloudAssociations.allAssociations()
            }
        } else {
            self.goodCloudAssociationLoader = nil
        }
        self.preferredTransportFactory = preferredTransportFactory
        self.goodCloudAdministrationHTTPRegistry = goodCloudAdministrationHTTPRegistry
    }

    static func production(
        defaults: UserDefaults = .standard,
        goodCloudAccountFactory: @MainActor () -> GoodCloudAccountDependencies = {
            let service = GoodCloudAccountService.production()
            return GoodCloudAccountDependencies(account: service, provisioner: service)
        },
        goodCloudAssociationStoreFactory: @MainActor () -> GoodCloudAssociationStore = {
            GoodCloudAssociationStore()
        },
        directTransportFactory: TransportFactory? = nil,
        preferredTransportFactory: PreferredTransportFactory? = nil
    ) -> RouterConnectionModel {
        let hosts = RouterHostStore(backend: UserDefaultsRouterHostBackend(defaults: defaults))
        let credentials = RouterCredentialStore(backend: KeychainRouterCredentialBackend())
        let goodCloudAccount = goodCloudAccountFactory()
        let goodCloudAssociations = goodCloudAssociationStoreFactory()
        let administrationHTTPRegistry = GoodCloudAdministrationHTTPRegistry(
            directFactory: { try HTTPClient(endpoint: $0) },
            preferredFactory: { endpoint, association, provisioner in
                let session = try RouterURLSessionFactory.make(endpoint: endpoint)
                let baseURL = try RouterURLSessionFactory.baseURL(for: endpoint)
                let coordinator = GoodCloudRelayCoordinator.production(
                    deviceID: association.goodCloudDeviceID,
                    provisioner: provisioner
                )
                let route = PreferredRouterRoute(
                    lanHTTP: HTTPClient(baseURL: baseURL, session: session),
                    lanEvents: SSEClient(baseURL: baseURL, session: session),
                    remoteHTTP: RemoteRouterHTTPClient(coordinator: coordinator),
                    remoteEvents: RemoteRouterEventStream(coordinator: coordinator)
                )
                return PreferredRouterHTTPClient(route: route)
            }
        )
        let directTransportFactory = directTransportFactory ?? { endpoint, credentials in
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
        let preferredTransportFactory = preferredTransportFactory ?? {
            endpoint, credentials, association, provisioner in
            let session = try RouterURLSessionFactory.make(endpoint: endpoint)
            let baseURL = try RouterURLSessionFactory.baseURL(for: endpoint)
            let coordinator = GoodCloudRelayCoordinator.production(
                deviceID: association.goodCloudDeviceID,
                provisioner: provisioner
            )
            let route = PreferredRouterRoute(
                lanHTTP: HTTPClient(baseURL: baseURL, session: session),
                lanEvents: SSEClient(baseURL: baseURL, session: session),
                remoteHTTP: RemoteRouterHTTPClient(coordinator: coordinator),
                remoteEvents: RemoteRouterEventStream(coordinator: coordinator)
            )
            return RouterTransport(
                endpoint: endpoint,
                accessLevel: .client,
                credentials: credentials,
                client: PreferredRouterHTTPClient(route: route),
                events: PreferredRouterEventStream(route: route),
                clock: SystemRouterConnectionClock(),
                backoff: RouterReconnectBackoff(
                    delays: [.seconds(1), .seconds(2), .seconds(5), .seconds(10)]
                )
            )
        }
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
            },
            transportFactory: directTransportFactory,
            goodCloudAccount: goodCloudAccount,
            goodCloudAssociations: goodCloudAssociations,
            preferredTransportFactory: preferredTransportFactory,
            administrationHTTPFactory: { endpoint in
                try administrationHTTPRegistry.client(for: endpoint)
            },
            goodCloudAdministrationHTTPRegistry: administrationHTTPRegistry
        )
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

    func reloadSavedHosts(refreshGoodCloudRemoteAccess shouldRefreshGoodCloud: Bool = true) async {
        savedHosts = await hostStore.hosts()
        await refreshClientCredentialAvailability(for: savedHosts)
        if shouldRefreshGoodCloud {
            await refreshGoodCloudRemoteAccess()
        }
        loadError = nil
    }

    func savedHost(matchingDeviceMAC mac: String) async -> RouterHostMetadata? {
        guard let normalizedMAC = DeviceIdentityDeduplicator.normalizedMAC(mac) else { return nil }
        let hosts = await hostStore.hosts()
        let matches = hosts.filter {
            DeviceIdentityDeduplicator.normalizedMAC($0.deviceID) == normalizedMAC
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    @discardableResult
    func refreshGoodCloudRemoteAccess() async -> Bool {
        let generation = beginGoodCloudRemoteAccessUpdate()
        guard let goodCloudAccount else {
            return clearGoodCloudRemoteAccess(ifCurrent: generation)
        }
        let state = await goodCloudAccount.account.validateStoredSession()
        return await publishGoodCloudRemoteAccess(state, generation: generation)
    }

    @discardableResult
    func publishGoodCloudRemoteAccess(_ state: GoodCloudSessionState) async -> Bool {
        let generation = beginGoodCloudRemoteAccessUpdate()
        return await publishGoodCloudRemoteAccess(state, generation: generation)
    }

    @discardableResult
    func beginGoodCloudRemoteAccessUpdate() -> UInt64 {
        goodCloudRefreshGeneration &+= 1
        return goodCloudRefreshGeneration
    }

    private func publishGoodCloudRemoteAccess(
        _ state: GoodCloudSessionState,
        generation: UInt64
    ) async -> Bool {
        guard goodCloudRefreshGeneration == generation else { return false }
        guard case .authenticated = state else {
            return clearGoodCloudRemoteAccess(ifCurrent: generation)
        }
        guard let goodCloudAccount, let goodCloudAssociationLoader else {
            return clearGoodCloudRemoteAccess(ifCurrent: generation)
        }
        let associations = await goodCloudAssociationLoader()
        guard goodCloudRefreshGeneration == generation else { return false }
        goodCloudSessionIsAuthenticated = true
        goodCloudAssociationsByHostID = Dictionary(uniqueKeysWithValues: associations.map {
            ($0.hostID, $0)
        })
        goodCloudAdministrationHTTPRegistry?.update(
            hosts: savedHosts,
            associations: associations,
            provisioner: goodCloudAccount.provisioner
        )
        return true
    }

    private func clearGoodCloudRemoteAccess(ifCurrent generation: UInt64) -> Bool {
        guard goodCloudRefreshGeneration == generation else { return false }
        goodCloudSessionIsAuthenticated = false
        goodCloudAssociationsByHostID = [:]
        goodCloudAdministrationHTTPRegistry?.update(
            hosts: savedHosts,
            associations: [],
            provisioner: nil
        )
        return true
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
            certificateFingerprint: result.endpoint.certificateFingerprint,
            tokenID: result.tokenID
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

    /// After this endpoint's managed token is revoked, remove only the client
    /// credential. The saved host and administrator credential remain intact.
    func clientCredentialLease(
        for host: RouterHostMetadata
    ) async throws -> RouterCredentialLease? {
        try await credentialStore.credentialLease(for: host.endpoint, role: .client)
    }

    func returnToEnrollment(
        _ host: RouterHostMetadata,
        ifCurrent lease: RouterCredentialLease
    ) async throws {
        let refreshVersion = beginClientCredentialAvailabilityRefresh(for: host.endpoint)
        do {
            _ = try await credentialStore.deleteToken(
                for: host.endpoint,
                role: .client,
                ifCurrent: lease
            )
            await refreshClientCredentialAvailability(
                for: host,
                version: refreshVersion
            )
        } catch {
            await refreshClientCredentialAvailability(
                for: host,
                version: refreshVersion
            )
            throw error
        }
    }

    func makeTransport(for host: RouterHostMetadata) throws -> any DeviceTransport {
        if goodCloudSessionIsAuthenticated,
           let association = goodCloudAssociationsByHostID[host.id],
           let goodCloudAccount,
           let preferredTransportFactory
        {
            return try preferredTransportFactory(
                host.endpoint,
                credentialStore,
                association,
                goodCloudAccount.provisioner
            )
        }
        return try transportFactory(host.endpoint, credentialStore)
    }

    func stageTLSCertificateFingerprint(
        _ fingerprint: String,
        for host: RouterHostMetadata
    ) async throws -> RouterHostMetadata {
        let staged = try await hostStore.stageCertificateFingerprint(
            fingerprint,
            for: host.id,
            ifCurrent: host
        )
        await reloadSavedHosts()
        return staged
    }

    func promoteStagedTLSPin(for hostID: UUID) async throws -> RouterHostMetadata {
        let promoted = try await tlsPinPromoter.promote(hostID: hostID)
        await reloadSavedHosts()
        return promoted
    }

    func promoteStagedTLSPin(
        for hostID: UUID,
        administratorToken: String
    ) async throws -> RouterHostMetadata {
        let promoted = try await tlsPinPromoter.promote(
            hostID: hostID,
            administratorToken: administratorToken
        )
        await reloadSavedHosts()
        return promoted
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
            certificateFingerprint: result.endpoint.certificateFingerprint,
            tokenID: result.tokenID
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
                preferredTransport: .bluetooth,
                routerClientCredentialAvailability: .unknown
            )
        }

        for host in savedHosts {
            let hostMAC = DeviceIdentityDeduplicator.normalizedMAC(host.deviceID)
            let matchingIndex: Int?
            if let hostMAC {
                matchingIndex = uniqueSavedHost(matchingNormalizedMAC: hostMAC)?.id == host.id
                    ? Self.uniqueRecordIndex(in: records, matchingNormalizedMAC: hostMAC)
                    : nil
            } else if let routerIdentity = routerIdentities[host.endpoint.peripheralID] {
                matchingIndex = Self.uniqueRecordIndex(in: records) { record in
                    guard let identity = record.identity else { return false }
                    return DeviceIdentityDeduplicator.merge(
                        ble: identity,
                        router: routerIdentity
                    ) != nil
                }
            } else {
                matchingIndex = nil
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
                    preferredTransport: .bluetooth,
                    routerClientCredentialAvailability: availability(for: host)
                )
            } else {
                records.append(AppDeviceConnectionRecord(
                    id: "router:\(host.id.uuidString)",
                    identity: routerIdentities[host.endpoint.peripheralID],
                    bluetoothDevice: nil,
                    discoveredRouter: nil,
                    routerHost: host,
                    transportOptions: [.router],
                    preferredTransport: .router,
                    routerClientCredentialAvailability: availability(for: host)
                ))
            }
        }
        return records
    }

    #if os(iOS)
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
                preferredTransport: .bluetooth,
                routerClientCredentialAvailability: .unknown
            )
        }

        for router in discoveredRouters {
            let routerIdentity = Self.snapshot(for: router)
            let host = uniqueSavedHost(matchingNormalizedMAC: router.deviceID)
            if let index = Self.uniqueRecordIndex(
                in: records,
                matchingNormalizedMAC: router.deviceID
            ) {
                let existing = records[index]
                records[index] = AppDeviceConnectionRecord(
                    id: existing.id,
                    identity: existing.identity,
                    bluetoothDevice: existing.bluetoothDevice,
                    discoveredRouter: router,
                    routerHost: host,
                    transportOptions: [.bluetooth, .router],
                    preferredTransport: .bluetooth,
                    routerClientCredentialAvailability: host.map(availability(for:))
                        ?? .enrollmentRequired
                )
            } else {
                records.append(AppDeviceConnectionRecord(
                    id: "router-discovered:\(router.deviceID)",
                    identity: routerIdentity,
                    bluetoothDevice: nil,
                    discoveredRouter: router,
                    routerHost: host,
                    transportOptions: [.router],
                    preferredTransport: .router,
                    routerClientCredentialAvailability: host.map(availability(for:))
                        ?? .enrollmentRequired
                ))
            }
        }

        for host in savedHosts where !records.contains(where: { $0.routerHost?.id == host.id }) {
            let hostMAC = DeviceIdentityDeduplicator.normalizedMAC(host.deviceID)
            let index = hostMAC.flatMap { normalizedMAC in
                uniqueSavedHost(matchingNormalizedMAC: normalizedMAC)?.id == host.id
                    ? Self.uniqueRecordIndex(in: records, matchingNormalizedMAC: normalizedMAC)
                    : nil
            }
            if let index {
                let existing = records[index]
                records[index] = AppDeviceConnectionRecord(
                    id: existing.id,
                    identity: existing.identity,
                    bluetoothDevice: existing.bluetoothDevice,
                    discoveredRouter: existing.discoveredRouter,
                    routerHost: host,
                    transportOptions: [.bluetooth, .router],
                    preferredTransport: .bluetooth,
                    routerClientCredentialAvailability: availability(for: host)
                )
            } else {
                records.append(AppDeviceConnectionRecord(
                    id: "router-saved:\(host.id.uuidString)",
                    identity: routerIdentities[host.endpoint.peripheralID],
                    bluetoothDevice: nil,
                    discoveredRouter: nil,
                    routerHost: host,
                    transportOptions: [.router],
                    preferredTransport: .router,
                    routerClientCredentialAvailability: availability(for: host)
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
    #endif

    private func uniqueSavedHost(matchingNormalizedMAC normalizedMAC: String?) -> RouterHostMetadata? {
        guard let normalizedMAC else { return nil }
        let matches = savedHosts.filter {
            DeviceIdentityDeduplicator.normalizedMAC($0.deviceID) == normalizedMAC
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private static func uniqueRecordIndex(
        in records: [AppDeviceConnectionRecord],
        matchingNormalizedMAC normalizedMAC: String?
    ) -> Int? {
        guard let normalizedMAC else { return nil }
        return uniqueRecordIndex(in: records) {
            DeviceIdentityDeduplicator.normalizedMAC($0.identity?.macAddress) == normalizedMAC
        }
    }

    private static func uniqueRecordIndex(
        in records: [AppDeviceConnectionRecord],
        where matches: (AppDeviceConnectionRecord) -> Bool
    ) -> Int? {
        let matchingIndices = records.indices.filter { matches(records[$0]) }
        guard matchingIndices.count == 1 else { return nil }
        return matchingIndices[0]
    }

    private func availability(for host: RouterHostMetadata) -> RouterClientCredentialAvailability {
        clientCredentialAvailability[host.endpoint.peripheralID] ?? .unknown
    }

    private func refreshClientCredentialAvailability(
        for hosts: [RouterHostMetadata]
    ) async {
        let refreshes = hosts.map { host in
            (
                host: host,
                version: beginClientCredentialAvailabilityRefresh(for: host.endpoint)
            )
        }
        var results: [(
            host: RouterHostMetadata,
            version: UInt64,
            availability: RouterClientCredentialAvailability
        )] = []
        for refresh in refreshes {
            results.append((
                host: refresh.host,
                version: refresh.version,
                availability: await readClientCredentialAvailability(
                    for: refresh.host.endpoint
                )
            ))
        }
        for result in results {
            publishClientCredentialAvailability(
                result.availability,
                for: result.host.endpoint,
                version: result.version
            )
        }
    }

    private func refreshClientCredentialAvailability(
        for host: RouterHostMetadata,
        version: UInt64
    ) async {
        let availability = await readClientCredentialAvailability(for: host.endpoint)
        publishClientCredentialAvailability(
            availability,
            for: host.endpoint,
            version: version
        )
    }

    private func beginClientCredentialAvailabilityRefresh(
        for endpoint: RouterEndpoint
    ) -> UInt64 {
        let id = endpoint.peripheralID
        clientCredentialAvailabilityVersions[id, default: 0] &+= 1
        return clientCredentialAvailabilityVersions[id, default: 0]
    }

    private func publishClientCredentialAvailability(
        _ availability: RouterClientCredentialAvailability,
        for endpoint: RouterEndpoint,
        version: UInt64
    ) {
        let id = endpoint.peripheralID
        guard clientCredentialAvailabilityVersions[id] == version else { return }
        clientCredentialAvailability[id] = availability
    }

    private func readClientCredentialAvailability(
        for endpoint: RouterEndpoint
    ) async -> RouterClientCredentialAvailability {
        do {
            return try await credentialStore.readToken(for: endpoint) == nil
                ? .enrollmentRequired
                : .available
        } catch {
            return .unknown
        }
    }

    #if os(iOS)
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
    #endif

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
