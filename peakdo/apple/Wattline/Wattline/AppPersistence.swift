import Foundation

@MainActor
final class AppPersistence {
    static let onboardingCompleteKey = "onboardingComplete"
    static let knownDevicesKey = "knownDevices"
    static let lastSuccessfulPeripheralIDKey = "lastSuccessfulPeripheralID"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

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
        guard let data = defaults.data(forKey: Self.knownDevicesKey),
              let records = try? JSONDecoder().decode([AppModel.KnownDevice].self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: records.map { ($0.identifier, $0.identity) })
    }

    func saveKnownDevices(_ devices: [UUID: AppModel.CachedIdentity]) {
        let records = devices.map { AppModel.KnownDevice(identifier: $0.key, identity: $0.value) }
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: Self.knownDevicesKey)
        }
    }

    func resetOnboarding() {
        defaults.removeObject(forKey: Self.onboardingCompleteKey)
    }
}
