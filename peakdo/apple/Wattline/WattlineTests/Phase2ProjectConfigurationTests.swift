import Foundation
import XCTest

final class Phase2ProjectConfigurationTests: XCTestCase {
    private func projectText() throws -> String {
        try String(contentsOf: TestProjectFiles.url("Wattline.xcodeproj/project.pbxproj"), encoding: .utf8)
    }

    func testGoodCloudKitUsesImmutableRevisionAndBothAppsUseWattlineNetwork() throws {
        let package = try String(
            contentsOf: TestProjectFiles.url("../WattlineNetwork/Package.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(package.contains("https://github.com/keithah/goodcloudkit"))
        XCTAssertTrue(package.contains(
            "revision: \"66226f7fb23876d273029a13d0a799bf8aa8cc7c\""
        ))
        XCTAssertFalse(package.contains("branch:"))
        XCTAssertFalse(package.contains("from: \"0.1.0\""))

        let project = try projectText()
        let iOSApp = try target("A10000000000000000000020", in: project)
        let macApp = try target("A100000000000000000000A0", in: project)
        XCTAssertTrue(iOSApp.contains("WattlineNetwork"))
        XCTAssertTrue(macApp.contains("WattlineNetwork"))
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
        let entitlements = try String(contentsOf: TestProjectFiles.url("WattlineWidgets/WattlineWidgets.entitlements"), encoding: .utf8)
        XCTAssertTrue(entitlements.contains("<string>group.com.keithah.wattline</string>"))
        let plist = try NSDictionary(contentsOf: TestProjectFiles.url("Wattline/Info.plist"), error: ())
        XCTAssertEqual(plist["NSSupportsLiveActivities"] as? Bool, true)
    }

    func testAppDeclaresLocalRouterDiscoveryPrivacyConfiguration() throws {
        let plist = try NSDictionary(contentsOf: TestProjectFiles.url("Wattline/Info.plist"), error: ())
        XCTAssertEqual(plist["NSBonjourServices"] as? [String], ["_wattline._tcp"])
        XCTAssertFalse((plist["NSLocalNetworkUsageDescription"] as? String)?.isEmpty ?? true)
        XCTAssertFalse((plist["NSCameraUsageDescription"] as? String)?.isEmpty ?? true)
        let URLTypes = try XCTUnwrap(plist["CFBundleURLTypes"] as? [NSDictionary])
        XCTAssertEqual(URLTypes.first?["CFBundleURLSchemes"] as? [String], ["wattline"])
    }

    func testWidgetExtensionDeclaresWidgetKitExtensionPoint() throws {
        let plist = try NSDictionary(contentsOf: TestProjectFiles.url("WattlineWidgets/Info.plist"), error: ())
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

    func testMacTargetsDeploymentBundlePackagesAndWidgetEmbedding() throws {
        let project = try projectText()
        let app = try target("A100000000000000000000A0", in: project)
        let tests = try target("A100000000000000000000A1", in: project)
        XCTAssertTrue(app.contains("name = WattlineMac;"))
        XCTAssertTrue(tests.contains("name = WattlineMacTests;"))
        for configuration in try configurations(for: app, in: project) {
            XCTAssertTrue(configuration.contains("MACOSX_DEPLOYMENT_TARGET = 14.0;"))
            XCTAssertTrue(configuration.contains("PRODUCT_BUNDLE_IDENTIFIER = com.keithah.wattline.mac;"))
            XCTAssertTrue(configuration.contains("CODE_SIGN_ENTITLEMENTS = WattlineMac/WattlineMac.entitlements;"))
        }
        XCTAssertTrue(app.contains("WattlineCore"))
        XCTAssertTrue(app.contains("WattlineUI"))
        XCTAssertTrue(app.contains("WattlineNetwork"))
        XCTAssertTrue(app.contains("Embed Foundation Extensions"))
    }

    func testMacPlistHasBonjourAndNoCameraPermission() throws {
        let plist = try NSDictionary(contentsOf: TestProjectFiles.url("WattlineMac/Info.plist"), error: ())
        XCTAssertEqual(plist["NSBonjourServices"] as? [String], ["_wattline._tcp"])
        XCTAssertNil(plist["NSCameraUsageDescription"])
    }

    func testWidgetSharedSchemeKeepsOnlyTheIOSHostTestSurface() throws {
        let scheme = try String(
            contentsOf: TestProjectFiles.url(
                "Wattline.xcodeproj/xcshareddata/xcschemes/WattlineWidgets.xcscheme"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(scheme.contains("BlueprintIdentifier = \"A10000000000000000000078\""))
        XCTAssertTrue(scheme.contains("BlueprintIdentifier = \"A10000000000000000000066\""))
        XCTAssertTrue(scheme.contains("BlueprintIdentifier = \"A10000000000000000000023\""))
        XCTAssertFalse(scheme.contains("BlueprintIdentifier = \"A100000000000000000000A1\""))
    }

    func testSharedAppSchemesPreserveTheirPlatformSpecificTestHosts() throws {
        let iOS = try String(
            contentsOf: TestProjectFiles.url(
                "Wattline.xcodeproj/xcshareddata/xcschemes/Wattline.xcscheme"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(iOS.contains("BlueprintIdentifier = \"A10000000000000000000066\""))
        XCTAssertTrue(iOS.contains("BlueprintIdentifier = \"A10000000000000000000023\""))
        XCTAssertFalse(iOS.contains("BlueprintIdentifier = \"A100000000000000000000A1\""))

        let mac = try String(
            contentsOf: TestProjectFiles.url(
                "Wattline.xcodeproj/xcshareddata/xcschemes/WattlineMac.xcscheme"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(mac.contains("BlueprintIdentifier = \"A100000000000000000000A1\""))
        XCTAssertFalse(mac.contains("BlueprintIdentifier = \"A10000000000000000000066\""))
        XCTAssertFalse(mac.contains("BlueprintIdentifier = \"A10000000000000000000023\""))
    }
}
