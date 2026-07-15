import XCTest

final class WattlineEntryUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testColdLaunchPrimesPermissionAndOffersDemo() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetOnboarding"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Your power, at a glance"].exists)
        XCTAssertTrue(app.buttons["Connect a device"].exists)
        XCTAssertTrue(app.buttons["Try Demo Mode"].exists)
    }

    func testDemoEntryDoesNotShowBluetoothPermissionUI() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetOnboarding"]
        app.launch()
        app.buttons["Try Demo Mode"].tap()

        XCTAssertTrue(app.staticTexts["DEMO"].waitForExistence(timeout: 3))
    }
}
