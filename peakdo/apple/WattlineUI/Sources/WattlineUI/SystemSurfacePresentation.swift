import Foundation

/// User preferences controlling system surfaces. Kept Codable so the app can
/// persist the value without coupling WattlineUI to a storage implementation.
public struct SystemSurfacePreferences: Codable, Equatable, Sendable {
    public var liveActivityCharging: Bool
    public var liveActivityDischarging: Bool
    public var lowBatteryEnabled: Bool
    public var lowBatteryThreshold: Int

    public init(
        liveActivityCharging: Bool = true,
        liveActivityDischarging: Bool = true,
        lowBatteryEnabled: Bool = false,
        lowBatteryThreshold: Int = 20
    ) {
        self.liveActivityCharging = liveActivityCharging
        self.liveActivityDischarging = liveActivityDischarging
        self.lowBatteryEnabled = lowBatteryEnabled
        self.lowBatteryThreshold = min(max(lowBatteryThreshold, 1), 99)
    }
}
