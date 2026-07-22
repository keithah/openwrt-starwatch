import Foundation
import WattlineCore
import WattlineNetwork
import XCTest
@testable import Wattline

@MainActor
final class RouterDiscoveryLifecycleTests: XCTestCase {
    func testScanLifecycleStartsOnceStopsOnExitAndRejectsOldSessionResults() async throws {
        let source = RecordingRouterDiscoverySource()
        let model = makeModel(discovery: RouterDiscovery(source: source))

        model.startDiscovery()
        model.startDiscovery()
        try await waitUntil { source.startCount == 1 }

        model.stopDiscovery()
        try await waitUntil { source.cancelCount == 1 }
        source.yield([serviceRecord(id: "DC:04:5A:EB:72:2B")], session: 0)
        await Task.yield()
        XCTAssertTrue(model.discoveredRouters.isEmpty)

        model.startDiscovery()
        try await waitUntil { source.startCount == 2 }
        source.yield([serviceRecord(id: "AA:BB:CC:DD:EE:FF")], session: 1)
        try await waitUntil { await model.discoveredRouters.count == 1 }
        XCTAssertEqual(model.discoveredRouters.first?.deviceID, "AABBCCDDEEFF")

        source.yield([serviceRecord(id: "DC:04:5A:EB:72:2B")], session: 0)
        await Task.yield()
        XCTAssertEqual(model.discoveredRouters.first?.deviceID, "AABBCCDDEEFF")
    }

