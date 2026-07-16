import Foundation
import XCTest

final class Phase2ProjectConfigurationTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // WattlineTests
            .deletingLastPathComponent() // Wattline
    }

    private func projectText() throws -> String {
        try String(contentsOf: root.appendingPathComponent("Wattline.xcodeproj/project.pbxproj"), encoding: .utf8)
    }

    /// Return one Xcode object, rather than searching the entire project. This keeps
    /// configuration assertions mutation-sensitive when another target happens to
    /// contain the same setting.
    private func object(_ id: String, isa: String, in project: String) throws -> String {
        let prefix = "\t\(id) "
        guard let start = project.range(of: prefix)?.lowerBound else {
            throw NSError(domain: "Phase2ProjectConfigurationTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Missing \(isa) object \(id)"])
        }
        guard let end = project[start...].firstIndex(of: "\n") else { return String(project[start...]) }
        let line = String(project[start..<end])
        guard line.contains("{isa = \(isa);") else {
            throw NSError(domain: "Phase2ProjectConfigurationTests", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Object \(id) is not \(isa)"])
        }
        return line
    }

    private func target(_ id: String, in project: String) throws -> String {
        try object(id, isa: "PBXNativeTarget", in: project)
    }

    private func configurations(for target: String, in project: String) throws -> [String] {
        let marker = "buildConfigurationList = "
        guard let range = target.range(of: marker) else { throw NSError(domain: "Phase2ProjectConfigurationTests", code: 2) }
        let suffix = target[range.upperBound...]
        guard let idEnd = suffix.firstIndex(of: ";") else { throw NSError(domain: "Phase2ProjectConfigurationTests", code: 3) }
        let listID = String(suffix[..<idEnd])
        let list = try object(listID, isa: "XCConfigurationList", in: project)
        let ids = list.split(separator: " ").compactMap { token -> String? in
            let value = token.trimmingCharacters(in: CharacterSet(charactersIn: "(),"))
            return value.range(of: "^[A-F0-9]{24}$", options: .regularExpression) != nil ? value : nil
        }
        return try ids.map { try object($0, isa: "XCBuildConfiguration", in: project) }
    }

    func testWidgetTargetConfigurationAndEmbeddingAreDeclared() throws {
        let project = try projectText()
        let widget = try target("A10000000000000000000078", in: project)
        XCTAssertTrue(widget.contains("name = WattlineWidgets;"))
        XCTAssertTrue(widget.contains("productType = \"com.apple.product-type.app-extension\";"))
        XCTAssertTrue(widget.contains("packageProductDependencies = (A10000000000000000000075 /* WattlineCore */, A10000000000000000000076 /* WattlineUI */, );"))
        XCTAssertFalse(widget.contains("A1000000000000000000007E"), "Widget must not embed itself")
        let app = try target("A10000000000000000000020", in: project)
        XCTAssertTrue(app.contains("A1000000000000000000007E"), "Only the iOS app embeds the widget extension")
        for configuration in try configurations(for: app, in: project) {
            XCTAssertTrue(configuration.contains("SUPPORTED_PLATFORMS = \"iphoneos iphonesimulator\";"))
            XCTAssertTrue(configuration.contains("SUPPORTS_MACCATALYST = NO;"))
        }
        XCTAssertTrue(project.contains("A1000000000000000000007E = {isa = PBXCopyFilesBuildPhase;"))
        XCTAssertTrue(project.contains("dstSubfolderSpec = 13;"))
    }

    func testWidgetDeploymentFloorsAndProductsAreConfigured() throws {
        let project = try projectText()
        let widget = try target("A10000000000000000000078", in: project)
        for configuration in try configurations(for: widget, in: project) {
            XCTAssertTrue(configuration.contains("IPHONEOS_DEPLOYMENT_TARGET = 17.0"))
            XCTAssertTrue(configuration.contains("MACOSX_DEPLOYMENT_TARGET = 14.0"))
            XCTAssertTrue(configuration.contains("SUPPORTED_PLATFORMS = \"iphoneos iphonesimulator macosx\";"))
            XCTAssertTrue(configuration.contains("CODE_SIGN_ENTITLEMENTS = WattlineWidgets/WattlineWidgets.entitlements;"))
            XCTAssertTrue(configuration.contains("INFOPLIST_FILE = WattlineWidgets/Info.plist;"))
            XCTAssertTrue(configuration.contains("PRODUCT_BUNDLE_IDENTIFIER = com.keithah.wattline.widgets;"))
            XCTAssertTrue(configuration.contains("\"PRODUCT_BUNDLE_IDENTIFIER[sdk=macosx*]\" = com.keithah.wattline.mac.widgets;"))
        }
        XCTAssertEqual((try configurations(for: widget, in: project)).count, 2)
        XCTAssertTrue(widget.contains("packageProductDependencies = (A10000000000000000000075 /* WattlineCore */, A10000000000000000000076 /* WattlineUI */, );"))
    }

    func testAppGroupAndLiveActivitiesPlistConfiguration() throws {
        let entitlements = try String(contentsOf: root.appendingPathComponent("WattlineWidgets/WattlineWidgets.entitlements"), encoding: .utf8)
        XCTAssertTrue(entitlements.contains("<string>group.com.keithah.wattline</string>"))
        let plist = try NSDictionary(contentsOf: root.appendingPathComponent("Wattline/Info.plist"), error: ())
        XCTAssertEqual(plist["NSSupportsLiveActivities"] as? Bool, true)
    }

    func testWidgetExtensionDeclaresWidgetKitExtensionPoint() throws {
        let plist = try NSDictionary(contentsOf: root.appendingPathComponent("WattlineWidgets/Info.plist"), error: ())
        XCTAssertEqual(plist["CFBundleName"] as? String, "WattlineWidgets")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "$(EXECUTABLE_NAME)")
        let extensionDictionary = try XCTUnwrap(plist["NSExtension"] as? NSDictionary)
        XCTAssertEqual(extensionDictionary["NSExtensionPointIdentifier"] as? String, "com.apple.widgetkit-extension")
    }

    func testAppHasExplicitWidgetTargetDependency() throws {
        let project = try projectText()
        let app = try target("A10000000000000000000020", in: project)
        XCTAssertTrue(app.contains("A10000000000000000000095"), "Wattline must explicitly depend on WattlineWidgets")
        XCTAssertTrue(project.contains("A10000000000000000000095 = {isa = PBXTargetDependency; target = A10000000000000000000078"))
    }
}
