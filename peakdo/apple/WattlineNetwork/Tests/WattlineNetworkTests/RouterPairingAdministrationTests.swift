import Foundation
import XCTest
@testable import WattlineNetwork

final class RouterPairingAdministrationTests: XCTestCase {
    private let endpoint = RouterEndpoint(
        scheme: "https",
        host: "router.local",
        port: 8378,
        certificateFingerprint: String(repeating: "0", count: 64),
        allowsInsecureWAN: false
    )

    private func makeAttachedClient(
        http: ScriptedRouterHTTPClient
    ) async throws -> RouterAdministrationClient {
        let store = RouterCredentialStore(backend: PairingCredentialBackend())
        try await store.saveToken("boot-admin", for: endpoint, role: .administrator)
        let client = RouterAdministrationClient(credentials: store) { _ in http }
        try await client.attach(endpoint: endpoint)
        return client
    }

    func testPairingModeLifecycleUsesExactRoutesAndZeroByteBodies() async throws {
        let http = ScriptedRouterHTTPClient(results: [
            ScriptedRouterHTTPClient.ok(
                #"{"open":false,"expires_at":"0001-01-01T00:00:00Z"}"#
            ),
            ScriptedRouterHTTPClient.ok(
                #"{"open":true,"expires_at":"2026-07-17T20:05:00Z","pin":"123456"}"#
            ),
            ScriptedRouterHTTPClient.ok(#"{"open":false}"#),
        ])
        let client = try await makeAttachedClient(http: http)

        let closed = try await client.pairingMode()
        XCTAssertFalse(closed.open)
        XCTAssertNil(closed.pin)

        let opened = try await client.openPairingMode()
        XCTAssertTrue(opened.open)
        XCTAssertEqual(opened.pin, "123456")
        XCTAssertFalse(String(describing: opened).contains("123456"))
        XCTAssertFalse(String(reflecting: opened).contains("123456"))

        try await client.closePairingMode()

        XCTAssertEqual(http.calls.map(\.method), ["GET", "POST", "DELETE"])
        XCTAssertEqual(
            http.calls.map(\.path),
            Array(repeating: "/api/v1/pairing-mode", count: 3)
        )
        XCTAssertEqual(http.calls.map(\.body), [nil, nil, nil])
    }

    func testClosedPairingModeRejectsPayloadThatCarriesPIN() async throws {
        let http = ScriptedRouterHTTPClient(results: [
            ScriptedRouterHTTPClient.ok(
                #"{"open":false,"expires_at":"0001-01-01T00:00:00Z","pin":"123456"}"#
            ),
        ])
        let client = try await makeAttachedClient(http: http)

        do {
            _ = try await client.pairingMode()
            XCTFail("expected incoherent closed pairing response rejection")
        } catch {
            XCTAssertEqual(error as? RouterAdministrationError, .invalidResponse)
        }
    }

    func testQRFetchHasNoQueryAcceptsParameterizedCaseInsensitivePNG() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let http = ScriptedRouterHTTPClient(results: [
            .success((
                png,
                HTTPURLResponse(
                    url: URL(string: "https://router.local:8378")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "Image/PNG; charset=binary",
                        "Cache-Control": "no-store",
                    ]
                )!
            )),
        ])
        let client = try await makeAttachedClient(http: http)

        let data = try await client.pairingQRCodePNG()
        XCTAssertEqual(data, png)
        XCTAssertEqual(http.calls[0].path, "/api/v1/pairing-mode/qr.png")
        XCTAssertFalse(http.calls[0].path.contains("?"))
        XCTAssertNil(http.calls[0].body)
    }

    func testQRFetchRejectsMalformedPNGMediaTypePrefix() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let http = ScriptedRouterHTTPClient(results: [
            .success((
                png,
                HTTPURLResponse(
                    url: URL(string: "https://router.local:8378")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "image/png-malformed"]
                )!
            )),
        ])
        let client = try await makeAttachedClient(http: http)

        do {
            _ = try await client.pairingQRCodePNG()
            XCTFail("expected malformed media type rejection")
        } catch {
            XCTAssertEqual(error as? RouterAdministrationError, .invalidResponse)
        }
    }

    func testQRFetchRejectsImagePNGWithoutStandardSignature() async throws {
        let http = ScriptedRouterHTTPClient(results: [
            .success((
                Data("not really a PNG".utf8),
                HTTPURLResponse(
                    url: URL(string: "https://router.local:8378")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "image/png"]
                )!
            )),
        ])
        let client = try await makeAttachedClient(http: http)

        do {
            _ = try await client.pairingQRCodePNG()
            XCTFail("expected invalid PNG signature rejection")
        } catch {
            XCTAssertEqual(error as? RouterAdministrationError, .invalidResponse)
        }
    }
}

private actor PairingCredentialBackend: RouterCredentialBackend {
    private var values: [String: Data] = [:]
    func read(account: String) async throws -> Data? { values[account] }
    func save(_ data: Data, account: String) async throws { values[account] = data }
    func delete(account: String) async throws { values[account] = nil }
}