    func testLiveRouterAndKnownBluetoothDeviceProduceOneBluetoothPreferredScanRecord() async throws {
        let source = RecordingRouterDiscoverySource()
        let model = makeModel(discovery: RouterDiscovery(source: source))
        let bluetoothID = UUID()
        let bluetooth = DiscoveredDevice(
            id: bluetoothID,
            localName: "Link-Power",
            rssi: -42,
            mode: .application
        )
        let cached = AppModel.CachedIdentity(
            advertisedName: "Link-Power",
            deviceInformationName: "Link-Power 2",
            macAddress: "dc-04-5a-eb-72-2b",
            cid: 0x0305,
            rawFeatures: 0x0000_0fff
        )

        model.startDiscovery()
        try await waitUntil { source.startCount == 1 }
        source.yield([serviceRecord(id: "DC:04:5A:EB:72:2B")], session: 0)
        try await waitUntil { await model.discoveredRouters.count == 1 }

        let records = model.scanRecords(
            bluetooth: [bluetooth],
            identities: [bluetoothID: cached]
        )

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].bluetoothDevice, bluetooth)
        XCTAssertEqual(records[0].discoveredRouter?.deviceID, "DC045AEB722B")
        XCTAssertEqual(records[0].transportOptions, [.bluetooth, .router])
        XCTAssertEqual(records[0].preferredTransport, .bluetooth)
        let presentation = ScanRecordPresentation(record: records[0])
        XCTAssertEqual(presentation.primaryAction, .connectBluetooth)
        XCTAssertTrue(presentation.offersRouterAction)
        XCTAssertEqual(presentation.transportLabels, ["BT", "Router"])
    }

    func testIdentitylessBluetoothDeviceAndDiscoveredRouterRemainDistinct() async throws {
        let source = RecordingRouterDiscoverySource()
        let model = makeModel(discovery: RouterDiscovery(source: source))
        let bluetooth = DiscoveredDevice(
            id: UUID(),
            localName: "Unidentified Link-Power",
            rssi: -38,
            mode: .application
        )

        model.startDiscovery()
        try await waitUntil { source.startCount == 1 }
        source.yield([serviceRecord(id: "DC:04:5A:EB:72:2B")], session: 0)
        try await waitUntil { await model.discoveredRouters.count == 1 }

        let records = model.scanRecords(bluetooth: [bluetooth], identities: [:])

        XCTAssertEqual(records.count, 2)
        let bluetoothRecord = try XCTUnwrap(records.first { $0.bluetoothDevice == bluetooth })
        XCTAssertEqual(bluetoothRecord.transportOptions, [.bluetooth])
        XCTAssertNil(bluetoothRecord.discoveredRouter)
        XCTAssertEqual(ScanRecordPresentation(record: bluetoothRecord).primaryAction, .connectBluetooth)

        let routerRecord = try XCTUnwrap(records.first { $0.discoveredRouter != nil })
        XCTAssertNil(routerRecord.bluetoothDevice)
        XCTAssertEqual(routerRecord.transportOptions, [.router])
        XCTAssertEqual(ScanRecordPresentation(record: routerRecord).primaryAction, .enrollRouter)
    }

    func testNaturalDiscoveryFinishPublishesErrorAndAllowsRestart() async throws {
        let source = RecordingRouterDiscoverySource()
        let model = makeModel(discovery: RouterDiscovery(source: source))

        model.startDiscovery()
        try await waitUntil { source.startCount == 1 }
        source.finish(session: 0)

        try await waitUntil { await model.discoveryError != nil }
        model.startDiscovery()
        try await waitUntil { source.startCount == 2 }
        XCTAssertNil(model.discoveryError)
    }

    func testStopDiscoveryClearsResultsAndError() async throws {
        let source = RecordingRouterDiscoverySource()
        let model = makeModel(discovery: RouterDiscovery(source: source))

        model.startDiscovery()
        try await waitUntil { source.startCount == 1 }
        source.yield([serviceRecord(id: "DC:04:5A:EB:72:2B")], session: 0)
        try await waitUntil { await model.discoveredRouters.count == 1 }
        source.finish(session: 0)
        try await waitUntil { await model.discoveryError != nil }

        model.stopDiscovery()

        XCTAssertTrue(model.discoveredRouters.isEmpty)
        XCTAssertNil(model.discoveryError)
    }

    func testStaleGenerationFinishCannotPublishErrorIntoReplacementSession() async throws {
        let source = RecordingRouterDiscoverySource()
        let model = makeModel(discovery: RouterDiscovery(source: source))

        model.startDiscovery()
        try await waitUntil { source.startCount == 1 }
        model.stopDiscovery()
        model.startDiscovery()
        try await waitUntil { source.startCount == 2 }

        source.finish(session: 0)
        source.yield([serviceRecord(id: "AA:BB:CC:DD:EE:FF")], session: 1)
        try await waitUntil { await model.discoveredRouters.count == 1 }

        XCTAssertNil(model.discoveryError)
        XCTAssertEqual(model.discoveredRouters.first?.deviceID, "AABBCCDDEEFF")
    }

    func testRouterOnlyDiscoveryPresentsEnrollmentAsPrimaryAction() async throws {
        let source = RecordingRouterDiscoverySource()
        let model = makeModel(discovery: RouterDiscovery(source: source))
        model.startDiscovery()
        try await waitUntil { source.startCount == 1 }
        source.yield([serviceRecord(id: "DC:04:5A:EB:72:2B")], session: 0)
        try await waitUntil { await model.discoveredRouters.count == 1 }

        let record = try XCTUnwrap(model.scanRecords(bluetooth: [], identities: [:]).first)
        let presentation = ScanRecordPresentation(record: record)

        XCTAssertEqual(presentation.title, "wattline-DC:04:5A:EB:72:2B")
        XCTAssertEqual(presentation.primaryAction, .enrollRouter)
        XCTAssertFalse(presentation.offersRouterAction)
        XCTAssertEqual(presentation.transportLabels, ["Router"])
    }

    func testBonjourLifecycleDoesNotCallGoodCloudOrChangeSavedLANRecords() async throws {
        let source = RecordingRouterDiscoverySource()
        let accountClient = DiscoveryGoodCloudClient()
        let account = GoodCloudAccountService.accountOnly(client: accountClient)
        let associationStore = GoodCloudAssociationStore(
            backend: DiscoveryAssociationBackend()
        )
        let hostStore = RouterHostStore(backend: DiscoveryHostBackend())
        let saved = try RouterHostValidator.validate(
            "192.168.8.1:8377",
            displayName: "Saved LAN router",
            reachability: .lan,
            allowsInsecureWAN: false,
            deviceID: "DC:04:5A:EB:72:2B",
            certificateFingerprint: nil
        )
        try await hostStore.save(saved)
        let model = RouterConnectionModel(
            hostStore: hostStore,
            credentialStore: RouterCredentialStore(backend: DiscoveryCredentialBackend()),
            discovery: RouterDiscovery(source: source),
            enrollmentClientFactory: { _ in
                throw NetworkError.unsupported("not used")
            },
            transportFactory: { _, _ in DiscoveryNoopTransport() },
            goodCloudAccount: .init(account: account, provisioner: account),
            goodCloudAssociations: associationStore
        )
        await model.reloadSavedHosts()
        let validationCountBeforeDiscovery = await accountClient.validationCount

        model.startDiscovery()
        try await waitUntil { source.startCount == 1 }
        model.stopDiscovery()
        try await waitUntil { source.cancelCount == 1 }

        let validationCountAfterDiscovery = await accountClient.validationCount
        XCTAssertEqual(validationCountBeforeDiscovery, 1)
        XCTAssertEqual(validationCountAfterDiscovery, validationCountBeforeDiscovery)
        XCTAssertEqual(model.savedHosts, [saved])
    }

    private func makeModel(discovery: RouterDiscovery) -> RouterConnectionModel {
        RouterConnectionModel(
            hostStore: RouterHostStore(backend: DiscoveryHostBackend()),
            credentialStore: RouterCredentialStore(backend: DiscoveryCredentialBackend()),
            discovery: discovery,
            enrollmentClientFactory: { _ in
                throw NetworkError.unsupported("not used")
            },
            transportFactory: { _, _ in DiscoveryNoopTransport() }
        )
    }

    private func serviceRecord(id: String) -> RouterServiceRecord {
        RouterServiceRecord(
            serviceName: "wattline-\(id)",
            domain: "local.",
            host: "wattline.local.",
            port: 8377,
            txt: [
                "api": Data("1".utf8),
                "auth": Data("pin".utf8),
                "id": Data(id.utf8),
                "model": Data("BP4SL3V2".utf8),
                "cid": Data("0305".utf8),
                "features": Data("00000fff".utf8),
                "tls": Data("none".utf8),
            ]
        )
    }
}

