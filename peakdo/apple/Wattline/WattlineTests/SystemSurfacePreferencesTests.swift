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
}
