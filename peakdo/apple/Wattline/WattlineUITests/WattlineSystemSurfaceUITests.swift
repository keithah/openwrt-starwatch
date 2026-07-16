import XCTest

@MainActor
final class WattlineSystemSurfaceUITests: XCTestCase {
    func testDemoSettingsExposeSystemSurfacePreferencesAndNoTimers() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetOnboarding"]
        app.launch()
        app.buttons["Try Demo Mode"].tap()
        app.tabBars.buttons["Settings"].tap()

        XCTAssertTrue(app.staticTexts["DEMO"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["System Surfaces"].exists)
        XCTAssertTrue(app.switches["Live Activity while charging"].exists)
        XCTAssertTrue(app.switches["Live Activity while discharging"].exists)
        XCTAssertTrue(app.switches["Low-battery notifications"].exists)
        XCTAssertFalse(app.tabBars.buttons["Timers"].exists)
    }
}
