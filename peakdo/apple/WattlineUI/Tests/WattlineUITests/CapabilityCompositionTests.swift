import XCTest
@testable import WattlineUI

final class CapabilityCompositionTests: XCTestCase {
    func testUSBRemovalRemovesCardLimitsAndToggle() {
        let sections = DashboardSections(
            capabilities: .init(hasBattery: true, hasDCPort: true, hasUSBPort: false)
        )

        XCTAssertFalse(sections.contains(.usbCard))
        XCTAssertFalse(sections.contains(.limitsLink))
    }

    func testBatteryRemovalUsesDCHeroAndNoBatteryStats() {
        let sections = DashboardSections(capabilities: .dcOnly)

        XCTAssertTrue(sections.contains(.dcHero))
        XCTAssertFalse(sections.contains(.batteryHero))
        XCTAssertFalse(sections.contains(.batteryStats))
    }

    func testFullyCapableDeviceUsesBatteryHeroAndAllCards() {
        let sections = DashboardSections(capabilities: .all)

        XCTAssertEqual(
            sections,
            [.batteryHero, .batteryStats, .dcCard, .usbCard, .limitsLink]
        )
    }

    func testPowerLimitsAreAbsentWhenFeatureIsUnsupported() {
        let sections = DashboardSections(
            capabilities: .init(
                hasBattery: true,
                hasDCPort: true,
                hasUSBPort: true,
                hasPowerLimits: false
            )
        )

        XCTAssertTrue(sections.contains(.usbCard))
        XCTAssertFalse(sections.contains(.limitsLink))
    }

    func testDeviceWithNoPresentationCapabilitiesHasNoSections() {
        XCTAssertTrue(DashboardSections(capabilities: .none).isEmpty)
    }
}
