import XCTest
@testable import WattlineUI

final class CapabilityCompositionTests: XCTestCase {
    func testUSBRemovalRemovesCardLimitsAndToggle() {
        let sections = DashboardSections(
            capabilities: .init(
                hasBattery: true,
                hasDCPort: true,
                hasDCControl: true,
                hasUSBPort: false,
                hasUSBOutputControl: false,
                hasPowerLimits: false
            )
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
            Array(sections),
            [.batteryHero, .batteryStats, .dcCard, .usbCard, .limitsLink]
        )
        XCTAssertEqual(sections.controlPresentation(for: .dc), .toggle)
        XCTAssertEqual(sections.controlPresentation(for: .usb), .toggle)
    }

    func testPowerLimitsAreAbsentWhenFeatureIsUnsupported() {
        let sections = DashboardSections(
            capabilities: .init(
                hasBattery: true,
                hasDCPort: true,
                hasDCControl: true,
                hasUSBPort: true,
                hasUSBOutputControl: true,
                hasPowerLimits: false
            )
        )

        XCTAssertTrue(sections.contains(.usbCard))
        XCTAssertFalse(sections.contains(.limitsLink))
    }

    func testDeviceWithNoPresentationCapabilitiesHasNoSections() {
        XCTAssertTrue(DashboardSections(capabilities: .none).isEmpty)
    }

    func testDCPortWithoutControlKeepsCardButHidesToggle() {
        let sections = DashboardSections(
            capabilities: .init(
                hasBattery: false,
                hasDCPort: true,
                hasDCControl: false,
                hasUSBPort: false,
                hasUSBOutputControl: false,
                hasPowerLimits: false
            )
        )

        XCTAssertTrue(sections.contains(.dcCard))
        XCTAssertEqual(sections.controlPresentation(for: .dc), .hidden)
    }

    func testUSBPortWithoutOutputControlKeepsCardButHidesToggle() {
        let sections = DashboardSections(
            capabilities: .init(
                hasBattery: true,
                hasDCPort: false,
                hasDCControl: false,
                hasUSBPort: true,
                hasUSBOutputControl: false,
                hasPowerLimits: true
            )
        )

        XCTAssertTrue(sections.contains(.usbCard))
        XCTAssertEqual(sections.controlPresentation(for: .usb), .hidden)
        XCTAssertTrue(sections.contains(.limitsLink))
    }
}
