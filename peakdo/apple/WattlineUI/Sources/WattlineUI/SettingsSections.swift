import WattlineCore

public enum SettingsRow: Equatable, Hashable, Sendable {
    case deviceInfo
    case clock
    case dcPort
    case bypass
    case restart
    case shutdown
    case systemSurfaces
}

public struct SettingsComposition: Equatable, Sendable {
    public let rows: [SettingsRow]

    public init(
        capabilities: DeviceCapabilities,
        isApplicationMode: Bool,
        supportsManualClock: Bool = true
    ) {
        var rows: [SettingsRow] = [.deviceInfo]
        guard isApplicationMode else {
            self.rows = rows
            return
        }

        if supportsManualClock { rows.append(.clock) }
        if capabilities.hasDCPort && capabilities.hasDCControl {
            rows.append(.dcPort)
        }
        if capabilities.hasBypass && capabilities.hasBypassControl {
            rows.append(.bypass)
        }
        if capabilities.hasBattery { rows.append(.systemSurfaces) }
        rows.append(.restart)
        if capabilities.canShutdown {
            rows.append(.shutdown)
        }
        self.rows = rows
    }
}
