import WattlineCore
import XCTest
@testable import WattlineNetwork

final class RouterCapabilitiesTests: XCTestCase {
    func testFeatureAndEndpointMustBothAllowSurface() {
        let features: FeatureFlags = [
            .dcControl, .usbOutputControl, .usbPowerLimit,
            .dcBypassControl, .dcScheduler, .shutdown,
        ]
        let capabilities = RouterCapabilities(
            features: features.rawValue,
            endpoints: [.actions, .usbCLimit, .schedules]
        )

        XCTAssertTrue(capabilities.supports(.dcControl))
        XCTAssertTrue(capabilities.supports(.typeCOutput))
        XCTAssertTrue(capabilities.supports(.powerLimits))
        XCTAssertTrue(capabilities.supports(.schedules))
        XCTAssertTrue(capabilities.supports(.restart))
        XCTAssertTrue(capabilities.supports(.shutdown))
        XCTAssertTrue(capabilities.supports(.bypassControl))
        XCTAssertFalse(capabilities.supports(.bypassThreshold))

        let withoutActions = RouterCapabilities(
            features: features.rawValue,
            endpoints: [.usbCLimit, .schedules]
        )
        XCTAssertFalse(withoutActions.supports(.dcControl), "feature alone must not expose a missing endpoint")
    }

    func testEndpointAloneCannotOverrideMissingFeature() {
        let capabilities = RouterCapabilities(
            features: FeatureFlags.dcPort.rawValue,
            endpoints: [.actions, .usbCLimit, .bypassThreshold, .schedules]
        )

        for surface in RouterSurfaceCapability.allCases {
            XCTAssertFalse(capabilities.supports(surface), "unsupported \(surface) must remain structurally absent")
        }
        XCTAssertTrue(capabilities.supportedSurfaces.isEmpty)
    }

    func testSupportedSurfacesContainsOnlyFeatureEndpointIntersection() {
        let features: FeatureFlags = [.dcControl, .dcBypassControl, .dcScheduler]
        let capabilities = RouterCapabilities(
            features: features.rawValue,
            endpoints: [.actions, .bypassThreshold]
        )

        XCTAssertEqual(capabilities.supportedSurfaces, [.dcControl, .bypassControl, .bypassThreshold])
        XCTAssertFalse(capabilities.supportedSurfaces.contains(.schedules))
    }
}
