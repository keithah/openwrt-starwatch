import Foundation
import WattlineCore
import WattlineNetwork
import XCTest
@testable import Wattline

@MainActor
final class RouterAppWiringTests: XCTestCase {
    func testTransportLabelsAreExplicitAndStable() {
        XCTAssertEqual(AppTransportKind.bluetooth.label, "BT")
        XCTAssertEqual(AppTransportKind.router.label, "Router")
        XCTAssertEqual(AppTransportKind.demo.label, "Demo")
    }

    func testRouterAndBluetoothRecordsWithTheSameMACAreOneBluetoothPreferredDevice() async throws {
        let fixture = makeFixture()
        let sharedHost = try host(name: "Kitchen router", address: "192.168.8.1:8377", mac: "dc-04-5a-eb-72-2b")
        let otherHost = try host(name: "Cabin router", address: "router.tailnet.ts.net:8377", reachability: .vpn, mac: "AA:BB:CC:DD:EE:FF")
        try await fixture.hostStore.save(sharedHost)
        try await fixture.hostStore.save(otherHost)
        await fixture.model.reloadSavedHosts()

        let records = fixture.model.records(bluetooth: [identity(mac: "DC:04:5A:EB:72:2B", cid: 0x0302)])

        XCTAssertEqual(records.count, 2)
        let merged = try XCTUnwrap(records.first { $0.transportOptions == [.bluetooth, .router] })
        XCTAssertEqual(merged.preferredTransport, .bluetooth)
        XCTAssertEqual(merged.routerHost?.id, sharedHost.id)
        XCTAssertEqual(records.first { $0.routerHost?.id == otherHost.id }?.transportOptions, [.router])
    }

    func testRouterEndpointCapabilitiesRemoveUnsupportedSurfacesStructurally() {
        let resolved = RouterConnectionModel.capabilities(
            for: identity(mac: "DC:04:5A:EB:72:2B", cid: 0x0302),
            endpoints: [.actions]
        )

        XCTAssertTrue(resolved.hasDCControl)
        XCTAssertTrue(resolved.hasUSBOutputControl)
        XCTAssertFalse(resolved.hasPowerLimits)
        XCTAssertFalse(resolved.hasScheduler)
    }

    func testManualHostPersistsMetadataAndStoresBearerTokenOnlyInCredentialStore() async throws {
        let fixture = makeFixture()

        let saved = try await fixture.model.saveManualHost(
            address: "router.tailnet.ts.net:8377",
            displayName: "Travel router",
            reachability: .vpn,
            allowsInsecureWAN: false,
            deviceID: "DC:04:5A:EB:72:2B",
            certificateFingerprint: nil,
            token: "secret-bearer"
        )

        XCTAssertEqual(fixture.model.savedHosts, [saved])
        XCTAssertFalse(String(data: try XCTUnwrap(fixture.hostBackend.storedData), encoding: .utf8)?.contains("secret-bearer") == true)
        let savedToken = await fixture.credentialBackend.savedToken
        XCTAssertEqual(savedToken, "secret-bearer")
    }

    func testRouterSelectionCreatesNoBluetoothOwnerAndUsesOnlyTheSelectedRouterTransport() async throws {
        let transport = RouterSelectionTransport(identity: identity(mac: "DC:04:5A:EB:72:2B", cid: 0x0302))
        var routerFactoryCount = 0
        var bluetoothFactoryCount = 0
        let fixture = makeFixture { _, _ in
            routerFactoryCount += 1
            return transport
        }
        let persistence = testPersistence()
        let model = AppModel(
            persistence: persistence,
            transportFactory: {
                bluetoothFactoryCount += 1
                return RouterSelectionTransport(identity: self.identity(mac: nil, cid: nil))
            },
            snapshotCoordinator: nil,
            widgetReloadAdapter: nil,
            liveActivityAdapter: RouterNoopLiveActivityAdapter(),
            routerConnections: fixture.model
        )
        let saved = try await fixture.model.saveManualHost(
            address: "192.168.8.1:8377",
            displayName: "Router",
            reachability: .lan,
            allowsInsecureWAN: false,
            deviceID: "DC:04:5A:EB:72:2B",
            certificateFingerprint: nil,
            token: "token"
        )

        model.connectViaRouter(saved)
        try await waitUntil { await transport.connectCount == 1 }

        XCTAssertEqual(model.activeTransportKind, .router)
        XCTAssertEqual(routerFactoryCount, 1)
        XCTAssertEqual(bluetoothFactoryCount, 0, "manual router selection must not instantiate CBCentralManager/BLETransport")
        let connectCount = await transport.connectCount
        XCTAssertEqual(connectCount, 1)
    }

