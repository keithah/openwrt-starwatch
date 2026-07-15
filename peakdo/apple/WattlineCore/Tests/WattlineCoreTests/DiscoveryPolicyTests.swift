import XCTest
@testable import WattlineCore

final class DiscoveryPolicyTests: XCTestCase {
    func testScanFilterAdmitsOnlyApplicationAndOTAAdvertisements() {
        XCTAssertEqual(
            DiscoveryPolicy.resolve(advertisementLocalName: "Link-Power 2", cachedPeripheralName: nil)?.mode,
            .application
        )
        XCTAssertEqual(
            DiscoveryPolicy.resolve(advertisementLocalName: "PeakDo-OTA", cachedPeripheralName: nil)?.mode,
            .ota
        )
        XCTAssertNil(
            DiscoveryPolicy.resolve(advertisementLocalName: "Unrelated", cachedPeripheralName: "Link-Power 2")
        )
    }

    func testFreshAdvertisementNameWinsOverStalePeripheralName() {
        let result = DiscoveryPolicy.resolve(
            advertisementLocalName: "PeakDo-OTA",
            cachedPeripheralName: "Link-Power-2"
        )

        XCTAssertEqual(result?.localName, "PeakDo-OTA")
        XCTAssertEqual(result?.mode, .ota)
    }

    func testCachedNameCannotAdmitUnrelatedAdvertisement() {
        XCTAssertNil(
            DiscoveryPolicy.classify(
                localName: "Other Device",
                cachedPeripheralName: "Link-Power-2"
            )
        )
    }

    func testMissingAdvertisementNameCannotUseCachedName() {
        XCTAssertNil(
            DiscoveryPolicy.classify(
                localName: nil,
                cachedPeripheralName: "Link-Power-2"
            )
        )
    }

    func testApplicationAdvertisementIsClassified() {
        XCTAssertEqual(
            DiscoveryPolicy.classify(localName: "Link-Power-2", cachedPeripheralName: nil),
            .application
        )
    }

    func testOTAModeUsesRecoveryClassificationForBondFailure() {
        XCTAssertEqual(
            OTAConnectionPolicy(mode: .bootloader, errorCode: 14).resolution,
            .showBondRecoveryGuidance
        )
    }

    func testApplicationModeDoesNotMisclassifyBondFailureAsOTARecovery() {
        XCTAssertEqual(
            OTAConnectionPolicy(mode: .application, errorCode: 14).resolution,
            .reportConnectionFailure
        )
    }
}
