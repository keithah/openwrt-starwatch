import XCTest

@MainActor
final class WattlineSettingsUITests: XCTestCase {
    func testSettingsExposesRestartAndShutdownWithoutTimers() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetOnboarding"]
        app.launch()
        app.buttons["Try Demo Mode"].tap()
        app.tabBars.buttons["Settings"].tap()

        XCTAssertTrue(app.buttons["Restart"].scrollToExistence(in: app))
        XCTAssertTrue(app.buttons["Shut Down"].scrollToExistence(in: app))
        XCTAssertFalse(app.tabBars.buttons["Timers"].exists)
    }

    func testShutdownRequiresConfirmationAndCancelLeavesSettingsVisible() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetOnboarding"]
        app.launch()
        app.buttons["Try Demo Mode"].tap()
        app.tabBars.buttons["Settings"].tap()

        let shutdown = app.buttons["Shut Down"]
        XCTAssertTrue(shutdown.scrollToExistence(in: app))
        shutdown.tap()
        let confirmation = app.sheets.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 2))
        XCTAssertTrue(confirmation.buttons["Shut Down"].exists)
        app.otherElements["dismiss popup"].tap()
        XCTAssertFalse(confirmation.exists)
        XCTAssertTrue(app.navigationBars["Settings"].exists)
    }
}

extension XCUIElement {
    func scrollToExistence(in app: XCUIApplication, maxSwipes: Int = 8) -> Bool {
        if exists && isHittable { return true }
        for _ in 0..<maxSwipes {
            app.swipeUp()
            if exists && isHittable { return true }
        }
        return false
    }
}
