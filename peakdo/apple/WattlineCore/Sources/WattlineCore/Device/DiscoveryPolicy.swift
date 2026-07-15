public struct DiscoveryIdentity: Equatable, Sendable {
    public let localName: String
    public let mode: DeviceMode

    public init(localName: String, mode: DeviceMode) {
        self.localName = localName
        self.mode = mode
    }
}

public enum DiscoveryPolicy {
    public static func resolve(
        advertisementLocalName: String?,
        cachedPeripheralName: String?
    ) -> DiscoveryIdentity? {
        guard let advertisementLocalName,
              let mode = classify(
                  localName: advertisementLocalName,
                  cachedPeripheralName: cachedPeripheralName
              )
        else { return nil }
        return DiscoveryIdentity(localName: advertisementLocalName, mode: mode)
    }

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
