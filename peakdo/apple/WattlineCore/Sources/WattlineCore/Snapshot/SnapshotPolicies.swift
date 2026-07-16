import Foundation

public struct SnapshotFanOutDecision: Equatable, Sendable {
    public let persist: Bool
    public let updateActivity: Bool
    public let reloadWidgets: Bool

    public init(persist: Bool, updateActivity: Bool, reloadWidgets: Bool) {
        self.persist = persist
        self.updateActivity = updateActivity
        self.reloadWidgets = reloadWidgets
    }
}

public enum SnapshotMaterialChangePolicy {
    private static let widgetReloadInterval: TimeInterval = 15 * 60

    public static func evaluate(previous: SharedDeviceSnapshot?, next: SharedDeviceSnapshot, lastWidgetReloadAt: Date?, now: Date) -> SnapshotFanOutDecision {
        guard let previous else { return SnapshotFanOutDecision(persist: true, updateActivity: true, reloadWidgets: true) }

        let batteryChanged: Bool = {
            guard let a = previous.battery, let b = next.battery else { return previous.battery != nil || next.battery != nil }
            return a.level != b.level
        }()
        let statusChanged = previous.battery?.status != next.battery?.status
        let connectionChanged = previous.connection != next.connection
        let dcStateChanged = portStateChanged(previous.dc, next.dc)
        let typeCStateChanged = portStateChanged(previous.typeC, next.typeC)
        let powerChanged = materialPowerChanged(previous.dc?.power, next.dc?.power) || materialPowerChanged(previous.typeC?.power, next.typeC?.power)
        let material = batteryChanged || statusChanged || connectionChanged || dcStateChanged || typeCStateChanged || powerChanged
        guard material else { return SnapshotFanOutDecision(persist: false, updateActivity: false, reloadWidgets: false) }

        let reload: Bool
        if statusChanged { reload = true }
        else if let lastWidgetReloadAt { reload = now.timeIntervalSince(lastWidgetReloadAt) >= widgetReloadInterval }
        else { reload = true }
        return SnapshotFanOutDecision(persist: true, updateActivity: true, reloadWidgets: reload)
    }

    private static func portStateChanged(_ a: SharedPortSnapshot?, _ b: SharedPortSnapshot?) -> Bool {
        guard let a, let b else { return a != nil || b != nil }
        return a.enabled != b.enabled || a.bypassOn != b.bypassOn || a.mode != b.mode || a.isDCInput != b.isDCInput
    }

    private static func materialPowerChanged(_ a: Double?, _ b: Double?) -> Bool {
        guard let a, let b else { return a != nil || b != nil }
        if a.isNaN || b.isNaN { return a.isNaN != b.isNaN }
        if a.isInfinite || b.isInfinite { return a != b }
        return abs(a - b) >= 1.0
    }
}

public extension SharedDeviceSnapshot {
    /// Wall-clock age of telemetry; future timestamps are treated as fresh.
    func age(now: Date) -> TimeInterval { max(0, now.timeIntervalSince(observedAt)) }
}
