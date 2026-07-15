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

enum BLEHandshakeFailure: Equatable, Sendable {
    case missingCharacteristic(GATTUUID)
    case invalidResponse
    case operationFailed(GATTUUID)
    case subscriptionFailed(GATTUUID)
}

enum BLEHandshakeAction: Equatable, Sendable {
    case settle
    case discoverServices
    case write(Data, to: GATTUUID, readAfterWrite: Bool)
    case read(GATTUUID)
    case subscribe(GATTUUID)
    case publish(DeviceIdentitySnapshot)
    case connected(UUID)
    case fail(BLEHandshakeFailure)
}

struct BLEHandshakeDriver: Sendable {
    private enum Step: Equatable, Sendable {
        case otaInfo
        case dis(GATTUUID)
        case features
        case deviceID
        case currentTime
        case telemetry(GATTUUID)
        case subscribe(GATTUUID)
        case publish
        case connected
    }

    private enum State: Equatable, Sendable {
        case idle
        case settling
        case discovering
        case writing(Step, GATTUUID, readAfterWrite: Bool)
        case reading(Step, GATTUUID)
        case subscribing(GATTUUID)
        case publishing
        case terminal
    }

    private let scope: BLEConnectionScope
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private var state: State = .idle
    private var available: Set<GATTUUID> = []
    private var steps: [Step] = []
    private var mode: DeviceMode = .application
    private var modelNumber: String?
    private var hardwareRevision: String?
    private var otaFirmwareRevision: String?
    private var appFirmwareRevision: String?
    private var cid: UInt16?
    private var features: FeatureFlags?
    private var macAddress: String?
    private let advertisedName: String?

    init(
        scope: BLEConnectionScope,
        advertisedName: String?,
        now: @escaping @Sendable () -> Date,
        calendar: Calendar = CurrentTimeCodec.defaultCalendar()
    ) {
        self.scope = scope
        self.advertisedName = advertisedName
        self.now = now
        self.calendar = calendar
    }

    mutating func start() -> BLEHandshakeAction? {
        guard state == .idle else { return nil }
        state = .settling
        return .settle
    }

    mutating func settleCompleted(scope: BLEConnectionScope) -> BLEHandshakeAction? {
        guard scope == self.scope, state == .settling else { return nil }
        state = .discovering
        return .discoverServices
    }

    mutating func characteristicsDiscovered(
        scope: BLEConnectionScope,
        available: Set<GATTUUID>
    ) -> BLEHandshakeAction? {
        guard scope == self.scope, state == .discovering else { return nil }
        self.available = available
        guard available.contains(.ota) else { return fail(.missingCharacteristic(.ota)) }
        return write(.otaInfo, bytes: Data([0x84]), to: .ota, readAfterWrite: true)
    }

    mutating func writeCompleted(
        scope: BLEConnectionScope,
        uuid: GATTUUID,
        succeeded: Bool
    ) -> BLEHandshakeAction? {
        guard scope == self.scope,
              case let .writing(step, expected, readAfterWrite) = state,
              uuid == expected
        else { return nil }
        guard succeeded else {
            switch step {
            case .features:
                appendPostFeatureSteps()
                return next()
            case .deviceID:
                return next()
            default:
                return fail(.operationFailed(uuid))
            }
        }
        if readAfterWrite {
            state = .reading(step, uuid)
            return .read(uuid)
        }
        return next()
    }

    mutating func readCompleted(
        scope: BLEConnectionScope,
        uuid: GATTUUID,
        value: Data?
    ) -> BLEHandshakeAction? {
        guard scope == self.scope,
              case let .reading(step, expected) = state,
              uuid == expected
        else { return nil }

        do {
            switch step {
            case .otaInfo:
                guard let value else { return fail(.invalidResponse) }
                let info = try OTAInfo(frame: value)
                mode = info.mode
                cid = info.cid
                steps = info.mode == .ota
                    ? [.publish, .connected]
                    : [.dis(.modelNumber), .dis(.hardwareRevision),
                       .dis(.firmwareRevision), .dis(.softwareRevision), .features]
            case let .dis(characteristic):
                if let value, let string = String(data: value, encoding: .utf8) {
                    switch characteristic {
                    case .modelNumber: modelNumber = string
                    case .hardwareRevision: hardwareRevision = string
                    case .firmwareRevision: otaFirmwareRevision = string
                    case .softwareRevision: appFirmwareRevision = string
                    default: break
                    }
                }
            case .features:
                if let value { features = try HandshakeCodec.features(from: value) }
                appendPostFeatureSteps()
            case .deviceID:
                if let value { macAddress = try DeviceID(reply: value).macAddress }
            case .telemetry, .currentTime, .subscribe, .publish, .connected:
                break
            }
        } catch {
            switch step {
            case .features:
                appendPostFeatureSteps()
            case .deviceID, .dis, .telemetry:
                break
            default:
                return fail(.invalidResponse)
            }
        }
        return next()
    }

