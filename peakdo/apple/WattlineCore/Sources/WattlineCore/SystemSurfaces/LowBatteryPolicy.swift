import Foundation

/// Whether a low-battery alert may be emitted or is suppressed until hysteresis is met.
public enum LowBatteryState: Equatable, Sendable {
    case armed
    case suppressed
}

/// Pure, deterministic low-battery edge detector.
public struct LowBatteryPolicy: Equatable, Sendable {
    public let threshold: Int
    public let hysteresis: Int
    public private(set) var state: LowBatteryState

    public init(threshold: Int = 20, hysteresis: Int = 3) {
        self.threshold = threshold
        self.hysteresis = hysteresis
        state = .armed
    }

    /// Evaluates one authoritative battery sample. The first eligible discharging sample
    /// already at or below the threshold alerts because an earlier crossing may be unobserved.
    public mutating func evaluate(
        level: Int,
        status: PowerFlow,
        enabled: Bool,
        hasBattery: Bool
    ) -> LowBatteryEvent? {
        guard enabled, hasBattery else { return nil }

        // Re-arm only after the battery has recovered beyond the threshold by the full
        // hysteresis band. This is intentionally independent of telemetry timestamps.
        if level >= threshold + hysteresis {
            state = .armed
        }

        guard status == .discharging, level <= threshold, state == .armed else {
            return nil
        }

        state = .suppressed
        return .alert
    }
}

public enum LowBatteryEvent: Equatable, Sendable {
    case alert
}
