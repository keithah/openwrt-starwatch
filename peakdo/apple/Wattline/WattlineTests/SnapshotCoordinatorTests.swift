import Foundation
import XCTest
import WattlineCore
@testable import Wattline

@MainActor
final class SnapshotCoordinatorTests: XCTestCase {
    func testConfirmedTelemetryPersistsAndPendingMutationDoesNotChangeSnapshot() async throws {
        let backend = RecordingSnapshotBackend()
        let store = SharedSnapshotStore(backend: backend)
        let coordinator = SnapshotCoordinator(store: store, now: { Date(timeIntervalSince1970: 100) })
        let id = UUID()
        let identity = DeviceIdentitySnapshot(peripheralID: id, advertisedName: "Demo", mode: .application, rawFeatures: 7, capabilities: DeviceCapabilities(features: []))
        let battery = try! BatteryStatus(frame: Data(repeating: 0, count: 16))
        let state = DeviceState(identity: identity, connection: .live, freshness: .live, battery: battery)
        _ = await coordinator.receive(state: state, identity: identity, capabilities: identity.capabilities, generation: 1)
        await coordinator.flushPendingWrites()
        let persisted = await store.read()
        XCTAssertNotNil(persisted)
        let writesAfterTelemetry = await backend.writeCount

        var pending = state
        pending.pendingMutations = [PendingMutation(id: UUID(), reconciler: .dcEnabled(false), startedAt: .zero, timeout: .seconds(3))]
        _ = await coordinator.receive(state: pending, identity: identity, capabilities: identity.capabilities, generation: 1)
        await coordinator.flushPendingWrites()
        let pendingWrites = await backend.writeCount
        XCTAssertEqual(pendingWrites, writesAfterTelemetry, "pending control state must not persist a snapshot")
    }

    func testStaleGenerationIsIgnoredAndStatusFlipFansOut() async throws {
        let backend = RecordingSnapshotBackend()
        let store = SharedSnapshotStore(backend: backend)
        let now = Date(timeIntervalSince1970: 100)
        let coordinator = SnapshotCoordinator(store: store, now: { now })
        let id = UUID()
        let identity = DeviceIdentitySnapshot(peripheralID: id, advertisedName: nil, mode: .application, capabilities: DeviceCapabilities(features: []))
        let first = DeviceState(identity: identity, connection: .live, freshness: .live)
        _ = await coordinator.receive(state: first, identity: identity, capabilities: identity.capabilities, generation: 2)
        await coordinator.flushPendingWrites()
        let stale = DeviceState(identity: identity, connection: .disconnected, freshness: .stale)
        let staleEvent = await coordinator.receive(state: stale, identity: identity, capabilities: identity.capabilities, generation: 1)
        XCTAssertNil(staleEvent)
        let writes = await backend.writeCount
        XCTAssertEqual(writes, 1)
    }

    func testDemoModeNeverWritesInjectedStoreAndEntitlementDeclaresGroup() async throws {
        let backend = RecordingSnapshotBackend()
        let store = SharedSnapshotStore(backend: backend)
        let coordinator = SnapshotCoordinator(store: store, now: Date.init, isDemo: true)
        let id = UUID()
        let identity = DeviceIdentitySnapshot(peripheralID: id, advertisedName: nil, mode: .application, capabilities: DeviceCapabilities(features: []))
        _ = await coordinator.receive(state: DeviceState(identity: identity), identity: identity, capabilities: identity.capabilities, generation: 1)
        await coordinator.flushPendingWrites()
        let writes = await backend.writeCount
        XCTAssertEqual(writes, 0)
        let entitlement = try String(contentsOfFile: "Wattline/Wattline.entitlements")
        XCTAssertTrue(entitlement.contains("group.com.keithah.wattline"))
    }

    func testAppModelAcceptedStatePersistsButPendingControlStateDoesNot() async throws {
        let backend = RecordingSnapshotBackend()
        let store = SharedSnapshotStore(backend: backend)
        let coordinator = Wattline.SnapshotCoordinator(store: store, now: { Date(timeIntervalSince1970: 200) })
        let persistence = AppPersistence(defaults: UserDefaults(suiteName: "SnapshotCoordinator-\(UUID().uuidString)")!)
        let model = AppModel(persistence: persistence, snapshotCoordinator: coordinator)
        let id = UUID()
        let identity = DeviceIdentitySnapshot(peripheralID: id, advertisedName: "Demo", mode: .application, rawFeatures: 7, capabilities: DeviceCapabilities(features: []))
        let accepted = DeviceState(identity: identity, connection: .live, freshness: .live)
        model.applySessionState(accepted)
        try await Task.sleep(for: .milliseconds(30))
        let acceptedWrites = await backend.writeCount
        XCTAssertEqual(acceptedWrites, 1, "accepted session telemetry must reach the coordinator")

        var pending = accepted
        pending.pendingMutations = [PendingMutation(id: UUID(), reconciler: .dcEnabled(false), startedAt: .zero, timeout: .seconds(3))]
        model.applySessionState(pending)
        try await Task.sleep(for: .milliseconds(30))
        let pendingWrites = await backend.writeCount
        XCTAssertEqual(pendingWrites, 1, "control/pending state must not write a snapshot")
    }

