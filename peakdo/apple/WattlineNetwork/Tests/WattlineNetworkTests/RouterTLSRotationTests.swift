import Foundation
import XCTest
@testable import WattlineNetwork

final class RouterTLSRotationTests: XCTestCase {
    private let activeDER = Data([0x30, 0x03, 0x01, 0x10, 0x01])
    private let stagedDER = Data([0x30, 0x03, 0x01, 0x10, 0x02])

    private var activePin: String {
        RouterTLSFingerprintPolicy.fingerprint(of: activeDER).lowercased()
    }

    private var stagedPin: String {
        RouterTLSFingerprintPolicy.fingerprint(of: stagedDER).lowercased()
    }

    func testRotateUsesExactConfirmedBodyAndRequiresLowercaseFingerprintAndRestart() async throws {
        let (client, http) = try await attachedClient(
            results: [ScriptedRouterHTTPClient.ok(rotateJSON)]
        )

        let response = try await client.rotateTLS()

        XCTAssertEqual(
            response.sha256,
            "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        )
        XCTAssertTrue(response.restartRequired)
        XCTAssertEqual(http.calls[0].method, "POST")
        XCTAssertEqual(http.calls[0].path, "/api/v1/tls/rotate")
        XCTAssertEqual(
            try XCTUnwrap(http.calls[0].body),
            Data(#"{"confirm":true}"#.utf8)
        )
    }

    func testRotateRejectsUppercaseShortNonHexAndRestartFalse() async throws {
        for json in [
            #"{"sha256":"ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789","restart_required":true}"#,
            #"{"sha256":"abc","restart_required":true}"#,
            #"{"sha256":"gbcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789","restart_required":true}"#,
            #"{"sha256":"abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789","restart_required":false}"#,
        ] {
            let (client, _) = try await attachedClient(
                results: [ScriptedRouterHTTPClient.ok(json)]
            )
            await XCTAssertThrowsTLSRotationError(try await client.rotateTLS()) {
                XCTAssertEqual($0 as? RouterAdministrationError, .invalidResponse)
            }
        }
    }

    func testCommittedRotationResponseSurvivesAttachmentReplacement() async throws {
        let oldHTTP = ScriptedRouterHTTPClient(
            results: [ScriptedRouterHTTPClient.ok(rotateJSON)],
            gateRequests: true
        )
        let replacementHTTP = ScriptedRouterHTTPClient(results: [])
        let oldEndpoint = makeHost(active: activePin).endpoint
        let replacementEndpoint = RouterEndpoint(
            scheme: "https",
            host: "replacement.local",
            port: 8378,
            certificateFingerprint: activePin,
            allowsInsecureWAN: false
        )
        let credentials = RouterCredentialStore(backend: AdministrationCredentialBackend())
        try await credentials.saveToken("old-admin", for: oldEndpoint, role: .administrator)
        let client = RouterAdministrationClient(credentials: credentials) { endpoint in
            endpoint == oldEndpoint ? oldHTTP : replacementHTTP
        }
        try await client.attach(endpoint: oldEndpoint)
        let rotation = Task { try await client.rotateTLS() }
        await oldHTTP.waitForGateRegistration()

        try await client.attach(endpoint: replacementEndpoint)
        oldHTTP.releaseGates()

        let response = try await rotation.value
        XCTAssertEqual(
            response.sha256,
            "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        )
        XCTAssertTrue(response.restartRequired)
        XCTAssertEqual(oldHTTP.calls.map(\.token), ["old-admin"])
        XCTAssertTrue(replacementHTTP.calls.isEmpty)
    }

    func testLegacyHostDecodesNilStagedPinAndOrdinaryEndpointUsesOnlyActivePin() throws {
        let legacy = try JSONDecoder().decode(
            RouterHostMetadata.self,
            from: legacyHostJSON(active: activePin)
        )

        XCTAssertNil(legacy.stagedCertificateFingerprint)
        XCTAssertEqual(legacy.endpoint.certificateFingerprint, activePin.uppercased())
        XCTAssertNotEqual(legacy.endpoint.certificateFingerprint, stagedPin.uppercased())
    }

    func testStagePersistsSeparatelyWithoutChangingActiveEndpoint() async throws {
        let fixture = try hostStoreFixture(active: activePin)

        let staged = try await fixture.store.stageCertificateFingerprint(
            stagedPin,
            for: fixture.host.id
        )

        XCTAssertEqual(staged.certificateFingerprint, activePin.uppercased())
        XCTAssertEqual(staged.stagedCertificateFingerprint, stagedPin.uppercased())
        XCTAssertEqual(staged.endpoint.certificateFingerprint, activePin.uppercased())
        XCTAssertFalse(
            String(decoding: try XCTUnwrap(fixture.backend.data), as: UTF8.self)
                .contains("private")
        )
    }

    func testConditionalStageCannotWriteIntoConcurrentlyReplacedHost() async throws {
        let fixture = try hostStoreFixture(active: activePin)
        let replacement = RouterHostMetadata(
            id: fixture.host.id,
            displayName: "Replacement",
            scheme: fixture.host.scheme,
            host: fixture.host.host,
            port: fixture.host.port,
            reachability: fixture.host.reachability,
            allowsInsecureWAN: fixture.host.allowsInsecureWAN,
            deviceID: "AA:BB:CC:DD:EE:FF",
            certificateFingerprint: thirdPin.uppercased(),
            stagedCertificateFingerprint: nil,
            tokenID: "replacement-token-id"
        )
        try await fixture.store.save(replacement)

        await XCTAssertThrowsTLSRotationError(
            try await fixture.store.stageCertificateFingerprint(
                stagedPin,
                for: fixture.host.id,
                ifCurrent: fixture.host
            )
        ) {
            XCTAssertEqual($0 as? RouterTLSPromotionError, .hostChanged)
        }

        let saved = await fixture.store.hosts()
        XCTAssertEqual(saved.first, replacement)
    }

    func testPromotionTrialUsesOnlyStagedPinAndCorrelatedDeviceThenAtomicallyPromotes() async throws {
        let fixture = try hostStoreFixture(
            active: activePin,
            staged: stagedPin,
            deviceID: deviceID
        )
        let http = ScriptedRouterHTTPClient(
            results: [ScriptedRouterHTTPClient.ok(deviceJSON(id: deviceID))]
        )
        let factory = TLSRecordingHTTPFactory(client: http)
        let promoter = try await makePromoter(
            store: fixture.store,
            host: fixture.host,
            factory: factory
        )

        let promoted = try await promoter.promote(hostID: fixture.host.id)

        XCTAssertEqual(factory.endpoints.single?.scheme, "https")
        XCTAssertEqual(
            factory.endpoints.single?.certificateFingerprint,
            stagedPin.uppercased()
        )
        XCTAssertEqual(promoted.certificateFingerprint, stagedPin.uppercased())
        XCTAssertNil(promoted.stagedCertificateFingerprint)
        XCTAssertEqual(http.calls.map(\.path), ["/api/v1/device"])
        XCTAssertEqual(http.calls.map(\.token), ["client-token"])
    }

    func testPromotionDeterministicallyPrefersStoredAdministratorCredential() async throws {
        let fixture = try hostStoreFixture(
            active: activePin,
            staged: stagedPin,
            deviceID: deviceID
        )
        let http = ScriptedRouterHTTPClient(
            results: [ScriptedRouterHTTPClient.ok(deviceJSON(id: deviceID))]
        )
        let factory = TLSRecordingHTTPFactory(client: http)
        let credentials = RouterCredentialStore(backend: AdministrationCredentialBackend())
        try await credentials.saveToken("client-token", for: fixture.host.endpoint, role: .client)
        try await credentials.saveToken(
            "administrator-token",
            for: fixture.host.endpoint,
            role: .administrator
        )
        let promoter = RouterTLSPinPromoter(
            hostStore: fixture.store,
            credentials: credentials,
            httpFactory: factory.make
        )

        _ = try await promoter.promote(hostID: fixture.host.id)

        XCTAssertEqual(http.calls.map(\.token), ["administrator-token"])
    }

    func testRejectedStoredAdministratorCredentialNeverFallsBackToClient() async throws {
        let fixture = try hostStoreFixture(
            active: activePin,
            staged: stagedPin,
            deviceID: deviceID
        )
        let http = ScriptedRouterHTTPClient(results: [.failure(NetworkError.unauthorized)])
        let credentials = RouterCredentialStore(backend: AdministrationCredentialBackend())
        try await credentials.saveToken("client-token", for: fixture.host.endpoint, role: .client)
        try await credentials.saveToken(
            "administrator-token",
            for: fixture.host.endpoint,
            role: .administrator
        )
        let promoter = RouterTLSPinPromoter(
            hostStore: fixture.store,
            credentials: credentials,
            httpFactory: TLSRecordingHTTPFactory(client: http).make
        )

        await XCTAssertThrowsTLSRotationError(
            try await promoter.promote(hostID: fixture.host.id)
        ) {
            XCTAssertEqual($0 as? NetworkError, .unauthorized)
        }

        XCTAssertEqual(http.calls.map(\.token), ["administrator-token"])
    }

    func testAdministratorCredentialReadFailureNeverReadsClientOrConstructsHTTP() async throws {
        let fixture = try hostStoreFixture(
            active: activePin,
            staged: stagedPin,
            deviceID: deviceID
        )
        let backend = TLSAdministratorReadFailingCredentialBackend()
        let credentials = RouterCredentialStore(backend: backend)
        try await credentials.saveToken("client-token", for: fixture.host.endpoint, role: .client)
        let http = ScriptedRouterHTTPClient(
            results: [ScriptedRouterHTTPClient.ok(deviceJSON(id: deviceID))]
        )
        let factory = TLSRecordingHTTPFactory(client: http)
        let promoter = RouterTLSPinPromoter(
            hostStore: fixture.store,
            credentials: credentials,
            httpFactory: factory.make
        )

        await XCTAssertThrowsTLSRotationError(
            try await promoter.promote(hostID: fixture.host.id)
        ) {
            XCTAssertEqual($0 as? NetworkError, .unauthorized)
        }

        let readAccounts = await backend.readAccounts()
        XCTAssertEqual(readAccounts.count, 1)
        XCTAssertTrue(readAccounts[0].hasSuffix(".administrator"))
        XCTAssertTrue(factory.endpoints.isEmpty)
        XCTAssertTrue(http.calls.isEmpty)
    }

    func testExplicitTransientAdministratorRecoveryNeverPersistsCredential() async throws {
        let fixture = try hostStoreFixture(
            active: activePin,
            staged: stagedPin,
            deviceID: deviceID
        )
        let http = ScriptedRouterHTTPClient(
            results: [ScriptedRouterHTTPClient.ok(deviceJSON(id: deviceID))]
        )
        let factory = TLSRecordingHTTPFactory(client: http)
        let credentials = RouterCredentialStore(backend: AdministrationCredentialBackend())
        let promoter = RouterTLSPinPromoter(
            hostStore: fixture.store,
            credentials: credentials,
            httpFactory: factory.make
        )

        _ = try await promoter.promote(
            hostID: fixture.host.id,
            administratorToken: "transient-recovery-admin"
        )

        XCTAssertEqual(http.calls.map(\.token), ["transient-recovery-admin"])
        let storedAdministrator = try await credentials.readToken(
            for: fixture.host.endpoint,
            role: .administrator
        )
        let storedClient = try await credentials.readToken(
            for: fixture.host.endpoint,
            role: .client
        )
        XCTAssertNil(storedAdministrator)
        XCTAssertNil(storedClient)
    }

    func testDeviceMismatchAbortsPromotionAndKeepsBothPins() async throws {
        let harness = try await promotionHarness(deviceReplyID: "AA:BB:CC:DD:EE:FF")

        await XCTAssertThrowsTLSRotationError(
            try await harness.promoter.promote(hostID: harness.host.id)
        ) {
            XCTAssertEqual($0 as? RouterTLSPromotionError, .deviceIDMismatch)
        }

        let savedHosts = await harness.store.hosts()
        let saved = try XCTUnwrap(savedHosts.first)
        XCTAssertEqual(saved.certificateFingerprint, activePin.uppercased())
        XCTAssertEqual(saved.stagedCertificateFingerprint, stagedPin.uppercased())
    }

    func testMalformedStoredDeviceIDIsRejectedBeforeTrialRequest() async throws {
        let host = makeHost(
            active: activePin,
            staged: stagedPin,
            deviceID: "not-a-device-id"
        )
        let harness = try await promotionHarness(host: host, deviceReplyID: "also-invalid")

        await XCTAssertThrowsTLSRotationError(
            try await harness.promoter.promote(hostID: host.id)
        ) {
            XCTAssertEqual($0 as? RouterTLSPromotionError, .invalidHost)
        }

        XCTAssertTrue(harness.factory.endpoints.isEmpty)
        XCTAssertTrue(harness.http.calls.isEmpty)
        let savedHosts = await harness.store.hosts()
        XCTAssertEqual(savedHosts.first, host)
    }

    func testMalformedResponseDeviceIDCannotPromoteValidStoredIdentity() async throws {
        let harness = try await promotionHarness(deviceReplyID: "not-a-device-id")

        await XCTAssertThrowsTLSRotationError(
            try await harness.promoter.promote(hostID: harness.host.id)
        ) {
            XCTAssertEqual($0 as? RouterTLSPromotionError, .deviceIDMismatch)
        }

        let savedHosts = await harness.store.hosts()
        let saved = try XCTUnwrap(savedHosts.first)
        XCTAssertEqual(saved.certificateFingerprint, activePin.uppercased())
        XCTAssertEqual(saved.stagedCertificateFingerprint, stagedPin.uppercased())
    }

    func testConcurrentRestagePreventsStaleTrialFromPromoting() async throws {
        let harness = try await promotionHarness(deviceReplyID: deviceID, gate: true)
        let promotion = Task {
            try await harness.promoter.promote(hostID: harness.host.id)
        }
        await harness.http.waitForGateRegistration()
        _ = try await harness.store.stageCertificateFingerprint(thirdPin, for: harness.host.id)
        harness.http.releaseGates()

        await XCTAssertThrowsTLSRotationError(try await promotion.value) {
            XCTAssertEqual($0 as? RouterTLSPromotionError, .hostChanged)
        }
        let savedHosts = await harness.store.hosts()
        XCTAssertEqual(try XCTUnwrap(savedHosts.first).stagedCertificateFingerprint,
                       thirdPin.uppercased())
    }

    func testConcurrentHostReplacementPreventsStaleTrialFromPromoting() async throws {
        let harness = try await promotionHarness(deviceReplyID: deviceID, gate: true)
        let promotion = Task {
            try await harness.promoter.promote(hostID: harness.host.id)
        }
        await harness.http.waitForGateRegistration()
        let replacement = RouterHostMetadata(
            id: harness.host.id,
            displayName: "Replacement",
            scheme: harness.host.scheme,
            host: harness.host.host,
            port: harness.host.port,
            reachability: harness.host.reachability,
            allowsInsecureWAN: harness.host.allowsInsecureWAN,
            deviceID: "AA:BB:CC:DD:EE:FF",
            certificateFingerprint: thirdPin.uppercased(),
            stagedCertificateFingerprint: nil,
            tokenID: "replacement-token-id"
        )
        try await harness.store.save(replacement)
        harness.http.releaseGates()

        await XCTAssertThrowsTLSRotationError(try await promotion.value) {
            XCTAssertEqual($0 as? RouterTLSPromotionError, .hostChanged)
        }
        let savedHosts = await harness.store.hosts()
        XCTAssertEqual(savedHosts.first, replacement)
    }

    func testConcurrentEndpointOnlyReplacementPreventsOldEndpointProofFromPromoting() async throws {
        let harness = try await promotionHarness(deviceReplyID: deviceID, gate: true)
        let promotion = Task {
            try await harness.promoter.promote(hostID: harness.host.id)
        }
        await harness.http.waitForGateRegistration()
        let replacement = RouterHostMetadata(
            id: harness.host.id,
            displayName: harness.host.displayName,
            scheme: harness.host.scheme,
            host: "replacement.router.local",
            port: 9443,
            reachability: harness.host.reachability,
            allowsInsecureWAN: harness.host.allowsInsecureWAN,
            deviceID: harness.host.deviceID,
            certificateFingerprint: harness.host.certificateFingerprint,
            stagedCertificateFingerprint: harness.host.stagedCertificateFingerprint,
            tokenID: harness.host.tokenID
        )
        try await harness.store.save(replacement)
        harness.http.releaseGates()

        await XCTAssertThrowsTLSRotationError(try await promotion.value) {
            XCTAssertEqual($0 as? RouterTLSPromotionError, .hostChanged)
        }
        let savedHosts = await harness.store.hosts()
        XCTAssertEqual(savedHosts.first, replacement)
    }

    func testPromotionRejectsHTTPAndMissingStageWithoutConstructingTrialTransport() async throws {
        for host in [
            makeHost(active: activePin, staged: stagedPin, scheme: "http"),
            makeHost(active: activePin, staged: nil),
        ] {
            let harness = try await promotionHarness(host: host, deviceReplyID: deviceID)

            await XCTAssertThrowsTLSRotationError(
                try await harness.promoter.promote(hostID: host.id)
            ) { _ in }

            XCTAssertTrue(harness.factory.endpoints.isEmpty)
            XCTAssertTrue(harness.http.calls.isEmpty)
        }
    }

    func testTrialFactoryPinFailureSendsNoCredentialAndNeverFallsBack() async throws {
        let fixture = try hostStoreFixture(active: activePin, staged: stagedPin, deviceID: deviceID)
        let http = ScriptedRouterHTTPClient(
            results: [ScriptedRouterHTTPClient.ok(deviceJSON(id: deviceID))]
        )
        let factory = TLSRecordingHTTPFactory(
            client: http,
            error: RouterHostValidationError.certificateFingerprintMismatch
        )
        let promoter = try await makePromoter(
            store: fixture.store,
            host: fixture.host,
            factory: factory
        )

        await XCTAssertThrowsTLSRotationError(
            try await promoter.promote(hostID: fixture.host.id)
        ) {
            XCTAssertEqual(
                $0 as? RouterHostValidationError,
                .certificateFingerprintMismatch
            )
        }

        XCTAssertEqual(factory.endpoints.count, 1)
        XCTAssertEqual(factory.endpoints.single?.scheme, "https")
        XCTAssertEqual(
            factory.endpoints.single?.certificateFingerprint,
            stagedPin.uppercased()
        )
        XCTAssertTrue(http.calls.isEmpty)
        let savedHosts = await fixture.store.hosts()
        let saved = try XCTUnwrap(savedHosts.first)
        XCTAssertEqual(saved.certificateFingerprint, activePin.uppercased())
        XCTAssertEqual(saved.stagedCertificateFingerprint, stagedPin.uppercased())
    }

    func testOldPinIsNotUsedAfterPromotion() async throws {
        let harness = try await promotionHarness(deviceReplyID: deviceID)

        let promoted = try await harness.promoter.promote(hostID: harness.host.id)

        XCTAssertEqual(promoted.endpoint.certificateFingerprint, stagedPin.uppercased())
        XCTAssertTrue(RouterTLSFingerprintPolicy.matches(
            expected: try XCTUnwrap(promoted.endpoint.certificateFingerprint),
            certificateData: stagedDER
        ))
        XCTAssertFalse(RouterTLSFingerprintPolicy.matches(
            expected: try XCTUnwrap(promoted.endpoint.certificateFingerprint),
            certificateData: activeDER
        ))
    }

    private func attachedClient(
        results: [Result<(Data, HTTPURLResponse), Error>]
    ) async throws -> (RouterAdministrationClient, ScriptedRouterHTTPClient) {
        let http = ScriptedRouterHTTPClient(results: results)
        let credentials = RouterCredentialStore(backend: AdministrationCredentialBackend())
        let endpoint = makeHost(active: activePin).endpoint
        try await credentials.saveToken("admin-token", for: endpoint, role: .administrator)
        let client = RouterAdministrationClient(credentials: credentials) { _ in http }
        try await client.attach(endpoint: endpoint)
        return (client, http)
    }

    private func hostStoreFixture(
        active: String,
        staged: String? = nil,
        deviceID: String = "DC:04:5A:EB:72:2B"
    ) throws -> TLSHostStoreFixture {
        let host = makeHost(active: active, staged: staged, deviceID: deviceID)
        let backend = TLSHostBackend(data: try JSONEncoder().encode([host]))
        return TLSHostStoreFixture(
            store: RouterHostStore(backend: backend),
            backend: backend,
            host: host
        )
    }

    private func makePromoter(
        store: RouterHostStore,
        host: RouterHostMetadata,
        factory: TLSRecordingHTTPFactory
    ) async throws -> RouterTLSPinPromoter {
        let credentials = RouterCredentialStore(backend: AdministrationCredentialBackend())
        try await credentials.saveToken("client-token", for: host.endpoint)
        return RouterTLSPinPromoter(
            hostStore: store,
            credentials: credentials,
            httpFactory: factory.make
        )
    }

    private func promotionHarness(
        host: RouterHostMetadata? = nil,
        deviceReplyID: String,
        gate: Bool = false
    ) async throws -> TLSPromotionHarness {
        let host = host ?? makeHost(active: activePin, staged: stagedPin, deviceID: deviceID)
        let backend = TLSHostBackend(data: try JSONEncoder().encode([host]))
        let store = RouterHostStore(backend: backend)
        let http = ScriptedRouterHTTPClient(
            results: [ScriptedRouterHTTPClient.ok(deviceJSON(id: deviceReplyID))],
            gateRequests: gate
        )
        let factory = TLSRecordingHTTPFactory(client: http)
        let promoter = try await makePromoter(store: store, host: host, factory: factory)
        return TLSPromotionHarness(
            store: store,
            host: host,
            promoter: promoter,
            http: http,
            factory: factory
        )
    }

    private func makeHost(
        active: String,
        staged: String? = nil,
        scheme: String = "https",
        deviceID: String = "DC:04:5A:EB:72:2B"
    ) -> RouterHostMetadata {
        RouterHostMetadata(
            id: UUID(uuidString: "BF3CAEE1-836D-54BC-867F-01E2257C9CA7")!,
            displayName: "Router",
            scheme: scheme,
            host: "router.local",
            port: scheme == "https" ? 8378 : 8377,
            reachability: .lan,
            allowsInsecureWAN: false,
            deviceID: deviceID,
            certificateFingerprint: active.uppercased(),
            stagedCertificateFingerprint: staged?.uppercased(),
            tokenID: "client-token-id"
        )
    }

    private func legacyHostJSON(active: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "id": "BF3CAEE1-836D-54BC-867F-01E2257C9CA7",
            "displayName": "Router",
            "scheme": "https",
            "host": "router.local",
            "port": 8378,
            "reachability": "lan",
            "allowsInsecureWAN": false,
            "deviceID": deviceID,
            "certificateFingerprint": active.uppercased(),
            "tokenID": "client-token-id",
        ])
    }
}

private struct TLSHostStoreFixture {
    let store: RouterHostStore
    let backend: TLSHostBackend
    let host: RouterHostMetadata
}

private struct TLSPromotionHarness {
    let store: RouterHostStore
    let host: RouterHostMetadata
    let promoter: RouterTLSPinPromoter
    let http: ScriptedRouterHTTPClient
    let factory: TLSRecordingHTTPFactory
}

private actor TLSAdministratorReadFailingCredentialBackend: RouterCredentialBackend {
    private enum ReadFailure: Error { case denied }
    private var values: [String: Data] = [:]
    private var reads: [String] = []

    func read(account: String) async throws -> Data? {
        reads.append(account)
        if account.hasSuffix(".administrator") { throw ReadFailure.denied }
        return values[account]
    }

    func save(_ data: Data, account: String) async throws {
        values[account] = data
    }

    func delete(account: String) async throws {
        values[account] = nil
    }

    func readAccounts() -> [String] { reads }
}

private final class TLSHostBackend: RouterHostKeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storedData: Data?

