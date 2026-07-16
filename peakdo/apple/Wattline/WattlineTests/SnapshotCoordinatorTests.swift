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
