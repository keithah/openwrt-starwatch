public enum DiscoveryPolicy {
    public static func classify(
        localName: String?,
        cachedPeripheralName _: String?
    ) -> DeviceMode? {
        guard let localName else { return nil }
        if localName.hasPrefix("Link-Power") { return .application }
        if localName.hasPrefix("PeakDo-OTA") { return .ota }
        return nil
    }
}

public enum OTAConnectionMode: Equatable, Sendable {
    case application
    case bootloader
}

public enum OTAConnectionResolution: Equatable, Sendable {
    case reportConnectionFailure
    case showBondRecoveryGuidance
}

public struct OTAConnectionPolicy: Equatable, Sendable {
    public static let bootloaderBondErrorCode = 14

    public let resolution: OTAConnectionResolution

    public init(mode: OTAConnectionMode, errorCode: Int?) {
        resolution = mode == .bootloader && errorCode == Self.bootloaderBondErrorCode
            ? .showBondRecoveryGuidance
            : .reportConnectionFailure
    }
}
