import Foundation
import XCTest

@MainActor
final class WattlineDemoUITests: XCTestCase {
    private let screenshotDirectory = URL(fileURLWithPath: "/tmp/task11-screenshots-final", isDirectory: true)

    override func setUpWithError() throws {
        continueAfterFailure = false
        try FileManager.default.createDirectory(
            at: screenshotDirectory,
            withIntermediateDirectories: true
        )
    }

    func testDemoModeDrivesEveryPhase1Surface() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-resetOnboarding", "-resetHeroStyle"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Your power, at a glance"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Connect a device"].exists)
        XCTAssertTrue(app.buttons["Try Demo Mode"].exists)
        XCTAssertEqual(app.alerts.count, 0, "Demo entry must not require Bluetooth permission")
        try capture("onboarding", app: app)

        app.buttons["Try Demo Mode"].tap()
        let hero = app.descendants(matching: .any)["Battery hero"]
        XCTAssertTrue(hero.waitForExistence(timeout: 3))
        XCTAssertTrue(String(describing: hero.value).contains("62"))
        XCTAssertTrue(String(describing: hero.value).localizedCaseInsensitiveContains("discharging"))
        XCTAssertTrue(app.staticTexts["DEMO"].exists)
        XCTAssertTrue(app.staticTexts["Segmented battery meter"].exists)
        try capture("dashboard-discharging", app: app)

        let dc = app.switches["DC Port"]
        XCTAssertTrue(dc.exists)
        let dcInitial = String(describing: dc.value)
        dc.tap()
        waitForValue(of: dc, differentFrom: dcInitial)

        let usb = app.switches["USB-C Output"]
        XCTAssertTrue(usb.exists)
        let usbInitial = String(describing: usb.value)
        usb.tap()
        waitForValue(of: usb, differentFrom: usbInitial)

        app.buttons["Demo charger"].tap()
        XCTAssertTrue(app.buttons["Unplug charger"].waitForExistence(timeout: 3))
        waitForValue(of: hero, containing: "charging")
        app.swipeDown()
        app.swipeDown()
        XCTAssertTrue(hero.isHittable)
        try capture("dashboard-charging", app: app)

        hero.press(forDuration: 1.1)
        XCTAssertTrue(app.staticTexts["Gauge battery meter"].waitForExistence(timeout: 3))
        XCTAssertTrue(hero.isHittable)
        try capture("dashboard-gauge", app: app)

        app.buttons["USB-C Power Limits"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["Limits screen"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.tabBars.firstMatch.exists, "The tab bar must not cover limits controls")
        for label in ["Global", "Input", "Output"] {
            let slider = app.sliders["\(label) limit"]
            XCTAssertTrue(slider.exists)
            waitForValue(of: slider, containing: "140")
            slider.adjust(toNormalizedSliderPosition: 0)
            waitForValue(of: slider, containing: "30")
            XCTAssertTrue(app.buttons["Reset \(label) limit"].exists)
        }
        app.buttons["Reset Input limit"].tap()
        waitForValue(of: app.sliders["Input limit"], containing: "65")
        XCTAssertTrue(app.staticTexts["Runtime limit"].exists)
        XCTAssertFalse(app.sliders["Runtime limit"].exists)
        try capture("limits", app: app)

        app.navigationBars.buttons.firstMatch.tap()
        waitForValue(of: hero, containing: "30.0 watts")
        XCTAssertFalse(app.tabBars.buttons["Timers"].exists)
        for tab in ["Home", "Shortcuts", "Settings"] {
            app.tabBars.buttons[tab].tap()
            XCTAssertTrue(app.staticTexts["DEMO"].waitForExistence(timeout: 3))
            if tab == "Shortcuts" {
                XCTAssertTrue(app.staticTexts["Coming in Phase 2"].exists)
            }
            try capture("tab-\(tab.lowercased())", app: app)
        }

        app.buttons["Connect a real device"].tap()
        XCTAssertFalse(app.staticTexts["DEMO"].waitForExistence(timeout: 2))
    }

    func testGaugeHeroStylePersistsAcrossDemoRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetOnboarding", "-resetHeroStyle"]
        app.launch()
        app.buttons["Try Demo Mode"].tap()
        let hero = app.descendants(matching: .any)["Battery hero"]
        XCTAssertTrue(hero.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Segmented battery meter"].exists)

        hero.press(forDuration: 1.1)
        XCTAssertTrue(app.staticTexts["Gauge battery meter"].waitForExistence(timeout: 3))

        app.terminate()
        app.launchArguments = ["-resetOnboarding"]
        app.launch()
        app.buttons["Try Demo Mode"].tap()
        XCTAssertTrue(app.staticTexts["Gauge battery meter"].waitForExistence(timeout: 3))
    }

    func testLimitsScreenHidesTabBarFromControls() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetOnboarding", "-resetHeroStyle"]
        app.launch()
        app.buttons["Try Demo Mode"].tap()
        XCTAssertTrue(app.buttons["USB-C Power Limits"].waitForExistence(timeout: 3))

        app.buttons["USB-C Power Limits"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["Limits screen"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.tabBars.firstMatch.exists, "The tab bar must not cover limits controls")
    }

    private func waitForValue(of element: XCUIElement, containing text: String) {
        let predicate = NSPredicate(format: "value CONTAINS[c] %@", text)
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 3),
            .completed
        )
    }

    private func waitForValue(of element: XCUIElement, differentFrom value: String) {
        let predicate = NSPredicate(format: "value != %@", value)
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 3),
            .completed
        )
    }

    private func capture(_ name: String, app _: XCUIApplication) throws {
        let screenshot = XCUIScreen.main.screenshot()
        try screenshot.pngRepresentation.write(to: screenshotDirectory.appendingPathComponent("\(name).png"))
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