private final class RecordingRouterDiscoverySource: RouterDiscoverySource, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncStream<[RouterServiceRecord]>.Continuation] = []
    private var starts = 0
    private var cancels = 0

    var startCount: Int { lock.withLock { starts } }
    var cancelCount: Int { lock.withLock { cancels } }

    func snapshots(serviceType: String) -> AsyncStream<[RouterServiceRecord]> {
        AsyncStream { continuation in
            lock.withLock {
                starts += 1
                continuations.append(continuation)
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.cancels += 1 }
            }
        }
    }

    func yield(_ records: [RouterServiceRecord], session: Int) {
        lock.withLock {
            guard continuations.indices.contains(session) else { return }
            continuations[session].yield(records)
        }
    }

    func finish(session: Int) {
        let continuation = lock.withLock {
            continuations.indices.contains(session) ? continuations[session] : nil
        }
        continuation?.finish()
    }
}

private final class DiscoveryHostBackend: RouterHostKeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(forKey key: String) -> Data? { lock.withLock { values[key] } }
    func set(_ data: Data, forKey key: String) throws { lock.withLock { values[key] = data } }
    func removeValue(forKey key: String) { lock.withLock { values[key] = nil } }
}

private actor DiscoveryGoodCloudClient: GoodCloudAccountClient {
    private(set) var validationCount = 0

    func hasStoredToken() async -> Bool {
        validationCount += 1
        return false
    }

    func login(email: String, password: String) async throws {}
    func devices() async throws -> [GoodCloudDeviceSummary] { [] }
    func logout() async throws {}
}

private final class DiscoveryAssociationBackend: GoodCloudAssociationKeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(forKey key: String) -> Data? { lock.withLock { values[key] } }
    func set(_ data: Data?, forKey key: String) { lock.withLock { values[key] = data } }
}

private actor DiscoveryCredentialBackend: RouterCredentialBackend {
    func read(account: String) async throws -> Data? { nil }
    func save(_ data: Data, account: String) async throws {}
    func delete(account: String) async throws {}
}

private actor DiscoveryNoopTransport: DeviceTransport {
    nonisolated let events = AsyncStream<DeviceEvent> { $0.finish() }
    func startScan() async throws {}
    func stopScan() async {}
    func makeConnectionScope(for id: UUID) async -> DeviceConnectionScope {
        DeviceConnectionScope(peripheralID: id, sessionID: UUID())
    }
    func connect(to id: UUID, scope: DeviceConnectionScope) async throws {}
    func disconnect() async {}
    func perform(_ command: DeviceCommand) async throws -> CommandOutcome { .sent }
    func refreshTelemetry() async throws {}
    func synchronizeDeviceTime() async throws {}
    func readDeviceTimeIfSupported() async throws -> Date? { nil }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
