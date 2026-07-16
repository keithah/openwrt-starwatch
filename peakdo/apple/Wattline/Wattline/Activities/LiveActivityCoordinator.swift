import Foundation
import ActivityKit
import WattlineCore

protocol LiveActivityAdapter: Sendable {
    func request(state: WattlineActivityAttributes.ContentState) async throws
    func update(state: WattlineActivityAttributes.ContentState) async throws
    func end() async
}

@MainActor
final class LiveActivityCoordinator {
    private let adapter: LiveActivityAdapter
    private var policy = LiveActivityPolicy()
    private var firstDisconnectedObservedAt: Date?
    init(adapter: LiveActivityAdapter) { self.adapter = adapter }

    func consume(_ snapshot: SharedDeviceSnapshot, now: Date, preferences: LiveActivityPreferences) async {
        if snapshot.connection == .disconnected {
            if firstDisconnectedObservedAt == nil { firstDisconnectedObservedAt = snapshot.observedAt }
        } else {
            firstDisconnectedObservedAt = nil
        }
        let command = policy.evaluate(snapshot: snapshot, now: now, preferences: preferences)
        do {
            switch command {
            case .none:
                // Preserve the first disconnected observation timestamp in the activity state.
                if snapshot.connection == .disconnected { try await adapter.update(state: Self.state(from: snapshot, observedAt: firstDisconnectedObservedAt)) }
            case .start(let s), .renew(let s): try await adapter.request(state: Self.state(from: s))
            case .update(let s): try await adapter.update(state: Self.state(from: s, observedAt: firstDisconnectedObservedAt))
            case .end: await adapter.end()
            }
        } catch { /* ActivityKit is an optional presentation surface; isolate failures. */ }
    }

    private static func state(from snapshot: SharedDeviceSnapshot, observedAt: Date? = nil) -> WattlineActivityAttributes.ContentState {
        let b = snapshot.battery
        let dcOutput = snapshot.dc.flatMap { $0.isDCInput == true ? nil : $0.power } ?? 0
        let typeCOutput = snapshot.typeC.flatMap { port in
            guard port.isDCInput != true,
                  port.mode == .output || port.mode == .inputAndOutput || (port.mode == nil && port.status == .discharging) else { return nil }
            return port.power
        } ?? 0
        let watts = dcOutput + typeCOutput
        return .init(level: Int(b?.level ?? 0), status: b?.status.rawValue ?? 0, runtimeSeconds: b.map { Int($0.remainingMinutes) * 60 }, aggregateOutputWatts: watts, observedAt: observedAt ?? snapshot.observedAt, isConnected: snapshot.connection == .live)
    }
}

struct SystemLiveActivityAdapter: LiveActivityAdapter {
    func request(state: WattlineActivityAttributes.ContentState) async throws {
        _ = try Activity<WattlineActivityAttributes>.request(attributes: .init(), content: .init(state: state, staleDate: nil), pushType: nil)
    }
    func update(state: WattlineActivityAttributes.ContentState) async throws {
        for activity in Activity<WattlineActivityAttributes>.activities { await activity.update(.init(state: state, staleDate: nil)) }
    }
    func end() async {
        for activity in Activity<WattlineActivityAttributes>.activities { await activity.end(nil, dismissalPolicy: .default) }
    }
}
