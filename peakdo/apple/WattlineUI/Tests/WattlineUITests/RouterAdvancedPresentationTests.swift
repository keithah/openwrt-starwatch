import XCTest
@testable import WattlineUI

final class RouterAdvancedPresentationTests: XCTestCase {
    func testEveryOuterGateMakesAllSurfacesAbsent() {
        let baseline = input()
        XCTAssertTrue(RouterAdvancedVisibility.evaluate(input(adminVerified: false)).surfaces.isEmpty)
        XCTAssertTrue(RouterAdvancedVisibility.evaluate(input(advanced: false)).surfaces.isEmpty)
        XCTAssertTrue(RouterAdvancedVisibility.evaluate(input(mode: .ota)).surfaces.isEmpty)
        XCTAssertEqual(RouterAdvancedVisibility.evaluate(baseline).surfaces, Set(RouterAdvancedSurface.allCases))
    }

    func testFeatureAndInventoryIntersectPerSurface() {
        let result = RouterAdvancedVisibility.evaluate(input(
            hasRunningMode: false,
            hasBarrierFree: true,
            hasUSBFirmware: false,
            hasBLEPIN: true,
            hasBypassControl: true,
            currentTimeAvailable: true,
            dcAvailable: true,
            usbAvailable: true
        ))
        XCTAssertEqual(result.surfaces, [.bypassThreshold, .clock, .barrierFree, .blePIN])

        XCTAssertFalse(RouterAdvancedVisibility.evaluate(input(dcAvailable: false)).surfaces.contains(.bypassThreshold))
        XCTAssertFalse(RouterAdvancedVisibility.evaluate(input(hasBypassControl: false)).surfaces.contains(.bypassThreshold))
        XCTAssertFalse(RouterAdvancedVisibility.evaluate(input(currentTimeAvailable: false)).surfaces.contains(.clock))
        XCTAssertFalse(RouterAdvancedVisibility.evaluate(input(hasRunningMode: false)).surfaces.contains(.runningMode))
        XCTAssertFalse(RouterAdvancedVisibility.evaluate(input(hasBarrierFree: false)).surfaces.contains(.barrierFree))
        XCTAssertFalse(RouterAdvancedVisibility.evaluate(input(hasUSBFirmware: false)).surfaces.contains(.usbFirmware))
        XCTAssertFalse(RouterAdvancedVisibility.evaluate(input(hasBLEPIN: false)).surfaces.contains(.blePIN))
        XCTAssertFalse(RouterAdvancedVisibility.evaluate(input(usbAvailable: false)).surfaces.contains(.usbFirmware))
    }

    func testCapabilityUnsupportedRemovesOnlyAffectedSurface() {
        let result = RouterAdvancedVisibility.evaluate(input(unsupported: [.barrierFree]))
        XCTAssertFalse(result.surfaces.contains(.barrierFree))
        XCTAssertTrue(result.surfaces.contains(.runningMode))
        XCTAssertTrue(result.surfaces.contains(.blePIN))
    }

    func testAdvancedDisabledShowsEnableAffordanceAndNoControls() {
        for disabled in [input(advanced: false), input(serverGate: .advancedDisabled)] {
            let result = RouterAdvancedVisibility.evaluate(disabled)
            XCTAssertTrue(result.surfaces.isEmpty)
            XCTAssertTrue(result.showsEnableAdvancedAffordance)
        }
        XCTAssertFalse(RouterAdvancedVisibility.evaluate(input(adminVerified: false)).showsEnableAdvancedAffordance)
        XCTAssertFalse(RouterAdvancedVisibility.evaluate(input(mode: .ota)).showsEnableAdvancedAffordance)
    }

    func testRunningModeAndBLEPINRequirePurposeSpecificConfirmation() {
        XCTAssertEqual(RouterAdvancedConfirmation.required(for: .runningMode), .runningMode)
        XCTAssertEqual(RouterAdvancedConfirmation.required(for: .blePIN), .blePIN)
        for surface in RouterAdvancedSurface.allCases where surface != .runningMode && surface != .blePIN {
            XCTAssertNil(RouterAdvancedConfirmation.required(for: surface))
        }
    }

    func testPresentationValuesRetainOnlyObservedNonSecretResults() {
        let values = RouterAdvancedValues(
            bypassThresholdVolts: 19.5,
            clock: .init(available: true, deviceTime: "2026-07-20T00:00:00Z", systemTime: "2026-07-20T00:00:02Z", driftSeconds: -2),
            runningMode: 1,
            barrierFreeEnabled: false,
            usbFirmware: .init(raw: "010409", major: 1, minor: 4, patch: 9),
            blePINUpdated: true
        )
        XCTAssertEqual(values.bypassThresholdVolts, 19.5)
        XCTAssertEqual(values.barrierFreeEnabled, false)
        XCTAssertEqual(values.usbFirmware?.displayVersion, "1.4.9")
        XCTAssertEqual(values.blePINUpdated, true)
        XCTAssertFalse(String(reflecting: values).contains("020555"))
    }

    func testBLEPINSecretClearsWhenItsSurfaceBecomesAbsent() {
        XCTAssertFalse(RouterAdvancedSecretPolicy.shouldClearBLEPIN(
            wasVisible: true,
            isVisible: true
        ))
        XCTAssertTrue(RouterAdvancedSecretPolicy.shouldClearBLEPIN(
            wasVisible: true,
            isVisible: false
        ))
        XCTAssertFalse(RouterAdvancedSecretPolicy.shouldClearBLEPIN(
            wasVisible: false,
            isVisible: false
        ))
    }

    private func input(
        adminVerified: Bool = true,
        advanced: Bool = true,
        mode: RouterAdvancedApplicationMode = .application,
        hasRunningMode: Bool = true,
        hasBarrierFree: Bool = true,
        hasUSBFirmware: Bool = true,
        hasBLEPIN: Bool = true,
        hasBypassControl: Bool = true,
        currentTimeAvailable: Bool = true,
        dcAvailable: Bool = true,
        usbAvailable: Bool = true,
        unsupported: Set<RouterAdvancedSurface> = [],
        serverGate: RouterAdvancedServerGate = .allowed
    ) -> RouterAdvancedVisibilityInput {
        RouterAdvancedVisibilityInput(
            adminVerified: adminVerified,
            advanced: advanced,
            mode: mode,
            hasRunningMode: hasRunningMode,
            hasBarrierFree: hasBarrierFree,
            hasUSBFirmware: hasUSBFirmware,
            hasBLEPIN: hasBLEPIN,
            hasBypassControl: hasBypassControl,
            currentTimeAvailable: currentTimeAvailable,
            dcAvailable: dcAvailable,
            usbAvailable: usbAvailable,
            unsupported: unsupported,
            serverGate: serverGate
        )
    }
}
