import XCTest
import WattlineCore
import WattlineUI
@testable import Wattline

@MainActor
final class SystemSurfacePreferencesTests: XCTestCase {
    func testPreferencesPersistAndClamp() {
        let defaults = UserDefaults(suiteName: "surface-\(UUID().uuidString)")!
        let persistence = AppPersistence(defaults: defaults)
        XCTAssertEqual(persistence.systemSurfacePreferences, SystemSurfacePreferences())
        persistence.systemSurfacePreferences = SystemSurfacePreferences(liveActivityCharging: false, liveActivityDischarging: true, lowBatteryEnabled: true, lowBatteryThreshold: 26)
        let reloaded = AppPersistence(defaults: defaults)
        XCTAssertEqual(reloaded.systemSurfacePreferences.lowBatteryThreshold, 26)
        XCTAssertTrue(reloaded.lowBatteryEnabled)
        XCTAssertFalse(reloaded.systemSurfacePreferences.liveActivityCharging)
    }

    func testBatteryCapabilityAddsSystemSurfaceRowOnlyWhenPresent() {
        let none = SettingsComposition(capabilities: DeviceCapabilities(features: []), isApplicationMode: true)
        XCTAssertFalse(none.rows.contains(.systemSurfaces))
        let battery = SettingsComposition(capabilities: DeviceCapabilities(features: [.batteryCapacity]), isApplicationMode: true)
        XCTAssertTrue(battery.rows.contains(.systemSurfaces))
    }

    func testPersistedLowBatteryPreferenceRestoresWithoutAuthorizationAndPostsAfterReinit() async {
        let defaults = UserDefaults(suiteName: "surface-restore-\(UUID().uuidString)")!
        let persistence = AppPersistence(defaults: defaults)
        var preferences = SystemSurfacePreferences()
        preferences.lowBatteryEnabled = true
        persistence.systemSurfacePreferences = preferences
        let recorder = NotificationRecorder()

        let model = AppModel(
            persistence: persistence,
            notificationAdapter: recorder,
            snapshotCoordinator: nil,
            widgetReloadAdapter: nil
        )
        // The launch restore is asynchronous, but must not request authorization.
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(model.lowBatteryNotificationCoordinator.isEnabled)
        let authorizationRequests = await recorder.authorizationRequests
        XCTAssertEqual(authorizationRequests, 0)

        let battery = SharedBatterySnapshot(enabled: true, status: .discharging, isFull: false, maxCapacity: 100, capacity: 100, level: 19, voltage: 0, current: 0, power: 0, remainingMinutes: 0)
        let snapshot = SharedDeviceSnapshot(peripheralID: UUID(), featuresRawValue: 0, battery: battery, dc: nil, typeC: nil, connection: .live, observedAt: Date())
        await model.lowBatteryNotificationCoordinator.receive(snapshot)
        let posts = await recorder.posts
        XCTAssertEqual(posts.count, 1)
    }
}
