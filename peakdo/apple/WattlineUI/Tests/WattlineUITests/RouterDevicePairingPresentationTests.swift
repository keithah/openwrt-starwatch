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
        XCTAssertEqual(RouterDevicePairingPresentation.statusText(stage: "connected", target: "AA", error: nil), "Connected to AA")
        XCTAssertEqual(RouterDevicePairingPresentation.statusText(stage: "failed", target: nil, error: "pair_failed"), "Pairing failed.")
    }

    func testPresentationValuesCannotContainPIN() {
        let value = RouterPairableDeviceValue(mac: "AA", name: "PeakDo", rssi: -50, paired: false)
        XCTAssertFalse(String(reflecting: value).localizedCaseInsensitiveContains("pin"))
        XCTAssertFalse(Mirror(reflecting: value).children.contains { $0.label?.localizedCaseInsensitiveContains("pin") == true })
    }
}
