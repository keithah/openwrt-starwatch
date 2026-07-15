import XCTest
import WattlineCore
@testable import WattlineUI

final class CapabilityCompositionTests: XCTestCase {
    @MainActor
    func testOptionalTelemetryIndicatorsRequireTheirFeatureBits() throws {
        let withoutIndicators = DashboardCapabilities(DeviceCapabilities(features: [.dcPort, .usbPort]))
        XCTAssertFalse(withoutIndicators.hasBypass)
        XCTAssertFalse(withoutIndicators.showsDCInput)

        let withIndicators = DashboardCapabilities(DeviceCapabilities(features: [
            .dcPort, .dcBypass, .usbPort, .usbDCInput,
        ]))
        XCTAssertTrue(withIndicators.hasBypass)
        XCTAssertTrue(withIndicators.showsDCInput)

        let dc = try DCPortStatus(frame: Data([1, 0, 0, 0, 0, 0, 0, 0, 1]))
        XCTAssertNil(PortCard(dcStatus: dc, showsBypass: false).detail)
        XCTAssertEqual(PortCard(dcStatus: dc, showsBypass: true).detail, "Bypass")

        let typeC = try TypeCPortStatus(frame: Data([1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]))
        XCTAssertFalse(PortCard(typeCStatus: typeC, showsDCInput: false).detail?.contains("DC input") == true)
        XCTAssertTrue(PortCard(typeCStatus: typeC, showsDCInput: true).detail?.contains("DC input") == true)
    }

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
