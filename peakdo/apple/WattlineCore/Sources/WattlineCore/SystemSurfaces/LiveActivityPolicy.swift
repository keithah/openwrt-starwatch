import Foundation

public struct LiveActivityPreferences: Equatable, Sendable {
    public var chargingEnabled: Bool
    public var dischargingEnabled: Bool
    public init(chargingEnabled: Bool = true, dischargingEnabled: Bool = true) {
        self.chargingEnabled = chargingEnabled
        self.dischargingEnabled = dischargingEnabled
    }
}

public enum LiveActivityLifecycleState: Equatable, Sendable {
    case inactive
    case active(startedAt: Date)
    case idle(since: Date)
    case disconnected(since: Date)
}

public enum LiveActivityCommand: Equatable, Sendable {
    case none
    case start(SharedDeviceSnapshot)
    case update(SharedDeviceSnapshot)
    case end
    case renew(SharedDeviceSnapshot)
}

public struct LiveActivityPolicy: Sendable {
    public private(set) var state: LiveActivityLifecycleState = .inactive
    private var startedAt: Date?
    private var previous: SharedDeviceSnapshot?
    private static let idleEnd: TimeInterval = 5 * 60
    private static let disconnectEnd: TimeInterval = 15 * 60
    private static let renewalAt: TimeInterval = 7 * 60 * 60 + 50 * 60

    public init() {}

    public mutating func evaluate(snapshot: SharedDeviceSnapshot, now: Date, preferences: LiveActivityPreferences) -> LiveActivityCommand {
        let flow = snapshot.battery?.status
        let connected = snapshot.connection == .live

        if case .inactive = state {
            guard connected, let flow, (flow == .charging && preferences.chargingEnabled) || (flow == .discharging && preferences.dischargingEnabled) else {
                previous = snapshot
                return .none
            }
            startedAt = now
            state = .active(startedAt: now)
            previous = snapshot
            return .start(snapshot)
        }

        if !connected {
            if case .disconnected(let since) = state, now.timeIntervalSince(since) >= Self.disconnectEnd {
                state = .inactive; startedAt = nil; previous = snapshot
                return .end
            }
            let since = (state.disconnectedSince ?? now)
            state = .disconnected(since: since)
            previous = snapshot
            return .none
        }

        if flow == .idle {
            if case .idle(let since) = state, now.timeIntervalSince(since) >= Self.idleEnd {
                state = .inactive; startedAt = nil; previous = snapshot
                return .end
            }
            let since = (state.idleSince ?? now)
            state = .idle(since: since)
            previous = snapshot
            return .none
        }

        // A fresh connected, non-idle sample resumes the held activity.
        if let startedAt {
            state = .active(startedAt: startedAt)
        } else {
            state = .active(startedAt: now); startedAt = now
        }
        let material = previous.map { SnapshotMaterialChangePolicy.evaluate(previous: $0, next: snapshot, lastWidgetReloadAt: nil, now: now).persist } ?? true
        let fresh = connected && (previous == nil || snapshot.observedAt > previous!.observedAt)
        previous = snapshot
        guard material && fresh else { return .none }
        if let startedAt, now.timeIntervalSince(startedAt) >= Self.renewalAt {
            self.startedAt = now
            state = .active(startedAt: now)
            return .renew(snapshot)
        }
        return .update(snapshot)
    }
}

private extension LiveActivityLifecycleState {
    var idleSince: Date? { if case .idle(let date) = self { return date }; return nil }
    var disconnectedSince: Date? { if case .disconnected(let date) = self { return date }; return nil }
}
