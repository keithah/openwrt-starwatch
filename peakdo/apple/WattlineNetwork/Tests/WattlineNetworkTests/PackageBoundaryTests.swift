import Foundation
import XCTest
@testable import WattlineNetwork

final class PackageBoundaryTests: XCTestCase {
    func testUnauthorizedErrorAndCoreImportAudit() throws {
        XCTAssertEqual(NetworkError.unauthorized, .unauthorized)

        let coreRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // WattlineNetworkTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WattlineNetwork
            .deletingLastPathComponent() // apple
        let sourceRoot = coreRoot.appendingPathComponent("WattlineCore/Sources")
        let enumerator = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)
        let forbidden = ["URLSession", "Network.framework", "import Network"]
        for case let file as URL in enumerator ?? FileManager.default.enumerator(atPath: sourceRoot.path)! {
            guard file.pathExtension == "swift" else { continue }
            let contents = try String(contentsOf: file)
            for token in forbidden {
                XCTAssertFalse(contents.contains(token), "WattlineCore contains forbidden networking token \(token) in \(file.path)")
            }
        }
    }
}
