import Foundation

public enum RouterAdvancedSurface: String, CaseIterable, Hashable, Sendable {
    case bypassThreshold
    case clock
    case runningMode
    case barrierFree
    case usbFirmware
    case blePIN
}

public enum RouterAdvancedApplicationMode: Equatable, Sendable {
    case application
    case ota
}

public enum RouterAdvancedServerGate: Equatable, Sendable {
    case allowed
    case advancedDisabled
}

public struct RouterAdvancedVisibilityInput: Sendable {
    public let adminVerified: Bool
    public let advanced: Bool
    public let mode: RouterAdvancedApplicationMode
    public let hasFactoryMode: Bool
    public let hasBypassControl: Bool
    public let currentTimeAvailable: Bool
    public let dcAvailable: Bool
    public let usbAvailable: Bool
    public let unsupported: Set<RouterAdvancedSurface>
    public let serverGate: RouterAdvancedServerGate

    public init(
        adminVerified: Bool,
        advanced: Bool,
        mode: RouterAdvancedApplicationMode,
        hasFactoryMode: Bool,
        hasBypassControl: Bool,
        currentTimeAvailable: Bool,
        dcAvailable: Bool,
        usbAvailable: Bool,
        unsupported: Set<RouterAdvancedSurface>,
        serverGate: RouterAdvancedServerGate
    ) {
        self.adminVerified = adminVerified
        self.advanced = advanced
        self.mode = mode
        self.hasFactoryMode = hasFactoryMode
        self.hasBypassControl = hasBypassControl
        self.currentTimeAvailable = currentTimeAvailable
        self.dcAvailable = dcAvailable
        self.usbAvailable = usbAvailable
        self.unsupported = unsupported
        self.serverGate = serverGate
    }
}

public struct RouterAdvancedVisibility: Equatable, Sendable {
    public let surfaces: Set<RouterAdvancedSurface>
    public let showsEnableAdvancedAffordance: Bool

    public init(
        surfaces: Set<RouterAdvancedSurface>,
        showsEnableAdvancedAffordance: Bool
    ) {
        self.surfaces = surfaces
        self.showsEnableAdvancedAffordance = showsEnableAdvancedAffordance
    }

    public static func evaluate(_ input: RouterAdvancedVisibilityInput) -> Self {
        guard input.adminVerified else {
            return .init(surfaces: [], showsEnableAdvancedAffordance: false)
        }
        guard input.advanced, input.serverGate == .allowed else {
            return .init(surfaces: [], showsEnableAdvancedAffordance: true)
        }
        guard input.mode == .application else {
            return .init(surfaces: [], showsEnableAdvancedAffordance: false)
        }

        var surfaces: Set<RouterAdvancedSurface> = []
        if input.hasBypassControl, input.dcAvailable { surfaces.insert(.bypassThreshold) }
        if input.currentTimeAvailable { surfaces.insert(.clock) }
        if input.hasFactoryMode {
            surfaces.formUnion([.runningMode, .barrierFree, .blePIN])
            if input.usbAvailable { surfaces.insert(.usbFirmware) }
        }
        surfaces.subtract(input.unsupported)
        return .init(surfaces: surfaces, showsEnableAdvancedAffordance: false)
    }
}

public enum RouterAdvancedConfirmation: Equatable, Sendable {
    case runningMode
    case blePIN

    public static func required(for surface: RouterAdvancedSurface) -> Self? {
        switch surface {
        case .runningMode: .runningMode
        case .blePIN: .blePIN
        default: nil
        }
    }
}

public enum RouterAdvancedSecretPolicy {
    public static func shouldClearBLEPIN(
        wasVisible: Bool,
        isVisible: Bool
    ) -> Bool {
        wasVisible && !isVisible
    }
}

public struct RouterAdvancedClockValue: Equatable, Sendable {
    public let available: Bool
    public let deviceTime: String?
    public let systemTime: String
    public let driftSeconds: Int?

    public init(available: Bool, deviceTime: String?, systemTime: String, driftSeconds: Int?) {
        self.available = available
        self.deviceTime = deviceTime
        self.systemTime = systemTime
        self.driftSeconds = driftSeconds
    }
}

public struct RouterAdvancedUSBFirmwareValue: Equatable, Sendable {
    public let raw: String
    public let major: UInt8
    public let minor: UInt8
    public let patch: UInt8

    public init(raw: String, major: UInt8, minor: UInt8, patch: UInt8) {
        self.raw = raw
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var displayVersion: String { "\(major).\(minor).\(patch)" }
}

public struct RouterAdvancedValues: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    public let bypassThresholdVolts: Double?
    public let clock: RouterAdvancedClockValue?
    public let runningMode: UInt8?
    public let barrierFreeEnabled: Bool?
    public let usbFirmware: RouterAdvancedUSBFirmwareValue?
    public let blePINUpdated: Bool?

    public init(
        bypassThresholdVolts: Double? = nil,
        clock: RouterAdvancedClockValue? = nil,
        runningMode: UInt8? = nil,
        barrierFreeEnabled: Bool? = nil,
        usbFirmware: RouterAdvancedUSBFirmwareValue? = nil,
        blePINUpdated: Bool? = nil
    ) {
        self.bypassThresholdVolts = bypassThresholdVolts
        self.clock = clock
        self.runningMode = runningMode
        self.barrierFreeEnabled = barrierFreeEnabled
        self.usbFirmware = usbFirmware
        self.blePINUpdated = blePINUpdated
    }

    public var description: String { "RouterAdvancedValues([REDACTED])" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["values": "[REDACTED]"], displayStyle: .struct)
    }
}
