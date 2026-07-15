import Foundation
import WattlineCore

struct PersistedObservation<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    let value: Value
    let observedAt: Date
}

struct PersistedDeviceState: Codable, Equatable, Sendable {
    var resolvedFeaturesRawValue: UInt32?
    var battery: PersistedObservation<BatteryStatus>?
    var dc: PersistedObservation<DCPortStatus>?
    var typeC: PersistedObservation<TypeCPortStatus>?

    init(
        resolvedFeaturesRawValue: UInt32? = nil,
        battery: PersistedObservation<BatteryStatus>? = nil,
        dc: PersistedObservation<DCPortStatus>? = nil,
        typeC: PersistedObservation<TypeCPortStatus>? = nil
    ) {
        self.resolvedFeaturesRawValue = resolvedFeaturesRawValue
        self.battery = battery
        self.dc = dc
        self.typeC = typeC
    }
}

@MainActor
final class AppPersistence {
    static let onboardingCompleteKey = "onboardingComplete"
    static let knownDevicesKey = "knownDevices"
    static let lastSuccessfulPeripheralIDKey = "lastSuccessfulPeripheralID"

    private let defaults: UserDefaults
    private let wallClock: @MainActor () -> Date
    private(set) var telemetryFlushCount = 0

    init(
        defaults: UserDefaults = .standard,
        wallClock: @escaping @MainActor () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.wallClock = wallClock
    }

    var currentDate: Date { wallClock() }

    var onboardingComplete: Bool {
        get { defaults.bool(forKey: Self.onboardingCompleteKey) }
        set { defaults.set(newValue, forKey: Self.onboardingCompleteKey) }
    }

    var lastSuccessfulPeripheralID: UUID? {
        get {
            defaults.string(forKey: Self.lastSuccessfulPeripheralIDKey).flatMap(UUID.init(uuidString:))
        }
        set {
            defaults.set(newValue?.uuidString, forKey: Self.lastSuccessfulPeripheralIDKey)
        }
    }

    func loadKnownDevices() -> [UUID: AppModel.CachedIdentity] {
        let records = loadRecords()
        return Dictionary(uniqueKeysWithValues: records.map { ($0.identifier, $0.identity) })
    }

    func saveKnownDevices(_ devices: [UUID: AppModel.CachedIdentity]) {
        let existing = Dictionary(uniqueKeysWithValues: loadRecords().map { ($0.identifier, $0) })
        saveRecords(devices.map {
            AppModel.KnownDevice(
                identifier: $0.key,
                identity: $0.value,
                persistedState: existing[$0.key]?.persistedState
            )
        })
    }

    func loadPersistedDeviceState(for identifier: UUID) -> PersistedDeviceState? {
        loadRecords().first { $0.identifier == identifier }?.persistedState
    }

    func saveResolvedFeatures(_ rawValue: UInt32, for identifier: UUID) {
        updatePersistedState(for: identifier) { state in
            state.resolvedFeaturesRawValue = rawValue
        }
    }

    func saveTelemetry(
        battery: PersistedObservation<BatteryStatus>?,
        dc: PersistedObservation<DCPortStatus>?,
        typeC: PersistedObservation<TypeCPortStatus>?,
        for identifier: UUID
    ) {
        let didSave = updatePersistedState(for: identifier) { state in
            if let battery { state.battery = battery }
            if let dc { state.dc = dc }
            if let typeC { state.typeC = typeC }
        }
        if didSave { telemetryFlushCount += 1 }
    }

    func resetOnboarding() {
        defaults.removeObject(forKey: Self.onboardingCompleteKey)
    }

    @discardableResult
    private func updatePersistedState(
        for identifier: UUID,
        mutate: (inout PersistedDeviceState) -> Void
    ) -> Bool {
        var records = loadRecords()
        guard let index = records.firstIndex(where: { $0.identifier == identifier }) else { return false }
        var state = records[index].persistedState ?? PersistedDeviceState()
        mutate(&state)
        records[index] = AppModel.KnownDevice(
            identifier: identifier,
            identity: records[index].identity,
            persistedState: state
        )
        saveRecords(records)
        return true
    }

    private func loadRecords() -> [AppModel.KnownDevice] {
        guard let data = defaults.data(forKey: Self.knownDevicesKey),
              let records = try? decoder.decode([AppModel.KnownDevice].self, from: data)
        else { return [] }
        return records
    }

    private func saveRecords(_ records: [AppModel.KnownDevice]) {
        if let data = try? encoder.encode(records) {
            defaults.set(data, forKey: Self.knownDevicesKey)
        }
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return decoder
    }
}