    mutating func notificationStateUpdated(
        scope: BLEConnectionScope,
        uuid: GATTUUID,
        succeeded: Bool,
        isNotifying: Bool
    ) -> BLEHandshakeAction? {
        guard scope == self.scope, state == .subscribing(uuid) else { return nil }
        guard succeeded, isNotifying else { return fail(.subscriptionFailed(uuid)) }
        return next()
    }

    mutating func eventEmitted(scope: BLEConnectionScope) -> BLEHandshakeAction? {
        guard scope == self.scope, state == .publishing else { return nil }
        return next()
    }

    private mutating func appendPostFeatureSteps() {
        guard !steps.contains(.deviceID) else { return }
        let capabilities = CapabilityResolver.resolve(
            features: features,
            cid: cid,
            model: modelNumber
        )
        steps += [.deviceID, .currentTime]
        if capabilities.hasBattery {
            steps += [.telemetry(.extendedBatteryInfo), .subscribe(.extendedBatteryInfo)]
        }
        if capabilities.hasDCPort {
            steps += [.telemetry(.dcPortStatus), .subscribe(.dcPortStatus)]
        }
        if capabilities.hasUSBPort {
            steps += [.telemetry(.typeCPortStatus), .subscribe(.typeCPortStatus)]
        }
        steps += [.publish, .connected]
    }

    private mutating func next() -> BLEHandshakeAction? {
        while !steps.isEmpty {
            let step = steps.removeFirst()
            switch step {
            case let .dis(uuid), let .telemetry(uuid):
                guard available.contains(uuid) else { continue }
                state = .reading(step, uuid)
                return .read(uuid)
            case .features:
                guard available.contains(.command) else {
                    appendPostFeatureSteps()
                    continue
                }
                return write(
                    step,
                    bytes: CommandRequest(command: .features, action: .get).bytes,
                    to: .command,
                    readAfterWrite: true
                )
            case .deviceID:
                guard available.contains(.command) else { continue }
                return write(
                    step,
                    bytes: CommandRequest(command: .deviceID, action: .get).bytes,
                    to: .command,
                    readAfterWrite: true
                )
            case .currentTime:
                guard available.contains(.currentTime) else {
                    return fail(.missingCharacteristic(.currentTime))
                }
                return write(
                    step,
                    bytes: CurrentTimeCodec.encode(now(), calendar: calendar, adjustReason: 1),
                    to: .currentTime,
                    readAfterWrite: false
                )
            case let .subscribe(uuid):
                guard available.contains(uuid) else { continue }
                state = .subscribing(uuid)
                return .subscribe(uuid)
            case .publish:
                state = .publishing
                return .publish(snapshot)
            case .connected:
                state = .terminal
                return .connected(scope.peripheralID)
            case .otaInfo:
                return fail(.invalidResponse)
            }
        }
        return fail(.invalidResponse)
    }

    private mutating func write(
        _ step: Step,
        bytes: Data,
        to uuid: GATTUUID,
        readAfterWrite: Bool
    ) -> BLEHandshakeAction {
        state = .writing(step, uuid, readAfterWrite: readAfterWrite)
        return .write(bytes, to: uuid, readAfterWrite: readAfterWrite)
    }

    private mutating func fail(_ failure: BLEHandshakeFailure) -> BLEHandshakeAction {
        state = .terminal
        return .fail(failure)
    }

    private var snapshot: DeviceIdentitySnapshot {
        let capabilities = mode == .ota
            ? DeviceCapabilities(features: [])
            : CapabilityResolver.resolve(features: features, cid: cid, model: modelNumber)
        return DeviceIdentitySnapshot(
            peripheralID: scope.peripheralID,
            advertisedName: advertisedName,
            mode: mode,
            modelNumber: modelNumber,
            hardwareRevision: hardwareRevision,
            otaFirmwareRevision: otaFirmwareRevision,
            appFirmwareRevision: appFirmwareRevision,
            cid: cid,
            rawFeatures: features?.rawValue,
            macAddress: macAddress,
            capabilities: capabilities
        )
    }
}

enum HandshakeAdvertisementPolicy {
    static func advertisedName(freshLocalName: String?) -> String? { freshLocalName }
}
