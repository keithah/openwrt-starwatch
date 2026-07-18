import Foundation
import XCTest
@testable import Wattline

@MainActor
final class RouterEnrollmentRouteTests: XCTestCase {
    func testNewPairingLinkReplacesPriorSecretAndClearRemovesIt() throws {
        let first = try XCTUnwrap(URL(string:
            "wattline://pair?v=1&id=DC045AEB722B&host=first.local&http=8377&pin=123456"
        ))
        let second = try XCTUnwrap(URL(string:
            "wattline://pair?v=1&id=AABBCCDDEEFF&host=second.local&http=8377&pin=654321"
        ))
        let route = RouterEnrollmentRoute()

        XCTAssertTrue(route.consume(first))
        XCTAssertEqual(route.payload?.deviceID, "DC045AEB722B")
        XCTAssertTrue(route.consume(second))
        XCTAssertEqual(route.payload?.deviceID, "AABBCCDDEEFF")
        XCTAssertFalse(String(describing: route).contains("654321"))

        route.clear()
        XCTAssertNil(route.payload)
    }

    func testNonPairingURLDoesNotReplaceCurrentRoute() throws {
        let route = RouterEnrollmentRoute()
        XCTAssertTrue(route.consume(URL(string:
            "wattline://pair?v=1&id=DC045AEB722B&host=first.local&http=8377&pin=123456"
        )!))

        XCTAssertFalse(route.consume(URL(string: "wattline://dashboard")!))
        XCTAssertEqual(route.payload?.deviceID, "DC045AEB722B")
    }
}
