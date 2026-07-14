import WattlineCore

public struct DashboardCapabilities: Equatable, Sendable {
    public let hasBattery: Bool
    public let hasDCPort: Bool
    public let hasUSBPort: Bool
    public let hasPowerLimits: Bool

    public init(
        hasBattery: Bool,
        hasDCPort: Bool,
        hasUSBPort: Bool,
        hasPowerLimits: Bool? = nil
    ) {
        self.hasBattery = hasBattery
        self.hasDCPort = hasDCPort
        self.hasUSBPort = hasUSBPort
        self.hasPowerLimits = hasPowerLimits ?? hasUSBPort
    }

    public init(_ capabilities: DeviceCapabilities) {
        self.init(
            hasBattery: capabilities.hasBattery,
            hasDCPort: capabilities.hasDCPort,
            hasUSBPort: capabilities.hasUSBPort,
            hasPowerLimits: capabilities.hasPowerLimits
        )
    }

    public static let all = DashboardCapabilities(
        hasBattery: true,
        hasDCPort: true,
        hasUSBPort: true,
        hasPowerLimits: true
    )

    public static let dcOnly = DashboardCapabilities(
        hasBattery: false,
        hasDCPort: true,
        hasUSBPort: false,
        hasPowerLimits: false
    )

    public static let none = DashboardCapabilities(
        hasBattery: false,
        hasDCPort: false,
        hasUSBPort: false,
        hasPowerLimits: false
    )
}

public enum DashboardSection: Equatable, Hashable, Sendable {
    case batteryHero
    case batteryStats
    case dcHero
    case dcCard
    case usbCard
    case limitsLink
}

public struct DashboardSections: Equatable, RandomAccessCollection, Sendable,
    ExpressibleByArrayLiteral
{
    public typealias Element = DashboardSection
    public typealias Index = Int

    private let storage: [DashboardSection]

    public init(capabilities: DashboardCapabilities) {
        var sections: [DashboardSection] = []

        if capabilities.hasBattery {
            sections += [.batteryHero, .batteryStats]
        } else if capabilities.hasDCPort {
            sections.append(.dcHero)
        }

        if capabilities.hasDCPort {
            sections.append(.dcCard)
        }

        if capabilities.hasUSBPort {
            sections.append(.usbCard)
            if capabilities.hasPowerLimits {
                sections.append(.limitsLink)
            }
        }

        storage = sections
    }

    public init(capabilities: DeviceCapabilities) {
        self.init(capabilities: DashboardCapabilities(capabilities))
    }

    public init(arrayLiteral elements: DashboardSection...) {
        storage = elements
    }

    public var startIndex: Int { storage.startIndex }
    public var endIndex: Int { storage.endIndex }

    public subscript(position: Int) -> DashboardSection {
        storage[position]
    }
}
