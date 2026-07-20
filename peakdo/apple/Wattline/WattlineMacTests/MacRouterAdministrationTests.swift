import Foundation
import XCTest

final class MacRouterAdministrationTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let projectDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // WattlineMacTests
            .deletingLastPathComponent() // Wattline
        return try String(
            contentsOf: projectDirectory.appending(path: relativePath),
            encoding: .utf8
        )
    }

    func testMenuAndSplitCompositionContainsRequiredDestinations() throws {
        let root = try source("WattlineMac/MacRootView.swift")
        XCTAssertTrue(root.contains("NavigationSplitView"))
        XCTAssertTrue(root.contains("Home"))
        XCTAssertTrue(root.contains("Shortcuts"))
        XCTAssertTrue(root.contains("Settings"))
        XCTAssertFalse(root.contains("Timers"))
    }

    func testMacAdministrationSupportsPasteAndImageButNoCamera() throws {
        let administration = try source("WattlineMac/RouterAdministration/MacRouterAdministrationView.swift")
        let adapters = try source("WattlineMac/RouterAdministration/MacRouterPlatformAdapters.swift")
        XCTAssertTrue(administration.contains("Paste pairing link"))
        XCTAssertTrue(administration.contains("Import QR image"))
        XCTAssertTrue(adapters.contains("NSPasteboard"))
        XCTAssertTrue(adapters.contains("NSOpenPanel"))
        XCTAssertFalse(administration.contains("AVCapture"))
        XCTAssertFalse(adapters.contains("AVCapture"))
    }

    func testOnlyMacAppModelOwnsTransportAndSession() throws {
        let appModel = try source("WattlineMac/MacAppModel.swift")
        let administration = try source("WattlineMac/RouterAdministration/MacRouterAdministrationView.swift")
            + (try source("WattlineMac/RouterAdministration/MacRouterPlatformAdapters.swift"))
        XCTAssertEqual(appModel.components(separatedBy: "BLETransport(").count - 1, 1)
        XCTAssertEqual(appModel.components(separatedBy: "DeviceSession(").count - 1, 1)
        XCTAssertFalse(administration.contains("BLETransport("))
        XCTAssertFalse(administration.contains("DeviceSession("))
        XCTAssertFalse(administration.contains("DeviceOperationBroker"))
    }

    func testMacAdministrationUsesSharedFunctionalControls() throws {
        let administration = try source("WattlineMac/RouterAdministration/MacRouterAdministrationView.swift")
        let sharedPaths = [
            "../WattlineShared/RouterAdministration/RouterHistoryView.swift",
            "../WattlineShared/RouterAdministration/RouterDevicePairingView.swift",
            "../WattlineShared/RouterAdministration/RouterPairingModeView.swift",
            "../WattlineShared/RouterAdministration/RouterTokensView.swift",
            "../WattlineShared/RouterAdministration/RouterSettingsView.swift",
            "../WattlineShared/RouterAdministration/RouterAdvancedView.swift",
            "../WattlineShared/RouterAdministration/RouterRulesView.swift",
        ]
        let shared = try sharedPaths.map(source).joined(separator: "\n")

        for viewName in [
            "RouterHistoryView", "RouterDevicePairingView", "RouterPairingModeView",
            "RouterTokensView", "RouterSettingsView", "RouterAdvancedView", "RouterRulesView",
        ] {
            XCTAssertTrue(administration.contains("\(viewName)(model: model)"), "missing \(viewName)")
        }
        XCTAssertTrue(shared.contains("import WattlineUI"))
        XCTAssertTrue(shared.contains("openPairing()"))
        XCTAssertTrue(shared.contains("revoke(token)"))
        XCTAssertTrue(shared.contains("saveSettings("))
        XCTAssertTrue(shared.contains("pairLinkPower("))
        XCTAssertTrue(shared.contains("setAdvancedRunningMode("))
        XCTAssertTrue(shared.contains("createRule("))
        XCTAssertTrue(shared.contains("savePowerLossPreset("))
    }

    func testNearbyRouterEnrollmentRequiresPINAndUsesCoordinatorConnection() throws {
        let administration = try source("WattlineMac/RouterAdministration/MacRouterAdministrationView.swift")

        XCTAssertTrue(administration.contains("Button(router.serviceName)"))
        XCTAssertTrue(administration.contains("SecureField(\"6-digit PIN\""))
        XCTAssertTrue(administration.contains("TextField(\"Client label\""))
        XCTAssertTrue(administration.contains("RouterEnrollmentCoordinator("))
        XCTAssertTrue(administration.contains("coordinator.submit("))
        XCTAssertTrue(administration.contains("let submittedPIN = pin"))
        XCTAssertTrue(administration.contains("pin: submittedPIN"))
        XCTAssertTrue(administration.contains("router: router"))
        XCTAssertTrue(administration.contains("enrollmentLifecycle.isCurrent(generation)"))
        XCTAssertTrue(administration.contains("enrollmentLifecycle.own(task, generation: generation)"))
        XCTAssertTrue(administration.contains("List(selection: savedHostSelection)"))
        XCTAssertTrue(administration.contains(".disabled(enrollmentLifecycle.isSubmitting)"))
        XCTAssertTrue(administration.contains("LabeledContent(\"Router name\", value: router.serviceName)"))
        XCTAssertFalse(administration.contains("enrollmentName = router.serviceName"))
        XCTAssertTrue(administration.contains("pin = \"\""))
        XCTAssertTrue(administration.contains(".onDisappear { leaveEnrollmentLifecycle() }"))
    }

    func testPairingURLNavigatesToAdministrationAndEnrollmentPrecedesSavedHost() throws {
        let root = try source("WattlineMac/MacRootView.swift")
        let administration = try source("WattlineMac/RouterAdministration/MacRouterAdministrationView.swift")

        XCTAssertTrue(root.contains(".onChange(of: model.routerEnrollmentRoute.payload)"))
        XCTAssertTrue(root.contains("selection = .routerAdministration"))
        XCTAssertTrue(administration.contains(".onChange(of: enrollmentRoute.payload)"))
        XCTAssertFalse(administration.contains(".onChange(of: enrollmentRoute.payload?.deviceID)"))
        XCTAssertTrue(administration.contains("if let enrollmentSource"))
        XCTAssertTrue(administration.contains("guard enrollmentSource == nil"))
    }

    func testMacNavigatesEveryAdministrationSection() throws {
        let administration = try source(
            "WattlineMac/RouterAdministration/MacRouterAdministrationView.swift"
        )

        for label in [
            "History", "Client enrollment", "API clients", "Router Configuration",
            "Link-Power pairing", "Advanced device", "Automation Rules",
        ] {
            XCTAssertTrue(administration.contains(label), "missing \(label)")
        }
    }

    func testMacDemoAndAdministrationExposeRequiredAccessibilityIdentifiers() throws {
        let paths = [
            "WattlineMac/MacMenuBarView.swift",
            "WattlineMac/MacRootView.swift",
            "WattlineMac/RouterAdministration/MacRouterAdministrationView.swift",
            "../WattlineShared/RouterAdministration/RouterAdvancedView.swift",
            "../WattlineShared/RouterAdministration/RouterDevicePairingView.swift",
            "../WattlineShared/RouterAdministration/RouterHistoryView.swift",
            "../WattlineShared/RouterAdministration/RouterPairingModeView.swift",
            "../WattlineShared/RouterAdministration/RouterRulesView.swift",
            "../WattlineShared/RouterAdministration/RouterSettingsView.swift",
            "../WattlineShared/RouterAdministration/RouterTokensView.swift",
        ]
        let text = try paths.map(source).joined(separator: "\n")

        for identifier in [
            "admin.secret", "history.chart", "rule.toggle", "action.destructive",
            "state.stale", "state.unavailable", "demo.badge", "connect.real-device",
        ] {
            XCTAssertTrue(text.contains(identifier), "missing \(identifier)")
        }
    }
}
