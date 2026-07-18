import Foundation
import WattlineCore

public struct RouterTimestampOrigin: Equatable, Sendable {
    public let wallClock: Date
    public let deviceTimestamp: DeviceTimestamp

    public init(wallClock: Date, deviceTimestamp: DeviceTimestamp) {
        self.wallClock = wallClock
        self.deviceTimestamp = deviceTimestamp
    }

    func timestamp(for date: Date) -> DeviceTimestamp {
        deviceTimestamp + .seconds(date.timeIntervalSince(wallClock))
    }
}

public enum RouterMappingError: Error, Equatable, Sendable {
    case disconnectedSnapshot
    case invalidPowerFlow(Int8)
    case invalidTypeCPortMode(UInt8)
    case coreTelemetry(String)
}

public struct RouterMapping: Sendable {
    private let peripheralID: UUID
    private let timestampOrigin: RouterTimestampOrigin

    public init(peripheralID: UUID, timestampOrigin: RouterTimestampOrigin) {
        self.peripheralID = peripheralID
        self.timestampOrigin = timestampOrigin
    }

    public func identity(_ identity: RouterIdentityDTO) -> DeviceIdentitySnapshot {
        let features = FeatureFlags(rawValue: identity.features)
        return DeviceIdentitySnapshot(
            peripheralID: peripheralID,
            advertisedName: nil,
            mode: .application,
            modelNumber: identity.model,
            hardwareRevision: identity.hardwareRevision,
            otaFirmwareRevision: nil,
            appFirmwareRevision: identity.firmware,
            cid: identity.cid,
            rawFeatures: identity.features,
            macAddress: identity.mac,
            capabilities: CapabilityResolver.resolve(
                features: features,
                cid: identity.cid,
                model: identity.model
            )
        )
    }

    public func events(
        snapshot: RouterSnapshotDTO,
        observedAt: DeviceTimestamp,
        notBefore: DeviceTimestamp? = nil
    ) throws -> [DeviceEvent] {
        guard snapshot.connected else {
            throw RouterMappingError.disconnectedSnapshot
        }

        let mappedTimestamp = snapshot.updatedAt.map(timestampOrigin.timestamp(for:)) ?? observedAt
        let receiptBoundedTimestamp = min(mappedTimestamp, observedAt)
        let timestamp = max(receiptBoundedTimestamp, notBefore ?? receiptBoundedTimestamp)
        var events: [DeviceEvent] = []
        if let battery = snapshot.battery {
            events.append(.battery(try map(battery), timestamp: timestamp))
        }
        if let dc = snapshot.dc {
            events.append(.dc(try map(dc), timestamp: timestamp))
        }
        if let typeC = snapshot.typeC {
            events.append(.typeC(try map(typeC), timestamp: timestamp))
        }
        return events
    }

    private func map(_ value: RouterBatteryDTO) throws -> BatteryStatus {
        let status = try powerFlow(value.status)
        return try decodeCoreTelemetry(BatteryPayload(
            enabled: value.enabled,
            status: status,
            isFull: value.full,
            maxCapacity: value.maxWh,
            capacity: value.wh,
            level: value.level,
            voltage: value.volts,
            current: value.amps,
            power: value.watts,
            remainingMinutes: value.remainMin
        ))
    }

    private func map(_ value: RouterDCPortDTO) throws -> DCPortStatus {
        let status = try powerFlow(value.status)
        return try decodeCoreTelemetry(DCPayload(
            enabled: value.enabled,
            status: status,
            voltage: value.volts,
            current: value.amps,
            power: value.watts,
            bypassOn: value.bypass
        ))
    }

    private func map(_ value: RouterTypeCPortDTO) throws -> TypeCPortStatus {
        let status = try powerFlow(value.status)
        guard let mode = TypeCPortMode(rawValue: value.mode) else {
            throw RouterMappingError.invalidTypeCPortMode(value.mode)
        }
        return try decodeCoreTelemetry(TypeCPayload(
            enabled: value.enabled,
            status: status,
            voltage: value.volts,
            current: value.amps,
            power: value.watts,
            temperature: value.tempC,
            mode: mode,
            isDCInput: value.dcInput
        ))
    }

    private func powerFlow(_ rawValue: Int8) throws -> PowerFlow {
        guard let flow = PowerFlow(rawValue: rawValue) else {
            throw RouterMappingError.invalidPowerFlow(rawValue)
        }
        return flow
    }

    private func decodeCoreTelemetry<Payload: Encodable, Value: Decodable>(
        _ payload: Payload
    ) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(payload))
        } catch {
            throw RouterMappingError.coreTelemetry(String(describing: error))
        }
    }
}

private struct BatteryPayload: Encodable {
    let enabled: Bool
    let status: PowerFlow
    let isFull: Bool
    let maxCapacity: Double
    let capacity: Double
    let level: UInt8
    let voltage: Double
    let current: Double
    let power: Double
    let remainingMinutes: UInt16
}

private struct DCPayload: Encodable {
    let enabled: Bool
    let status: PowerFlow
    let voltage: Double
    let current: Double
    let power: Double
    let bypassOn: Bool?
}

private struct TypeCPayload: Encodable {
    let enabled: Bool
    let status: PowerFlow
    let voltage: Double
    let current: Double
    let power: Double
    let temperature: Double
    let mode: TypeCPortMode?
    let isDCInput: Bool?
}
