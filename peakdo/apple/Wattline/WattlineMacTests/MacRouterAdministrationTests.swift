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
}