    func testAppModelUsesProductionAppGroupSnapshotCoordinatorByDefault() {
        let defaults = UserDefaults(suiteName: "ProductionSnapshotCoordinator-\(UUID().uuidString)")!
        let persistence = AppPersistence(defaults: defaults)
        let model = AppModel(persistence: persistence, transportFactory: { DemoTransport(seed: 1) })
        XCTAssertTrue(model.hasSnapshotCoordinatorForTesting)
    }

    func testAppModelAppliesWidgetReloadDecisionForAcceptedTelemetry() async throws {
        let backend = RecordingSnapshotBackend()
        let coordinator = Wattline.SnapshotCoordinator(store: SharedSnapshotStore(backend: backend), now: { Date(timeIntervalSince1970: 200) })
        var reloads = 0
        let adapter = Wattline.WidgetReloadAdapter { reloads += 1 }
        let model = AppModel(persistence: AppPersistence(defaults: UserDefaults(suiteName: "WidgetReload-\(UUID().uuidString)!")!), snapshotCoordinator: coordinator, widgetReloadAdapter: adapter)
        let id = UUID()
        let identity = DeviceIdentitySnapshot(peripheralID: id, advertisedName: "Demo", mode: .application, capabilities: DeviceCapabilities(features: []))
        model.applySessionState(DeviceState(identity: identity, connection: .live, freshness: .live))
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(reloads, 1)
    }

    func testAppModelFansOutAcceptedSnapshotToLiveActivityCoordinator() async throws {
        let backend = RecordingSnapshotBackend()
        let coordinator = Wattline.SnapshotCoordinator(store: SharedSnapshotStore(backend: backend), now: { Date(timeIntervalSince1970: 200) })
        let activity = SnapshotActivityAdapter()
        let model = AppModel(
            persistence: AppPersistence(defaults: UserDefaults(suiteName: "ActivityFanout-\(UUID().uuidString)")!),
            snapshotCoordinator: coordinator,
            liveActivityAdapter: activity
        )
        let id = UUID()
        let identity = DeviceIdentitySnapshot(peripheralID: id, advertisedName: "Demo", mode: .application, capabilities: DeviceCapabilities(features: []))
        let battery = try BatteryStatus(frame: batteryFrame(level: 80, status: .charging))
        model.applySessionState(DeviceState(identity: identity, connection: .live, freshness: .live, battery: battery))
        try await Task.sleep(for: .milliseconds(80))
        model.applySessionState(DeviceState(identity: identity, connection: .live, freshness: .live, battery: try BatteryStatus(frame: batteryFrame(level: 79, status: .charging))))
        try await Task.sleep(for: .milliseconds(80))
        let events = await activity.events
        XCTAssertEqual(events.map(\.0), [.request, .update])
    }

    func testDashboardDeepLinkSelectsConnectedRouteAndInfoPlistRegistersScheme() throws {
        let defaults = UserDefaults(suiteName: "DeepLink-\(UUID().uuidString)")!
        let persistence = AppPersistence(defaults: defaults)
        // Deep links are only actionable after onboarding; exercise the connected-capable route.
        persistence.onboardingComplete = true
        let model = AppModel(persistence: persistence, snapshotCoordinator: nil)
        model.handleDeepLink(URL(string: "wattline://dashboard")!)
        XCTAssertEqual(model.route, .connected)
        let plist = try String(contentsOfFile: "Wattline/Info.plist")
        XCTAssertTrue(plist.contains("<string>wattline</string>"))
    }
}

private func batteryFrame(level: UInt8, status: PowerFlow) -> Data {
    var frame = Data(repeating: 0, count: 16)
    frame[0] = 1
    frame[1] = UInt8(bitPattern: status.rawValue)
    frame[7] = level
    return frame
}

private actor SnapshotActivityAdapter: LiveActivityAdapter {
    enum Event: Equatable { case request, update, end }
    private(set) var events: [(Event, WattlineActivityAttributes.ContentState?)] = []
    func request(state: WattlineActivityAttributes.ContentState) async throws { events.append((.request, state)) }
    func update(state: WattlineActivityAttributes.ContentState) async throws { events.append((.update, state)) }
    func end() async { events.append((.end, nil)) }
}

private final class RecordingSnapshotBackend: @unchecked Sendable, SnapshotKeyValueStore {
    private let lock = NSLock()
    private var writes = 0
    private var values: [String: Data] = [:]
    var writeCount: Int { lock.lock(); defer { lock.unlock() }; return writes }
    func data(forKey key: String) -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func set(_ data: Data, forKey key: String) { lock.lock(); defer { lock.unlock() }; writes += 1; values[key] = data }
    func removeValue(forKey key: String) { lock.lock(); defer { lock.unlock() }; values[key] = nil }
}