    private func makeFixture(
        transportFactory: @escaping RouterConnectionModel.TransportFactory = { _, _ in
            RouterSelectionTransport(identity: RouterAppWiringTests.identity(mac: nil, cid: nil))
        }
    ) -> RouterFixture {
        let hostBackend = RouterHostMemoryBackend()
        let credentialBackend = RouterCredentialMemoryBackend()
        let hostStore = RouterHostStore(backend: hostBackend)
        let credentialStore = RouterCredentialStore(backend: credentialBackend)
        return RouterFixture(
            model: RouterConnectionModel(
                hostStore: hostStore,
                credentialStore: credentialStore,
                transportFactory: transportFactory
            ),
            hostStore: hostStore,
            hostBackend: hostBackend,
            credentialBackend: credentialBackend
        )
    }

    private func host(
        name: String,
        address: String,
        reachability: RouterHostReachability = .lan,
        mac: String
    ) throws -> RouterHostMetadata {
        try RouterHostValidator.validate(
            address,
            displayName: name,
            reachability: reachability,
            allowsInsecureWAN: false,
            deviceID: mac,
            certificateFingerprint: nil
        )
    }

    nonisolated private static func identity(mac: String?, cid: UInt16?) -> DeviceIdentitySnapshot {
        let features: FeatureFlags = [
            .batteryCapacity, .dcPort, .dcControl, .dcScheduler,
            .usbPort, .usbPowerLimit, .usbOutputControl, .shutdown,
        ]
        return DeviceIdentitySnapshot(
            peripheralID: UUID(),
            advertisedName: "Link-Power",
            mode: .application,
            modelNumber: "BP4SL3V2",
            hardwareRevision: "2.1",
            otaFirmwareRevision: nil,
            appFirmwareRevision: "1.4.9",
            cid: cid,
            rawFeatures: features.rawValue,
            macAddress: mac,
            capabilities: DeviceCapabilities(features: features)
        )
    }

    private func identity(mac: String?, cid: UInt16?) -> DeviceIdentitySnapshot {
        Self.identity(mac: mac, cid: cid)
    }

    private func testPersistence() -> AppPersistence {
        let suite = "RouterAppWiringTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppPersistence(defaults: defaults)
    }
}

private struct RouterFixture {
    let model: RouterConnectionModel
    let hostStore: RouterHostStore
    let hostBackend: RouterHostMemoryBackend
    let credentialBackend: RouterCredentialMemoryBackend
}

private final class RouterHostMemoryBackend: RouterHostKeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    var storedData: Data? { lock.withLock { data } }
    func data(forKey key: String) -> Data? { storedData }
    func set(_ data: Data, forKey key: String) { lock.withLock { self.data = data } }
    func removeValue(forKey key: String) { lock.withLock { data = nil } }
}

private actor RouterCredentialMemoryBackend: RouterCredentialBackend {
    private var data: Data?
    var savedToken: String? { data.flatMap { String(data: $0, encoding: .utf8) } }
    func read(account: String) async throws -> Data? { data }
    func save(_ data: Data, account: String) async throws { self.data = data }
    func delete(account: String) async throws { data = nil }
}

private actor RouterSelectionTransport: DeviceTransport {
    nonisolated let events: AsyncStream<DeviceEvent>
    private let continuation: AsyncStream<DeviceEvent>.Continuation
    private let identity: DeviceIdentitySnapshot
    private(set) var connectCount = 0

    init(identity: DeviceIdentitySnapshot) {
        self.identity = identity
        let pair = AsyncStream<DeviceEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    func startScan() async throws {}
    func stopScan() async {}
    func makeConnectionScope(for id: UUID) async -> DeviceConnectionScope {
        DeviceConnectionScope(peripheralID: id, sessionID: UUID())
    }
    func connect(to id: UUID, scope: DeviceConnectionScope) async throws {
        connectCount += 1
        let snapshot = DeviceIdentitySnapshot(
            peripheralID: id,
            advertisedName: identity.advertisedName,
            mode: identity.mode,
            modelNumber: identity.modelNumber,
            hardwareRevision: identity.hardwareRevision,
            otaFirmwareRevision: identity.otaFirmwareRevision,
            appFirmwareRevision: identity.appFirmwareRevision,
            cid: identity.cid,
            rawFeatures: identity.rawFeatures,
            macAddress: identity.macAddress,
            capabilities: identity.capabilities
        )
        continuation.yield(.handshakeCompleted(snapshot, scope: scope))
        continuation.yield(.connected(scope))
    }
    func disconnect() async {}
    func perform(_ command: DeviceCommand) async throws -> CommandOutcome { .sent }
    func refreshTelemetry() async throws {}
    func synchronizeDeviceTime() async throws {}
    func readDeviceTimeIfSupported() async throws -> Date? { nil }
}

private struct RouterNoopLiveActivityAdapter: LiveActivityAdapter {
    func request(state: WattlineActivityAttributes.ContentState) async throws {}
    func update(state: WattlineActivityAttributes.ContentState) async throws {}
    func end() async {}
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
