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

    func testPublicDescriptionsNeverExposeBLEPIN() throws {
        let settings = try JSONDecoder().decode(
            RouterSettings.self,
            from: Data(completeSettingsJSON.utf8)
        )
        let patch = RouterSettingsPatch(blePIN: "020555")
        let result = try JSONDecoder().decode(
            RouterSettingsUpdateResult.self,
            from: Data((completeSettingsJSON.dropLast() + ",\"restart_required\":false}").utf8)
        )

        assertDoesNotExposeBLEPIN(settings, named: "RouterSettings")
        assertDoesNotExposeBLEPIN(patch, named: "RouterSettingsPatch")
        assertDoesNotExposeBLEPIN(result, named: "RouterSettingsUpdateResult")
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

    func testSettingsGETWaitsBehindEarlierPrivilegedPUTAndReadsAfterIt() async throws {
        let advancedJSON = completeSettingsJSON.replacingOccurrences(
            of: "\"advanced\":false",
            with: "\"advanced\":true"
        )
        let updatedJSON = advancedJSON.dropLast() + ",\"restart_required\":false}"
        let http = ScriptedRouterHTTPClient(
            results: [
                ScriptedRouterHTTPClient.ok(String(updatedJSON)),
                ScriptedRouterHTTPClient.ok(advancedJSON),
            ],
            gateRequests: true
        )
        let endpoint = endpoint(host: "router.local")
        let credentials = RouterCredentialStore(backend: AdministrationCredentialBackend())
        try await credentials.saveToken("admin-token", for: endpoint, role: .administrator)
        let client = RouterAdministrationClient(credentials: credentials) { _ in http }
        try await client.attach(endpoint: endpoint)

        let update = Task { try await client.updateSettings(.init(advanced: true)) }
        await http.waitForGateRegistration()
        let read = Task { try await client.settings() }
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(http.calls.map(\.method), ["PUT"])
        http.releaseNextGate()
        let updateValue = try await update.value
        XCTAssertTrue(updateValue.settings.advanced)
        await http.waitForCallCount(2)
        http.releaseNextGate()
        let readValue = try await read.value
        XCTAssertTrue(readValue.advanced)
        XCTAssertEqual(http.calls.map(\.method), ["PUT", "GET"])
    }

    func testValidatedReplacementPUTBlocksHostAndCredentialInvalidationUntilResponse() async throws {
        let source = try RouterHostValidator.validate(
            "https://router.local:8378",
            displayName: "HTTPS route",
            reachability: .lan,
            allowsInsecureWAN: false,
            deviceID: "DC:04:5A:EB:72:2B",
            certificateFingerprint: String(repeating: "01", count: 32)
        )
        let candidate = try RouterHostValidator.validate(
            "http://router.local:8377",
            displayName: "HTTP route",
            reachability: .lan,
            allowsInsecureWAN: false,
            deviceID: "DC:04:5A:EB:72:2B",
            certificateFingerprint: nil
        )
        let hostStore = RouterHostStore(backend: SettingsHostBackend())
        try await hostStore.save(source)
        try await hostStore.save(candidate)
        let credentials = RouterCredentialStore(backend: AdministrationCredentialBackend())
        try await credentials.saveToken(
            "source-admin",
            for: source.endpoint,
            role: .administrator
        )
        try await credentials.saveToken(
            "candidate-client",
            for: candidate.endpoint,
            role: .client
        )
        let migrationHTTP = ScriptedRouterHTTPClient(results: [
            ScriptedRouterHTTPClient.ok(settingsDeviceJSON),
        ])
        let validator = RouterEndpointMigrationValidator(
            hostStore: hostStore,
            credentials: credentials,
            httpFactory: { _ in migrationHTTP }
        )
        let proof = try await validator.validate(
            candidate: candidate,
            expectedDeviceID: "DC:04:5A:EB:72:2B"
        )
        let updateHTTP = ScriptedRouterHTTPClient(
            results: [ScriptedRouterHTTPClient.ok(
                completeSettingsJSON.dropLast() + ",\"restart_required\":true}"
            )],
            gateRequests: true
        )
        let client = RouterAdministrationClient(credentials: credentials) { _ in updateHTTP }
        try await client.attach(endpoint: source.endpoint)
        let update = Task {
            try await validator.updateSettings(
                .init(https: .init(enabled: false)),
                using: client,
                validation: proof,
                source: source,
                candidate: candidate,
                expectedDeviceID: "DC:04:5A:EB:72:2B",
                isCurrent: { true }
            )
        }
        await updateHTTP.waitForGateRegistration()

        let starts = AsyncStream<String>.makeStream()
        var startsIterator = starts.stream.makeAsyncIterator()
        let completions = SettingsMutationCompletions()
        let changedCandidate = try RouterHostValidator.validate(
            "http://router.local:8377",
            displayName: "Changed HTTP route",
            reachability: .lan,
            allowsInsecureWAN: false,
            deviceID: "DC:04:5A:EB:72:2B",
            certificateFingerprint: nil
        )
        let hostMutation = Task {
            starts.continuation.yield("host")
            try await hostStore.save(changedCandidate)
            await completions.completeHost()
        }
        let credentialMutation = Task {
            starts.continuation.yield("credential")
            try await credentials.saveToken(
                "replacement-client",
                for: candidate.endpoint,
                role: .client
            )
            await completions.completeCredential()
        }
        _ = await startsIterator.next()
        _ = await startsIterator.next()
        for _ in 0..<100 { await Task.yield() }
        let blockedCompletions = await completions.snapshot()

        XCTAssertFalse(blockedCompletions.host)
        XCTAssertFalse(blockedCompletions.credential)

        updateHTTP.releaseGates()
        let result = try await update.value
        try await hostMutation.value
        try await credentialMutation.value
        let finalCompletions = await completions.snapshot()
        let savedHosts = await hostStore.hosts()
        let savedCandidate = savedHosts.first(where: { $0.id == candidate.id })
        let savedCredential = try await credentials.readToken(
            for: candidate.endpoint,
            role: .client
        )

        XCTAssertTrue(result.restartRequired)
        XCTAssertTrue(finalCompletions.host)
        XCTAssertTrue(finalCompletions.credential)
        XCTAssertEqual(savedCandidate, changedCandidate)
        XCTAssertEqual(savedCredential, "replacement-client")
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

    private func assertDoesNotExposeBLEPIN<T>(_ value: T, named name: String) {
        XCTAssertFalse(String(describing: value).contains("020555"), "\(name) description leaked BLE PIN")
        XCTAssertFalse(String(reflecting: value).contains("020555"), "\(name) debug description leaked BLE PIN")
        XCTAssertFalse(
            recursivelyReflectedStrings(value).contains("020555"),
            "\(name) Mirror leaked BLE PIN"
        )
        var dumped = ""
        dump(value, to: &dumped)
        XCTAssertFalse(dumped.contains("020555"), "\(name) dump leaked BLE PIN")
    }

    private func recursivelyReflectedStrings(_ value: Any) -> [String] {
        let mirror = Mirror(reflecting: value)
        return mirror.children.flatMap { child -> [String] in
            if let string = child.value as? String {
                return [string]
            }
            return recursivelyReflectedStrings(child.value)
        }
    }
}

private actor SettingsMutationCompletions {
    private(set) var hostCompleted = false
    private(set) var credentialCompleted = false

    func completeHost() { hostCompleted = true }
    func completeCredential() { credentialCompleted = true }
    func snapshot() -> (host: Bool, credential: Bool) {
        (hostCompleted, credentialCompleted)
    }
}

private final class SettingsHostBackend: RouterHostKeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(forKey key: String) -> Data? {
        lock.withLock { values[key] }
    }

    func set(_ data: Data, forKey key: String) {
        lock.withLock { values[key] = data }
    }

    func removeValue(forKey key: String) {
        lock.withLock { values[key] = nil }
    }
}

private let completeSettingsJSON = #"{"http":{"enabled":true,"addr4":"0.0.0.0","addr6":"::","port":8377},"https":{"enabled":true,"addr4":"0.0.0.0","addr6":"::","port":8378},"tls":{"cert":"/etc/wattline/tls/server.crt","key":"/etc/wattline/tls/server.key","sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"},"token_store":"/etc/wattline/tokens.json","pairing_ttl":"5m0s","pairing_always_on":false,"advanced":false,"mdns":{"enabled":true,"interfaces":["br-lan"]},"wan_access":false,"ble_pin":"020555"}"#

private let settingsDeviceJSON = #"{"id":"DC:04:5A:EB:72:2B","model":"BP4SL3V2","hardware_revision":"V2","application_firmware":"1.4.9","ota_firmware":"1.0.3","cid":773,"features_raw":32767,"features":{},"available":{"current_time":true,"ota":true,"dc":true,"usbc":true},"mode":"ota","connection":{"connected":true,"phase":"bootloader","reconnect":"bootloader"},"commands":{"active":[],"recent":[]},"magic_dns_name":"wattline.example.ts.net"}"#

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
