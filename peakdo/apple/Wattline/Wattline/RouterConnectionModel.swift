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
    let routerHost: RouterHostMetadata?
    let transportOptions: Set<AppTransportKind>
    let preferredTransport: AppTransportKind
}

@MainActor
@Observable
final class RouterConnectionModel {
    typealias TransportFactory = @MainActor (
        _ endpoint: RouterEndpoint,
        _ credentials: any RouterCredentialProvider
    ) throws -> any DeviceTransport

    private(set) var savedHosts: [RouterHostMetadata] = []
    private(set) var loadError: String?
    private var routerIdentities: [UUID: DeviceIdentitySnapshot] = [:]

    private let hostStore: RouterHostStore
    private let credentialStore: RouterCredentialStore
    private let transportFactory: TransportFactory

    init(
        hostStore: RouterHostStore,
        credentialStore: RouterCredentialStore,
        transportFactory: @escaping TransportFactory
    ) {
        self.hostStore = hostStore
        self.credentialStore = credentialStore
        self.transportFactory = transportFactory
    }

    static func production(defaults: UserDefaults = .standard) -> RouterConnectionModel {
        let hosts = RouterHostStore(backend: UserDefaultsRouterHostBackend(defaults: defaults))
        let credentials = RouterCredentialStore(backend: KeychainRouterCredentialBackend())
        return RouterConnectionModel(
            hostStore: hosts,
            credentialStore: credentials
        ) { endpoint, credentials in
            let session = try RouterURLSessionFactory.make(endpoint: endpoint)
            let baseURL = try RouterURLSessionFactory.baseURL(for: endpoint)
            return RouterTransport(
                endpoint: endpoint,
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

    func remove(_ host: RouterHostMetadata) async throws {
        try await credentialStore.deleteToken(for: host.endpoint)
        try await hostStore.remove(id: host.id)
        await reloadSavedHosts()
    }

    func makeTransport(for host: RouterHostMetadata) throws -> any DeviceTransport {
        try transportFactory(host.endpoint, credentialStore)
    }

    func record(identity: DeviceIdentitySnapshot) {
        routerIdentities[identity.peripheralID] = identity
    }

    func records(bluetooth identities: [DeviceIdentitySnapshot]) -> [AppDeviceConnectionRecord] {
        var records = identities.map { identity in
            AppDeviceConnectionRecord(
                id: "ble:\(identity.peripheralID.uuidString)",
                identity: identity,
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
                    routerHost: host,
                    transportOptions: [.bluetooth, .router],
                    preferredTransport: .bluetooth
                )
            } else {
                records.append(AppDeviceConnectionRecord(
                    id: "router:\(host.id.uuidString)",
                    identity: routerIdentities[host.endpoint.peripheralID],
                    routerHost: host,
                    transportOptions: [.router],
                    preferredTransport: .router
                ))
            }
        }
        return records
    }

    static func capabilities(
        for identity: DeviceIdentitySnapshot,
        endpoints: Set<RouterEndpointCapability>
    ) -> DeviceCapabilities {
        var features = identity.capabilities.features
        if !endpoints.contains(.actions) {
            features.subtract([.dcControl, .usbOutputControl, .dcBypassControl, .shutdown])
        }
        if !endpoints.contains(.usbCLimit) {
            features.remove(.usbPowerLimit)
        }
        if !endpoints.contains(.schedules) {
            features.remove(.dcScheduler)
        }
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
