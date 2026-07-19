import Foundation
import XCTest
@testable import WattlineNetwork

final class RouterHistoryTests: XCTestCase {
    private let endpoint = RouterEndpoint(
        scheme: "https",
        host: "router.local",
        port: 8378,
        certificateFingerprint: String(repeating: "0", count: 64),
        allowsInsecureWAN: false
    )

    func testFetchDecodesExactContractFieldsWithClientToken() async throws {
        let body = #"""
        [{"at":"2026-07-17T19:59:00Z","level":77,"status":1,"dc_w":12.0,"typec_w":20.0},
         {"at":"2026-07-17T20:00:00Z","level":76,"status":-1}]
        """#
        let http = ScriptedRouterHTTPClient(results: [ScriptedRouterHTTPClient.ok(body)])
        let client = RouterHistoryClient(
            httpClient: http,
            credentials: TransientRouterCredentialProvider(token: "wlt_client"),
            endpoint: endpoint
        )

        let samples = try await client.fetch()

        XCTAssertEqual(http.calls, [.init(
            method: "GET", path: "/api/v1/history", body: nil, token: "wlt_client"
        )])
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0].level, 77)
        XCTAssertEqual(samples[0].status, 1)
        XCTAssertEqual(samples[0].dcWatts, 12.0)
        XCTAssertEqual(samples[0].typeCWatts, 20.0)
        XCTAssertEqual(samples[1].status, -1)
        XCTAssertNil(samples[1].dcWatts)
        XCTAssertNil(samples[1].typeCWatts)
        XCTAssertEqual(
            samples[1].at.timeIntervalSince(samples[0].at), 60, accuracy: 0.001
        )
    }

    func testEmptyArrayAndInvalidDateBehaveHonestly() async throws {
        let http = ScriptedRouterHTTPClient(results: [
            ScriptedRouterHTTPClient.ok("[]"),
            ScriptedRouterHTTPClient.ok(#"[{"at":"yesterday","level":1,"status":0}]"#),
        ])
        let client = RouterHistoryClient(
            httpClient: http,
            credentials: TransientRouterCredentialProvider(token: "wlt_client"),
            endpoint: endpoint
        )

        let empty = try await client.fetch()
        XCTAssertEqual(empty, [])

        do {
            _ = try await client.fetch()
            XCTFail("expected decode failure")
        } catch {
            guard case NetworkError.decode = error else {
                return XCTFail("expected NetworkError.decode, got \(error)")
            }
        }
    }
}
