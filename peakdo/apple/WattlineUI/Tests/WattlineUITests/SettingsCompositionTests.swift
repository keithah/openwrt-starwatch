import WattlineCore
@testable import WattlineUI
import XCTest

final class SettingsCompositionTests: XCTestCase {
    func testUnsupportedSettingsControlsAreAbsentButRestartRemains() {
        let value = SettingsComposition(
            capabilities: DeviceCapabilities(features: []),
            isApplicationMode: true
        )

        XCTAssertEqual(value.rows, [.deviceInfo, .clock, .restart])
        XCTAssertFalse(value.rows.contains(.dcPort))
        XCTAssertFalse(value.rows.contains(.bypass))
        XCTAssertFalse(value.rows.contains(.shutdown))
    }

    func testShutdownBitAddsOnlyShutdown() {
        let value = SettingsComposition(
            capabilities: DeviceCapabilities(features: [.shutdown]),
            isApplicationMode: true
        )

        XCTAssertEqual(value.rows, [.deviceInfo, .clock, .restart, .shutdown])
        XCTAssertFalse(value.rows.contains(.dcPort))
        XCTAssertFalse(value.rows.contains(.bypass))
    }

    func testDCPortRequiresBothPortAndControlFeatures() {
        XCTAssertFalse(composition(features: [.dcPort]).rows.contains(.dcPort))
        XCTAssertFalse(composition(features: [.dcControl]).rows.contains(.dcPort))
        XCTAssertTrue(composition(features: [.dcPort, .dcControl]).rows.contains(.dcPort))
    }

    func testBypassRequiresBothPresentationAndControlFeatures() {
        XCTAssertFalse(composition(features: [.dcBypass]).rows.contains(.bypass))
        XCTAssertFalse(composition(features: [.dcBypassControl]).rows.contains(.bypass))
        XCTAssertTrue(composition(features: [.dcBypass, .dcBypassControl]).rows.contains(.bypass))
    }

    func testOTAModeContainsNoSettingsActions() {
        let value = SettingsComposition(
            capabilities: DeviceCapabilities(features: [
                .dcPort, .dcControl, .dcBypass, .dcBypassControl, .shutdown,
            ]),
            isApplicationMode: false
        )

        XCTAssertEqual(value.rows, [.deviceInfo])
    }

    func testAdministratorClockControlIsStructurallyAbsentForPairedRouterClient() {
        let value = SettingsComposition(
            capabilities: DeviceCapabilities(features: [.batteryCapacity]),
            isApplicationMode: true,
            supportsManualClock: false
        )

        XCTAssertFalse(value.rows.contains(.clock))
        XCTAssertTrue(value.rows.contains(.systemSurfaces))
    }

    private func composition(features: FeatureFlags) -> SettingsComposition {
        SettingsComposition(
            capabilities: DeviceCapabilities(features: features),
            isApplicationMode: true
        )
    }
}
