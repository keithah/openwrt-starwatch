public struct FeatureFlags: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let display = FeatureFlags(rawValue: 1 << 0)
    public static let factoryMode = FeatureFlags(rawValue: 1 << 1)
    public static let sleep = FeatureFlags(rawValue: 1 << 2)
    public static let shutdown = FeatureFlags(rawValue: 1 << 3)
    public static let batteryCapacity = FeatureFlags(rawValue: 1 << 4)
    public static let dcPort = FeatureFlags(rawValue: 1 << 5)
    public static let dcControl = FeatureFlags(rawValue: 1 << 6)
    public static let dcScheduler = FeatureFlags(rawValue: 1 << 7)
    public static let usbPort = FeatureFlags(rawValue: 1 << 8)
    public static let usbPowerLimit = FeatureFlags(rawValue: 1 << 9)
    public static let usbOutputControl = FeatureFlags(rawValue: 1 << 10)
    public static let dcBypass = FeatureFlags(rawValue: 1 << 11)
    public static let dcBypassControl = FeatureFlags(rawValue: 1 << 12)
    public static let usbDCInput = FeatureFlags(rawValue: 1 << 13)
    public static let usbDCInputPower = FeatureFlags(rawValue: 1 << 14)
}

public struct DeviceCapabilities: Equatable, Sendable {
    public let features: FeatureFlags

    public init(features: FeatureFlags) {
        self.features = features
    }

    public var hasFactoryMode: Bool { features.contains(.factoryMode) }
    public var canShutdown: Bool { features.contains(.shutdown) }
    public var hasBattery: Bool { features.contains(.batteryCapacity) }
    public var hasDCPort: Bool { features.contains(.dcPort) }
    public var hasDCControl: Bool { features.contains(.dcControl) }
    public var hasScheduler: Bool { features.contains(.dcScheduler) }
    public var hasUSBPort: Bool { features.contains(.usbPort) }
    public var hasPowerLimits: Bool { features.contains(.usbPowerLimit) }
    public var hasUSBOutputControl: Bool { features.contains(.usbOutputControl) }
    public var hasBypass: Bool { features.contains(.dcBypass) }
    public var hasBypassControl: Bool { features.contains(.dcBypassControl) }
    public var showsDCInput: Bool { features.contains(.usbDCInput) }
    public var showsDCInputPower: Bool { features.contains(.usbDCInputPower) }
}

public enum CapabilityResolver {
    public static func resolve(
        features: FeatureFlags?,
        cid: UInt16?,
        model: String?
    ) -> DeviceCapabilities {
        if let features {
            return DeviceCapabilities(features: features)
        }
        if let cid {
            return fallback(forModelByte: UInt8(cid >> 8))
        }
        return fallback(forModelString: model)
    }

    private static let lpFamilyFallback: FeatureFlags = [
        .batteryCapacity,
        .dcPort,
        .dcControl,
        .usbPort,
        .usbPowerLimit,
        .usbOutputControl,
    ]

    private static let lppFallback: FeatureFlags = [.dcPort, .dcControl]

    private static func fallback(forModelByte modelByte: UInt8) -> DeviceCapabilities {
        switch modelByte {
        case 0x01, 0x03:
            DeviceCapabilities(features: lpFamilyFallback)
        case 0x02:
            DeviceCapabilities(features: lppFallback)
        default:
            DeviceCapabilities(features: [])
        }
    }

    private static func fallback(forModelString model: String?) -> DeviceCapabilities {
        switch model {
        case "BP4SL3V1", "PK-LINK-POWER-1", "BP4SL3V2":
            DeviceCapabilities(features: lpFamilyFallback)
        case "BP4SL3":
            DeviceCapabilities(features: lppFallback)
        default:
            DeviceCapabilities(features: [])
        }
    }
}
