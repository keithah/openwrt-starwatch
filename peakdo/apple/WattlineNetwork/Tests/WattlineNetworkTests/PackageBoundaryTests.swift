import Foundation
import XCTest
@testable import WattlineNetwork

final class PackageBoundaryTests: XCTestCase {
    private let forbiddenNetworkingTokenPatterns = [
        "URLSession",
        "FoundationNetworking",
        "Network.framework",
        "import Network",
        "NetworkExtension",
        "NWBrowser",
        "NWConnection",
        "Network.",
        "import Security"
    ]

    func testCoreImportAuditDetectsEveryForbiddenNetworkingToken() {
        let requiredTokens = [
            "URLSession",
            "FoundationNetworking",
            "Network.framework",
            "import Network",
            "NetworkExtension",
            "NWBrowser",
            "NWConnection",
            "Network.",
            "import Security"
        ]
        for token in requiredTokens {
            let fixture = "let marker = \"\(token)\""
            XCTAssertTrue(
                forbiddenNetworkingTokens(in: fixture).contains(token),
                "The WattlineCore audit must reject the forbidden token \(token)"
            )
        }
    }

    func testUnauthorizedErrorAndCoreUIImportAudit() throws {
        XCTAssertEqual(NetworkError.unauthorized, .unauthorized)

        let coreRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // WattlineNetworkTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WattlineNetwork
            .deletingLastPathComponent() // apple
        for module in ["WattlineCore", "WattlineUI"] {
            let sourceRoot = coreRoot.appendingPathComponent("\(module)/Sources")
            let enumerator = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)
            var auditedFileCount = 0
            for case let file as URL in enumerator ?? FileManager.default.enumerator(atPath: sourceRoot.path)! {
                guard file.pathExtension == "swift" else { continue }
                auditedFileCount += 1
                let contents = try String(contentsOf: file)
                XCTAssertTrue(
                    forbiddenNetworkingTokens(in: contents).isEmpty,
                    "\(module) contains a forbidden networking token in \(file.path)"
                )
            }
            XCTAssertGreaterThan(auditedFileCount, 0, "\(module) source audit did not inspect any Swift files")
        }
    }

    private func forbiddenNetworkingTokens(in contents: String) -> [String] {
        forbiddenNetworkingTokenPatterns.filter(contents.contains)
    }
}
