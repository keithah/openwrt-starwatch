import WattlineCore
import XCTest
@testable import WattlineNetwork

final class RouterCapabilitiesTests: XCTestCase {
    func testFeatureAndEndpointMustBothAllowSurface() {
        let features: FeatureFlags = [
            .dcControl, .usbOutputControl, .usbPowerLimit,
            .dcBypassControl, .shutdown,
        ]
        let capabilities = RouterCapabilities(
            features: features.rawValue,
            endpoints: [.controls, .usbCLimit]
        )

        XCTAssertTrue(capabilities.supports(.dcControl))
        XCTAssertTrue(capabilities.supports(.typeCOutput))
        XCTAssertTrue(capabilities.supports(.powerLimits))
        XCTAssertTrue(capabilities.supports(.restart))
        XCTAssertTrue(capabilities.supports(.shutdown))
        XCTAssertTrue(capabilities.supports(.bypassControl))

        let withoutActions = RouterCapabilities(
            features: features.rawValue,
            endpoints: [.usbCLimit]
        )
        XCTAssertFalse(withoutActions.supports(.dcControl), "feature alone must not expose a missing endpoint")
    }

    func testEndpointAloneCannotOverrideMissingFeature() {
        let capabilities = RouterCapabilities(
            features: FeatureFlags.dcPort.rawValue,
            endpoints: [.controls, .usbCLimit]
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
            endpoints: [.controls]
        )

        XCTAssertEqual(capabilities.supportedSurfaces, [.dcControl, .bypassControl])
    }
}
