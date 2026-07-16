import XCTest

@MainActor
final class WattlineDashboardUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDemoDashboardControlsAndLimitsAreReachable() {
        let app = launchInDemoMode()

        XCTAssertTrue(app.switches["DC Port"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.switches["USB-C Output"].exists)
        app.buttons["USB-C Power Limits"].tap()
        XCTAssertTrue(app.sliders["Global limit"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Runtime limit"].exists)
    }

    func testConnectedShellHasOnlyPhaseTwoTabsAndRetainsDemoBadge() {
        let app = launchInDemoMode()

        XCTAssertFalse(app.tabBars.buttons["Timers"].exists)
        for tab in ["Home", "Shortcuts", "Settings"] {
            app.tabBars.buttons[tab].tap()
            XCTAssertTrue(app.staticTexts["DEMO"].exists)
        }
    }

    private func launchInDemoMode() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetOnboarding"]
        app.launch()
        app.buttons["Try Demo Mode"].tap()
        return app
    }
}
