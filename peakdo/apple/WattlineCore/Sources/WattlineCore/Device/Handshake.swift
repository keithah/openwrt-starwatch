import Foundation

public struct DeviceIdentitySnapshot: Equatable, Sendable {
    public let peripheralID: UUID
    public let advertisedName: String?
    public let mode: DeviceMode
    public let modelNumber: String?
    public let hardwareRevision: String?
    public let otaFirmwareRevision: String?
    public let appFirmwareRevision: String?
    public let cid: UInt16?
    public let rawFeatures: UInt32?
    public let macAddress: String?
    public let capabilities: DeviceCapabilities

    public init(
        peripheralID: UUID,
        advertisedName: String?,
        mode: DeviceMode,
        modelNumber: String? = nil,
        hardwareRevision: String? = nil,
        otaFirmwareRevision: String? = nil,
        appFirmwareRevision: String? = nil,
        cid: UInt16? = nil,
        rawFeatures: UInt32? = nil,
        macAddress: String? = nil,
        capabilities: DeviceCapabilities
    ) {
        self.peripheralID = peripheralID
        self.advertisedName = advertisedName
        self.mode = mode
        self.modelNumber = modelNumber
        self.hardwareRevision = hardwareRevision
        self.otaFirmwareRevision = otaFirmwareRevision
        self.appFirmwareRevision = appFirmwareRevision
        self.cid = cid
        self.rawFeatures = rawFeatures
        self.macAddress = macAddress
        self.capabilities = capabilities
    }
}

public enum HandshakeOperation: Equatable, Sendable {
    case settle
    case discoverServices
    case otaInfo
    case readDIS(GATTUUID)
    case features
    case deviceID
    case writeCurrentTime
    case readTelemetry(GATTUUID)
    case subscribe(GATTUUID)
    case publishSnapshot
    case connected
}

public enum HandshakePlan {
    public static func operations(
        mode: DeviceMode,
        capabilities: DeviceCapabilities
    ) -> [HandshakeOperation] {
        var result: [HandshakeOperation] = [.settle, .discoverServices, .otaInfo]
        guard mode == .application else {
            return result + [.publishSnapshot, .connected]
        }

        result += [
            .readDIS(.modelNumber), .readDIS(.hardwareRevision),
            .readDIS(.firmwareRevision), .readDIS(.softwareRevision),
            .features, .deviceID, .writeCurrentTime,
        ]
        if capabilities.hasBattery {
            result += [.readTelemetry(.extendedBatteryInfo), .subscribe(.extendedBatteryInfo)]
        }
        if capabilities.hasDCPort {
            result += [.readTelemetry(.dcPortStatus), .subscribe(.dcPortStatus)]
        }
        if capabilities.hasUSBPort {
            result += [.readTelemetry(.typeCPortStatus), .subscribe(.typeCPortStatus)]
        }
        return result + [.publishSnapshot, .connected]
    }
}
