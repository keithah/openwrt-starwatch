import WattlineCore

public struct DashboardCapabilities: Equatable, Sendable {
    public let hasBattery: Bool
    public let hasDCPort: Bool
    public let hasDCControl: Bool
    public let hasUSBPort: Bool
    public let hasUSBOutputControl: Bool
    public let hasPowerLimits: Bool
    public let hasBypass: Bool
    public let showsDCInput: Bool

    public init(
        hasBattery: Bool,
        hasDCPort: Bool,
        hasDCControl: Bool,
        hasUSBPort: Bool,
        hasUSBOutputControl: Bool,
        hasPowerLimits: Bool,
        hasBypass: Bool = false,
        showsDCInput: Bool = false
    ) {
        self.hasBattery = hasBattery
        self.hasDCPort = hasDCPort
        self.hasDCControl = hasDCControl
        self.hasUSBPort = hasUSBPort
        self.hasUSBOutputControl = hasUSBOutputControl
        self.hasPowerLimits = hasPowerLimits
        self.hasBypass = hasBypass
        self.showsDCInput = showsDCInput
    }

    public init(_ capabilities: DeviceCapabilities) {
        self.init(
            hasBattery: capabilities.hasBattery,
            hasDCPort: capabilities.hasDCPort,
            hasDCControl: capabilities.hasDCControl,
            hasUSBPort: capabilities.hasUSBPort,
            hasUSBOutputControl: capabilities.hasUSBOutputControl,
            hasPowerLimits: capabilities.hasPowerLimits,
            hasBypass: capabilities.hasBypass,
            showsDCInput: capabilities.showsDCInput
        )
    }

    public static let all = DashboardCapabilities(
        hasBattery: true,
        hasDCPort: true,
        hasDCControl: true,
        hasUSBPort: true,
        hasUSBOutputControl: true,
        hasPowerLimits: true,
        hasBypass: true,
        showsDCInput: true
    )

    public static let dcOnly = DashboardCapabilities(
        hasBattery: false,
        hasDCPort: true,
        hasDCControl: true,
        hasUSBPort: false,
        hasUSBOutputControl: false,
        hasPowerLimits: false
    )

    public static let none = DashboardCapabilities(
        hasBattery: false,
        hasDCPort: false,
        hasDCControl: false,
        hasUSBPort: false,
        hasUSBOutputControl: false,
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

public enum DashboardPort: Equatable, Hashable, Sendable {
    case dc
    case usb
}

public enum DashboardControlPresentation: Equatable, Sendable {
    case hidden
    case toggle
}

public struct DashboardSections: Equatable, RandomAccessCollection, Sendable,
    ExpressibleByArrayLiteral
{
    public typealias Element = DashboardSection
    public typealias Index = Int

    private let storage: [DashboardSection]
    private let dcControl: DashboardControlPresentation
    private let usbControl: DashboardControlPresentation

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
        dcControl = capabilities.hasDCPort && capabilities.hasDCControl ? .toggle : .hidden
        usbControl = capabilities.hasUSBPort && capabilities.hasUSBOutputControl ? .toggle : .hidden
    }

    public init(capabilities: DeviceCapabilities) {
        self.init(capabilities: DashboardCapabilities(capabilities))
    }

    public init(arrayLiteral elements: DashboardSection...) {
        storage = elements
        dcControl = .hidden
        usbControl = .hidden
    }

    public var startIndex: Int { storage.startIndex }
    public var endIndex: Int { storage.endIndex }

    public subscript(position: Int) -> DashboardSection {
        storage[position]
    }

    public func controlPresentation(for port: DashboardPort) -> DashboardControlPresentation {
        switch port {
        case .dc: dcControl
        case .usb: usbControl
        }
    }
}
