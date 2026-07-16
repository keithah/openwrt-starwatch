import Foundation
import XCTest

final class Phase2ProjectConfigurationTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // WattlineTests
            .deletingLastPathComponent() // Wattline
    }

    func testWidgetTargetConfigurationAndEmbeddingAreDeclared() throws {
        let project = try String(contentsOf: root.appendingPathComponent("Wattline.xcodeproj/project.pbxproj"), encoding: .utf8)
        XCTAssertTrue(project.contains("WattlineWidgets"))
        XCTAssertTrue(project.contains("com.apple.product-type.app-extension"))
        XCTAssertTrue(project.contains("com.keithah.wattline.widgets"))
        XCTAssertTrue(project.contains("com.keithah.wattline.mac.widgets"))
        XCTAssertTrue(project.contains("WattlineWidgets/WattlineWidgets.entitlements"))
        XCTAssertTrue(project.contains("WattlineWidgets in Embed Foundation Extensions"))
        XCTAssertTrue(project.contains("Embed Foundation Extensions"))
    }

    func testWidgetDeploymentFloorsAndProductsAreConfigured() throws {
        let project = try String(contentsOf: root.appendingPathComponent("Wattline.xcodeproj/project.pbxproj"), encoding: .utf8)
        XCTAssertTrue(project.contains("IPHONEOS_DEPLOYMENT_TARGET = 17.0"))
        XCTAssertTrue(project.contains("MACOSX_DEPLOYMENT_TARGET = 14.0"))
        XCTAssertTrue(project.contains("WattlineCore in Frameworks"))
        XCTAssertTrue(project.contains("WattlineUI in Frameworks"))
    }

    func testAppGroupAndLiveActivitiesPlistConfiguration() throws {
        let entitlements = try String(contentsOf: root.appendingPathComponent("WattlineWidgets/WattlineWidgets.entitlements"), encoding: .utf8)
        XCTAssertTrue(entitlements.contains("group.com.keithah.wattline"))
        let plist = try NSDictionary(contentsOf: root.appendingPathComponent("Wattline/Info.plist"), error: ())
        XCTAssertEqual(plist["NSSupportsLiveActivities"] as? Bool, true)
    }
}
