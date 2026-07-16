import XCTest
@testable import WattlineUI

final class SystemSurfacePresentationTests: XCTestCase {
    func testDefaultsAndThresholdClamping() throws {
        let defaults = SystemSurfacePreferences()
        XCTAssertTrue(defaults.liveActivityCharging)
        XCTAssertTrue(defaults.liveActivityDischarging)
        XCTAssertFalse(defaults.lowBatteryEnabled)
        XCTAssertEqual(defaults.lowBatteryThreshold, 20)
        XCTAssertEqual(SystemSurfacePreferences(lowBatteryThreshold: 0).lowBatteryThreshold, 1)
        XCTAssertEqual(SystemSurfacePreferences(lowBatteryThreshold: 100).lowBatteryThreshold, 99)
    }

    func testCodableRoundTripPreservesIndependentToggles() throws {
        let value = SystemSurfacePreferences(liveActivityCharging: false, liveActivityDischarging: true, lowBatteryEnabled: true, lowBatteryThreshold: 27)
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(SystemSurfacePreferences.self, from: data), value)
    }
}
