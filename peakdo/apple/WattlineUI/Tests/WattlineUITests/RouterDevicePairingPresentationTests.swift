import XCTest
@testable import WattlineUI

final class RouterDevicePairingPresentationTests: XCTestCase {
    func testRowsAreDeterministicAndExposeRSSIAndPairedMarker() {
        let rows = RouterDevicePairingPresentation.rows(stage: "idle", devices: [
            .init(mac: "BB", name: "Zulu", rssi: -80, paired: false),
            .init(mac: "AA", name: "Alpha", rssi: -42, paired: true),
        ])
        XCTAssertEqual(rows.map(\.title), ["Alpha", "Zulu"])
        XCTAssertEqual(rows.map(\.detail), ["-42 dBm · Paired", "-80 dBm"])
    }

    func testBusyTerminalAndErrorText() {
        XCTAssertEqual(RouterDevicePairingPresentation.statusText(stage: "scanning", target: nil, error: nil), "Scanning for Link-Power devices…")
        XCTAssertEqual(RouterDevicePairingPresentation.statusText(stage: "pairing", target: "AA", error: nil), "Pairing AA…")
        XCTAssertEqual(RouterDevicePairingPresentation.statusText(stage: "paired", target: "AA", error: nil), "Paired with AA")
        XCTAssertEqual(RouterDevicePairingPresentation.statusText(stage: "error", target: nil, error: "pair_failed"), "Pairing failed.")
    }

    func testPINValidationMirrorsRouterCompatibilityContract() {
        XCTAssertTrue(RouterDevicePairingPresentation.isValidPIN(""))
        XCTAssertTrue(RouterDevicePairingPresentation.isValidPIN("7"))
        XCTAssertTrue(RouterDevicePairingPresentation.isValidPIN("020555"))
        XCTAssertFalse(RouterDevicePairingPresentation.isValidPIN("1234567"))
        XCTAssertFalse(RouterDevicePairingPresentation.isValidPIN("１２３"))
    }

    func testBusyCompositionStructurallyOmitsConflictingActions() {
        XCTAssertEqual(
            RouterDevicePairingPresentation.actions(
                isOperationRunning: true, stage: "idle", hasSelection: true
            ),
            .init(
                showsScan: false, showsSelect: false,
                showsPair: false, showsUnpair: false
            )
        )
        XCTAssertEqual(
            RouterDevicePairingPresentation.actions(
                isOperationRunning: false, stage: "idle", hasSelection: true
            ),
            .init(
                showsScan: true, showsSelect: true,
                showsPair: true, showsUnpair: true
            )
        )
    }

    func testAuthoritativeBusyStageStructurallyOmitsEveryConflictingAction() {
        for stage in ["scanning", "pairing"] {
            XCTAssertEqual(
                RouterDevicePairingPresentation.actions(
                    isOperationRunning: false, stage: stage, hasSelection: true
                ),
                .init(
                    showsScan: false, showsSelect: false,
                    showsPair: false, showsUnpair: false
                ),
                "authoritative \(stage) must remain busy after the local request returns"
            )
        }
    }

    func testPresentationValuesCannotContainPIN() {
        let value = RouterPairableDeviceValue(mac: "AA", name: "PeakDo", rssi: -50, paired: false)
        XCTAssertFalse(String(reflecting: value).localizedCaseInsensitiveContains("pin"))
        XCTAssertFalse(Mirror(reflecting: value).children.contains { $0.label?.localizedCaseInsensitiveContains("pin") == true })
    }
}
