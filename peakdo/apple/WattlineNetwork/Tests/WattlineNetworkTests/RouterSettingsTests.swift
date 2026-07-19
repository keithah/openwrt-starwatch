import Foundation
import XCTest
@testable import WattlineNetwork

final class RouterSettingsTests: XCTestCase {
    func testGETDecodesEveryDocumentedSettingsFieldAndIgnoresAdditiveReplyField() async throws {
        let json = completeSettingsJSON.dropLast() + ",\"future_reply\":{\"kept_by_router\":true}}"
        let (client, http) = try await attachedClient(results: [ScriptedRouterHTTPClient.ok(String(json))])

        let value = try await client.settings()

        XCTAssertEqual(value.http, .init(enabled: true, addr4: "0.0.0.0", addr6: "::", port: 8377))
        XCTAssertEqual(value.https, .init(enabled: true, addr4: "0.0.0.0", addr6: "::", port: 8378))
        XCTAssertEqual(value.tls.cert, "/etc/wattline/tls/server.crt")
        XCTAssertEqual(value.tls.key, "/etc/wattline/tls/server.key")
        XCTAssertEqual(value.tls.sha256, String(repeating: "0123456789abcdef", count: 4))
        XCTAssertEqual(value.tokenStore, "/etc/wattline/tokens.json")
        XCTAssertEqual(value.pairingTTL, "5m0s")
        XCTAssertFalse(value.pairingAlwaysOn)
        XCTAssertFalse(value.advanced)
        XCTAssertEqual(value.mdns, .init(enabled: true, interfaces: ["br-lan"]))
        XCTAssertFalse(value.wanAccess)
        XCTAssertEqual(value.blePIN, "020555")
        XCTAssertEqual(http.calls.map(\.method), ["GET"])
        XCTAssertEqual(http.calls.map(\.path), ["/api/v1/settings"])
        XCTAssertNil(http.calls[0].body)
    }

    func testPatchOmitsUnchangedTopLevelAndNestedMembers() throws {
        let patch = RouterSettingsPatch(
            http: .init(port: 9000),
            advanced: true,
            wanAccess: false
        )
        XCTAssertEqual(try object(patch) as NSDictionary, [
            "http": ["port": 9000],
            "advanced": true,
            "wan_access": false,
        ])
        let encoded = try JSONEncoder().encode(patch)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("sha256"))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("https"))
    }

    func testExplicitEmptyMDNSInterfacesDiffersFromOmittedInterfaces() throws {
        let omitted = try object(RouterSettingsPatch(mdns: .init(enabled: false)))
        let cleared = try object(RouterSettingsPatch(mdns: .init(interfaces: [])))
        XCTAssertEqual(omitted as NSDictionary, ["mdns": ["enabled": false]])
        XCTAssertEqual(cleared as NSDictionary, ["mdns": ["interfaces": []]])
    }

    func testPatchTypeCannotEncodeReadonlyFingerprintOrUnknownFields() throws {
        let patch = RouterSettingsPatch(tls: .init(cert: "/new.crt", key: "/new.key"))
        let keys = Set(try object(patch).keys)
        XCTAssertEqual(keys, ["tls"])
        let tls = try XCTUnwrap(try object(patch)["tls"] as? [String: Any])
        XCTAssertEqual(Set(tls.keys), ["cert", "key"])
        XCTAssertNil(tls["sha256"])
    }

    func testPUTSendsExactSparseBodyAndDecodesCompleteMergedReadback() async throws {
        let response = completeSettingsJSON.dropLast() + ",\"restart_required\":true}"
        let (client, http) = try await attachedClient(results: [ScriptedRouterHTTPClient.ok(String(response))])

        let result = try await client.updateSettings(.init(
            advanced: true, mdns: .init(interfaces: [])
        ))

        XCTAssertTrue(result.restartRequired)
        XCTAssertEqual(result.settings.http.port, 8377)
        XCTAssertEqual(result.settings.blePIN, "020555")
        XCTAssertEqual(http.calls.count, 1)
        XCTAssertEqual(http.calls[0].method, "PUT")
        XCTAssertEqual(http.calls[0].path, "/api/v1/settings")
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: XCTUnwrap(http.calls[0].body)) as? NSDictionary,
            ["advanced": true, "mdns": ["interfaces": []]]
        )
    }

    func testMalformedOrPartialPUTReadbackIsRejected() async throws {
        let (client, _) = try await attachedClient(results: [ScriptedRouterHTTPClient.ok(#"{"advanced":true,"restart_required":false}"#)])
        await XCTAssertThrowsErrorAsync(try await client.updateSettings(.init(advanced: true))) {
            XCTAssertEqual($0 as? RouterAdministrationError, .invalidResponse)
        }
    }

    func testPUTCompletionFromReplacedAttachmentPublishesNothing() async throws {
        let oldHTTP = ScriptedRouterHTTPClient(
            results: [ScriptedRouterHTTPClient.ok(
                completeSettingsJSON.dropLast() + ",\"restart_required\":false}"
            )],
            gateRequests: true
        )
        let newHTTP = ScriptedRouterHTTPClient(results: [])
        let oldEndpoint = endpoint(host: "router.local")
        let backend = AdministrationCredentialBackend()
        let credentials = RouterCredentialStore(backend: backend)
        try await credentials.saveToken("admin-token", for: oldEndpoint, role: .administrator)
        let client = RouterAdministrationClient(credentials: credentials) { value in
            value.host == "router.local" ? oldHTTP : newHTTP
        }
        try await client.attach(endpoint: oldEndpoint)
        let task = Task { try await client.updateSettings(.init(advanced: true)) }
        await oldHTTP.waitForGateRegistration()
        try await client.attach(endpoint: endpoint(host: "replacement.local"))
        oldHTTP.releaseGates()
        await XCTAssertThrowsErrorAsync(try await task.value) { XCTAssertTrue($0 is CancellationError) }
    }

    private func attachedClient(
        results: [Result<(Data, HTTPURLResponse), Error>]
    ) async throws -> (RouterAdministrationClient, ScriptedRouterHTTPClient) {
        let http = ScriptedRouterHTTPClient(results: results)
        let endpoint = endpoint(host: "router.local")
        let credentials = RouterCredentialStore(backend: AdministrationCredentialBackend())
        try await credentials.saveToken("admin-token", for: endpoint, role: .administrator)
        let client = RouterAdministrationClient(credentials: credentials) { _ in http }
        try await client.attach(endpoint: endpoint)
        return (client, http)
    }

    private func endpoint(host: String) -> RouterEndpoint {
        RouterEndpoint(
            scheme: "https", host: host, port: 8378,
            certificateFingerprint: String(repeating: "01", count: 32),
            allowsInsecureWAN: false
        )
    }

    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
}

private let completeSettingsJSON = #"{"http":{"enabled":true,"addr4":"0.0.0.0","addr6":"::","port":8377},"https":{"enabled":true,"addr4":"0.0.0.0","addr6":"::","port":8378},"tls":{"cert":"/etc/wattline/tls/server.crt","key":"/etc/wattline/tls/server.key","sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"},"token_store":"/etc/wattline/tokens.json","pairing_ttl":"5m0s","pairing_always_on":false,"advanced":false,"mdns":{"enabled":true,"interfaces":["br-lan"]},"wan_access":false,"ble_pin":"020555"}"#

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw an error")
    } catch {
        errorHandler(error)
    }
}
