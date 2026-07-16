import Foundation
import WattlineCore

/// App-target adapter for the shared snapshot store.
///
/// The Core package deliberately knows nothing about app groups or UserDefaults;
/// this adapter is the production bridge owned by the iOS app target.
final class AppGroupSnapshotBackend: @unchecked Sendable, SnapshotKeyValueStore {
    static let suiteName = "group.com.keithah.wattline"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = UserDefaults(suiteName: suiteName) ?? .standard) {
        self.defaults = defaults
    }

    func data(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    func set(_ data: Data, forKey key: String) {
        defaults.set(data, forKey: key)
    }

    func removeValue(forKey key: String) {
        defaults.removeObject(forKey: key)
    }
}
