import Foundation
import WattlineCore

/// Fan-out produced when accepted telemetry changes a shared snapshot.
struct SnapshotFanOutEvent: Equatable, Sendable {
    let snapshot: SharedDeviceSnapshot
    let decision: SnapshotFanOutDecision
}

/// Main-actor reducer between the sole BLE owner and read-only system surfaces.
@MainActor
final class SnapshotCoordinator {
    private let store: SharedSnapshotStore
    private let now: @Sendable () -> Date
    private let isDemo: Bool
    private var generation: UInt = 0
    private var previous: SharedDeviceSnapshot?
    private var pending: SharedDeviceSnapshot?
    private var lastWidgetReloadAt: Date?

    init(store: SharedSnapshotStore, now: @escaping @Sendable () -> Date = Date.init, isDemo: Bool = false) {
        self.store = store
        self.now = now
        self.isDemo = isDemo
    }

    func receive(
        state: DeviceState,
        identity: DeviceIdentitySnapshot?,
        capabilities: DeviceCapabilities,
        generation: UInt
    ) async -> SnapshotFanOutEvent? {
        guard generation >= self.generation else { return nil }
        self.generation = generation
        // Pending mutations are presentation state, never authoritative telemetry.
        guard state.pendingMutations.isEmpty else { return nil }
        guard let identity else { return nil }
        let timestamp = now()
        let snapshot = SharedDeviceSnapshot(
            peripheralID: identity.peripheralID,
            featuresRawValue: identity.rawFeatures ?? capabilities.features.rawValue,
            battery: state.battery.map { SharedBatterySnapshot(enabled: $0.enabled, status: $0.status, isFull: $0.isFull, maxCapacity: $0.maxCapacity, capacity: $0.capacity, level: $0.level, voltage: $0.voltage, current: $0.current, power: $0.power, remainingMinutes: $0.remainingMinutes) },
            dc: state.dc.map { SharedPortSnapshot(enabled: $0.enabled, status: $0.status, voltage: $0.voltage, current: $0.current, power: $0.power, bypassOn: $0.bypassOn) },
            typeC: state.typeC.map { SharedPortSnapshot(enabled: $0.enabled, status: $0.status, voltage: $0.voltage, current: $0.current, power: $0.power, mode: $0.mode, isDCInput: $0.isDCInput) },
            connection: state.connection.sharedSnapshotState,
            observedAt: timestamp
        )
        // Compare against the coalesced candidate when several channel callbacks arrive
        // in one run-loop turn. This keeps one material decision and one eventual write.
        let comparison = pending ?? previous
        let decision = SnapshotMaterialChangePolicy.evaluate(previous: comparison, next: snapshot, lastWidgetReloadAt: lastWidgetReloadAt, now: timestamp)
        guard decision.persist else { return SnapshotFanOutEvent(snapshot: snapshot, decision: decision) }
        pending = snapshot
        if decision.reloadWidgets { lastWidgetReloadAt = timestamp }
        return SnapshotFanOutEvent(snapshot: snapshot, decision: decision)
    }

    /// Flushes the coalesced battery/DC/Type-C burst as one encoded store write.
    func flushPendingWrites() async {
        guard let snapshot = pending else { return }
        pending = nil
        previous = snapshot
        guard !isDemo else { return }
        try? await store.write(snapshot)
    }
}

private extension DeviceConnectionState {
    var sharedSnapshotState: SharedConnectionState {
        switch self {
        case .loading: .loading
        case .live: .live
        case .disconnected: .disconnected
        case .reconnecting: .reconnecting
        }
    }
}
