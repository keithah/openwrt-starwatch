import Foundation
import XCTest
@testable import WattlineNetwork

final class RouterPairingInputTests: XCTestCase {
    private let first = "wattline://pair?v=1&id=DC045AEB722B&host=router.local&http=8377&pin=123456"

    func testTextInputTrimsPasteWhitespaceAndRedactsThePairingSecret() throws {
        let input = try RouterPairingInputParser.parse(text: "  \n\(first)\n")

        XCTAssertEqual(input.payload.deviceID, "DC045AEB722B")
        XCTAssertEqual(input.payload.host, "router.local")
        XCTAssertFalse(String(describing: input).contains("123456"))
        XCTAssertFalse(String(reflecting: input).contains("123456"))
        var dumped = ""
        dump(input, to: &dumped)
        XCTAssertFalse(dumped.contains("123456"))
    }

    func testInputRejectsUnknownQueryFieldsAndNonPairingText() throws {
        XCTAssertThrowsError(try RouterPairingInputParser.parse(text: first + "&extra=x"))
        XCTAssertThrowsError(try RouterPairingInputParser.parse(text: "not a pairing URL"))
    }
}
