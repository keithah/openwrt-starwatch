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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            liveActivityCharging: try container.decode(Bool.self, forKey: .liveActivityCharging),
            liveActivityDischarging: try container.decode(Bool.self, forKey: .liveActivityDischarging),
            lowBatteryEnabled: try container.decode(Bool.self, forKey: .lowBatteryEnabled),
            lowBatteryThreshold: try container.decode(Int.self, forKey: .lowBatteryThreshold)
        )
    }
}