    init(data: Data?) {
        storedData = data
    }

    var data: Data? { lock.withLock { storedData } }

    func data(forKey key: String) -> Data? { data }

    func set(_ data: Data, forKey key: String) {
        lock.withLock { storedData = data }
    }

    func removeValue(forKey key: String) {
        lock.withLock { storedData = nil }
    }
}

private final class TLSRecordingHTTPFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let client: any RouterHTTPClient
    private let error: Error?
    private var recordedEndpoints: [RouterEndpoint] = []

    init(client: any RouterHTTPClient, error: Error? = nil) {
        self.client = client
        self.error = error
    }

    var endpoints: [RouterEndpoint] { lock.withLock { recordedEndpoints } }

    func make(_ endpoint: RouterEndpoint) throws -> any RouterHTTPClient {
        lock.withLock { recordedEndpoints.append(endpoint) }
        if let error { throw error }
        return client
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}

private func XCTAssertThrowsTLSRotationError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        errorHandler(error)
    }
}

private let rotateJSON = #"{"sha256":"abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789","restart_required":true}"#
private let deviceID = "DC:04:5A:EB:72:2B"
private let thirdPin = String(repeating: "03", count: 32)

private func deviceJSON(id: String) -> String {
    #"{"id":"\#(id)","model":"BP4SL3V2","hardware_revision":"V2","application_firmware":"1.4.9","ota_firmware":"1.0.3","cid":773,"features_raw":32767,"features":{},"available":{"current_time":true,"ota":true,"dc":true,"usbc":true},"mode":"ota","connection":{"connected":true,"phase":"bootloader","reconnect":"bootloader"},"commands":{"active":[],"recent":[]},"magic_dns_name":"wattline.example.ts.net"}"#
}
