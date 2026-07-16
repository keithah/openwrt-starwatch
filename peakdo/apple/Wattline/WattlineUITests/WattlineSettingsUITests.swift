import XCTest

@MainActor
final class WattlineSettingsUITests: XCTestCase {
    func testSettingsExposesRestartAndShutdownWithoutTimers() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetOnboarding"]
        app.launch()
        app.buttons["Try Demo Mode"].tap()
        app.tabBars.buttons["Settings"].tap()

        XCTAssertTrue(app.buttons["Restart"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Shut Down"].exists)
        XCTAssertFalse(app.tabBars.buttons["Timers"].exists)
    }

    func testShutdownRequiresConfirmationAndCancelLeavesSettingsVisible() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetOnboarding"]
        app.launch()
        app.buttons["Try Demo Mode"].tap()
        app.tabBars.buttons["Settings"].tap()

        app.buttons["Shut Down"].tap()
        XCTAssertTrue(app.alerts["Shut down this device?"].waitForExistence(timeout: 2))
        app.alerts["Shut down this device?"].buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Restart"].exists)
    }
}
