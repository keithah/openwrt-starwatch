import XCTest
@testable import WattlineCore

final class LowBatteryPolicyTests: XCTestCase {
    func testDownwardCrossingAlertsOnceUntilHysteresisRearm() {
        var policy = LowBatteryPolicy()
        XCTAssertNil(policy.evaluate(level: 21, status: .discharging, enabled: true, hasBattery: true))
        XCTAssertEqual(policy.evaluate(level: 20, status: .discharging, enabled: true, hasBattery: true), .alert)
        XCTAssertNil(policy.evaluate(level: 19, status: .discharging, enabled: true, hasBattery: true))
        XCTAssertNil(policy.evaluate(level: 18, status: .discharging, enabled: true, hasBattery: true))
        XCTAssertNil(policy.evaluate(level: 23, status: .discharging, enabled: true, hasBattery: true))
        XCTAssertEqual(policy.evaluate(level: 20, status: .discharging, enabled: true, hasBattery: true), .alert)
    }

    func testChargingAndIdleAreSilentAndGatesSuppressAlerts() {
        var policy = LowBatteryPolicy()
        XCTAssertNil(policy.evaluate(level: 20, status: .charging, enabled: true, hasBattery: true))
        XCTAssertNil(policy.evaluate(level: 19, status: .idle, enabled: true, hasBattery: true))
        XCTAssertNil(policy.evaluate(level: 18, status: .discharging, enabled: false, hasBattery: true))
        XCTAssertNil(policy.evaluate(level: 18, status: .discharging, enabled: true, hasBattery: false))
    }

    func testAlreadyLowFirstEligibleDischargeAlertsOnce() {
        var policy = LowBatteryPolicy()
        XCTAssertEqual(policy.evaluate(level: 19, status: .discharging, enabled: true, hasBattery: true), .alert)
        XCTAssertNil(policy.evaluate(level: 18, status: .discharging, enabled: true, hasBattery: true))
        XCTAssertNil(policy.evaluate(level: 23, status: .charging, enabled: true, hasBattery: true))
        XCTAssertEqual(policy.evaluate(level: 20, status: .discharging, enabled: true, hasBattery: true), .alert)
    }
}
