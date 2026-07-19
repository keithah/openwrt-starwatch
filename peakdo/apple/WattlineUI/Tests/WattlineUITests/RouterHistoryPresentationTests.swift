import Foundation
import XCTest
@testable import WattlineUI

final class RouterHistoryPresentationTests: XCTestCase {
    func testPointsSortAscendingAndPowerAggregatesWithoutFabrication() {
        let earlier = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 1_060)
        let presentation = RouterHistoryPresentation(
            points: [
                RouterHistoryPoint(at: later, level: 76, dcWatts: nil, typeCWatts: nil),
                RouterHistoryPoint(at: earlier, level: 77, dcWatts: 12.0, typeCWatts: 20.0),
            ],
            fetchedAt: later
        )

        XCTAssertFalse(presentation.isEmpty)
        XCTAssertEqual(presentation.points.map(\.at), [earlier, later])
        XCTAssertEqual(presentation.powerPoints, [
            RouterHistoryPowerPoint(at: earlier, watts: 32.0),
            RouterHistoryPowerPoint(at: later, watts: nil),
        ])
        XCTAssertEqual(presentation.fetchedAt, later)
    }

    func testSingleNilSideStillAggregatesAndEmptyStateIsHonest() {
        let at = Date(timeIntervalSince1970: 2_000)
        let presentation = RouterHistoryPresentation(
            points: [RouterHistoryPoint(at: at, level: 50, dcWatts: nil, typeCWatts: 7.5)],
            fetchedAt: nil
        )
        XCTAssertEqual(presentation.powerPoints, [
            RouterHistoryPowerPoint(at: at, watts: 7.5)
        ])

        let empty = RouterHistoryPresentation(points: [], fetchedAt: nil)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertNil(empty.fetchedAt)
    }
}
