import Foundation
import XCTest
@testable import WattlineUI

final class RouterHistoryPresentationTests: XCTestCase {
    func testScreenPresentationDistinguishesEveryEmptyLoadState() {
        let history = RouterHistoryPresentation(points: [], fetchedAt: nil)

        let neverLoaded = RouterHistoryScreenPresentation(
            history: history,
            loadState: .neverLoaded
        )
        XCTAssertTrue(neverLoaded.showsNeverLoaded)
        XCTAssertFalse(neverLoaded.showsInitialProgress)
        XCTAssertFalse(neverLoaded.showsSuccessfulEmpty)
        XCTAssertNil(neverLoaded.emptyFailureMessage)

        let loading = RouterHistoryScreenPresentation(
            history: history,
            loadState: .initialLoading
        )
        XCTAssertFalse(loading.showsNeverLoaded)
        XCTAssertTrue(loading.showsInitialProgress)
        XCTAssertFalse(loading.showsSuccessfulEmpty)
        XCTAssertNil(loading.emptyFailureMessage)

        let loaded = RouterHistoryScreenPresentation(
            history: history,
            loadState: .loaded
        )
        XCTAssertFalse(loaded.showsNeverLoaded)
        XCTAssertFalse(loaded.showsInitialProgress)
        XCTAssertTrue(loaded.showsSuccessfulEmpty)
        XCTAssertNil(loaded.emptyFailureMessage)

        let failed = RouterHistoryScreenPresentation(
            history: history,
            loadState: .failed(message: "Could not load router history.")
        )
        XCTAssertFalse(failed.showsNeverLoaded)
        XCTAssertFalse(failed.showsInitialProgress)
        XCTAssertFalse(failed.showsSuccessfulEmpty)
        XCTAssertEqual(failed.emptyFailureMessage, "Could not load router history.")
        XCTAssertFalse(failed.showsCharts)
    }

    func testRefreshingExistingDataKeepsChartsAndShowsRefreshProgress() {
        let at = Date(timeIntervalSince1970: 2_000)
        let history = RouterHistoryPresentation(
            points: [RouterHistoryPoint(
                at: at, level: 50, dcWatts: 4.0, typeCWatts: nil
            )],
            fetchedAt: at
        )
        let refreshing = RouterHistoryScreenPresentation(
            history: history,
            loadState: .refreshing
        )

        XCTAssertTrue(refreshing.showsCharts)
        XCTAssertTrue(refreshing.showsRefreshProgress)
        XCTAssertFalse(refreshing.showsInitialProgress)
        XCTAssertNil(refreshing.failureMessage)

        let failedRefresh = RouterHistoryScreenPresentation(
            history: history,
            loadState: .failed(message: "Refresh failed.")
        )
        XCTAssertTrue(failedRefresh.showsCharts)
        XCTAssertFalse(failedRefresh.showsRefreshProgress)
        XCTAssertEqual(failedRefresh.failureMessage, "Refresh failed.")
        XCTAssertNil(failedRefresh.emptyFailureMessage)
    }

    func testRefreshingSuccessfulEmptyHistoryShowsProgressInsteadOfBlankContent() {
        let presentation = RouterHistoryScreenPresentation(
            history: RouterHistoryPresentation(
                points: [],
                fetchedAt: Date(timeIntervalSince1970: 2_000)
            ),
            loadState: .refreshing
        )

        XCTAssertTrue(presentation.showsEmptyRefreshProgress)
        XCTAssertFalse(presentation.showsInitialProgress)
        XCTAssertFalse(presentation.showsSuccessfulEmpty)
        XCTAssertFalse(presentation.showsCharts)
    }

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
