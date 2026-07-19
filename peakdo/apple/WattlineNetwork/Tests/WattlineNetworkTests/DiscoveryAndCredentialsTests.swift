import Foundation
import XCTest
@testable import WattlineNetwork

final class RouterDiscoveryTests: XCTestCase {
    func testParsesExactV1TXTAndResolvedAuthorityAndDeduplicatesMACFormats() async throws {
        let fingerprint = String(repeating: "ab", count: 32)
        let requiredTXT: [String: Data] = [
            "api": Data("1".utf8),
            "auth": Data("pin".utf8),
            "model": Data("BP4SL3V2".utf8),
            "cid": Data("0305".utf8),
            "features": Data("00000fff".utf8),
            "tls": Data(fingerprint.utf8),
        ]
        let source = DiscoverySourceFixture(snapshots: [[
            RouterServiceRecord(
                serviceName: "wattline-one",
                domain: "local.",
                host: "wattline.local.",
                port: 8378,
                txt: requiredTXT.merging(["id": Data("dc:04:5a:eb:72:2b".utf8)]) { _, new in new }
            ),
            RouterServiceRecord(
                serviceName: "wattline-duplicate",
                domain: "local.",
                host: "wattline.local.",
                port: 8378,
                txt: requiredTXT.merging(["id": Data("DC-04-5A-EB-72-2B".utf8)]) { _, new in new }
            ),
            RouterServiceRecord(serviceName: "invalid", domain: "local.", host: nil, port: nil, txt: [:]),
        ]])
        let discovery = RouterDiscovery(source: source)

        var iterator = discovery.routers().makeAsyncIterator()
        let nextRouters = await iterator.next()
        let routers = try XCTUnwrap(nextRouters)

        XCTAssertEqual(routers.count, 1)
        XCTAssertEqual(routers[0].deviceID, "DC045AEB722B")
        XCTAssertEqual(routers[0].certificateFingerprint, fingerprint.uppercased())
        XCTAssertEqual(routers[0].serviceName, "wattline-duplicate")
        XCTAssertEqual(routers[0].model, "BP4SL3V2")
        XCTAssertEqual(routers[0].cid, 0x0305)
        XCTAssertEqual(routers[0].features, 0x0000_0fff)
        XCTAssertEqual(routers[0].endpoint.scheme, "https")
        XCTAssertEqual(routers[0].endpoint.host, "wattline.local")
        XCTAssertEqual(routers[0].endpoint.port, 8378)
        let requestedServiceTypes = source.requestedServiceTypes
        XCTAssertEqual(requestedServiceTypes, ["_wattline._tcp"])
    }

    func testRejectsInvalidV1TXTAndObsoleteFingerprintKey() {
        let base: [String: Data] = [
            "api": Data("1".utf8), "auth": Data("pin".utf8),
            "id": Data("DC:04:5A:EB:72:2B".utf8), "model": Data(),
            "cid": Data("0305".utf8), "features": Data("00000fff".utf8),
            "tls": Data("none".utf8),
        ]
        let invalidOverrides: [[String: Data]] = [
            ["api": Data("2".utf8)], ["auth": Data("token".utf8)],
            ["id": Data("not-a-mac".utf8)], ["cid": Data("305".utf8)],
            ["features": Data("00000FFF".utf8)], ["tls": Data("bad".utf8)],
        ]
        var records = invalidOverrides.enumerated().map { index, values in
            RouterServiceRecord(
                serviceName: "invalid-\(index)", domain: "local.",
                host: "wattline.local", port: 8377,
                txt: base.merging(values) { _, new in new }
            )
        }
        var obsolete = base
        obsolete["tls"] = nil
        obsolete["fingerprint"] = Data(String(repeating: "ab", count: 32).utf8)
        records.append(RouterServiceRecord(
            serviceName: "obsolete", domain: "local.",
            host: "wattline.local", port: 8378, txt: obsolete
        ))
        records.append(RouterServiceRecord(
            serviceName: "unresolved", domain: "local.", host: nil, port: nil, txt: base
        ))
        for missingKey in ["model", "cid", "features"] {
            var missing = base
            missing[missingKey] = nil
            records.append(RouterServiceRecord(
                serviceName: "missing-\(missingKey)", domain: "local.",
                host: "wattline.local", port: 8377, txt: missing
            ))
        }

        XCTAssertTrue(RouterDiscovery.parseAndDeduplicate(records).isEmpty)
    }
}

final class RouterHostStoreTests: XCTestCase {
    private let fingerprint = String(repeating: "12", count: 32)

    func testValidatesTailscaleHostAndPersistsOnlyMetadata() async throws {
        let backend = HostBackendSpy()
        let store = RouterHostStore(backend: backend)
        let host = try RouterHostValidator.validate(
            "router.magic-tailnet.ts.net:8080",
            displayName: "Travel router",
            reachability: .vpn,
            allowsInsecureWAN: false,
            deviceID: "dc:04:5a:eb:72:2b",
            certificateFingerprint: nil
        )

        try await store.save(host)
        let restored = await store.hosts()

        XCTAssertEqual(host.scheme, "http")
        XCTAssertEqual(host.host, "router.magic-tailnet.ts.net")
        XCTAssertEqual(host.port, 8080)
        XCTAssertEqual(host.deviceID, "DC045AEB722B")
        XCTAssertEqual(restored, [host])
        let bytes = try XCTUnwrap(backend.lastData)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("bearer-secret"))
    }

    func testPlainHTTPWANRequiresExplicitOptIn() {
        XCTAssertThrowsError(try RouterHostValidator.validate(
            "http://router.example.com:8080",
            displayName: "WAN router",
            reachability: .wan,
            allowsInsecureWAN: false,
            deviceID: nil,
            certificateFingerprint: nil
        )) { error in
            XCTAssertEqual(error as? RouterHostValidationError, .insecureWANRequiresOptIn)
        }

        XCTAssertNoThrow(try RouterHostValidator.validate(
            "http://router.example.com:8080",
            displayName: "WAN router",
            reachability: .wan,
            allowsInsecureWAN: true,
            deviceID: nil,
            certificateFingerprint: nil
        ))
    }

    func testManualLANAddressIsAcceptedWithoutWANOptIn() throws {
        let host = try RouterHostValidator.validate(
            "http://192.168.8.1:8080",
            displayName: "GL router",
            reachability: .lan,
            allowsInsecureWAN: false,
            deviceID: nil,
            certificateFingerprint: nil
        )

        XCTAssertEqual(host.reachability, .lan)
        XCTAssertEqual(host.host, "192.168.8.1")
        XCTAssertFalse(host.allowsInsecureWAN)
    }

    func testWattlinedDefaultPortsAndExplicitPorts() throws {
        let http = try host("router.lan")
        let explicitHTTP = try host("http://router.lan:9000")
        let https = try host("https://router.lan", fingerprint: fingerprint)
        let explicitHTTPS = try host("https://router.lan:9443", fingerprint: fingerprint)

        XCTAssertEqual(http.port, 8377)
        XCTAssertEqual(explicitHTTP.port, 9000)
        XCTAssertEqual(https.port, 8378)
        XCTAssertEqual(explicitHTTPS.port, 9443)
    }

    private func host(_ address: String, fingerprint: String? = nil) throws -> RouterHostMetadata {
        try RouterHostValidator.validate(
            address,
            displayName: "Router",
            reachability: .lan,
            allowsInsecureWAN: false,
            deviceID: nil,
            certificateFingerprint: fingerprint
        )
    }

    func testHTTPSWANRequiresPinAndRejectsFingerprintMismatch() throws {
        XCTAssertThrowsError(try RouterHostValidator.validate(
            "https://router.example.com",
            displayName: "WAN router",
            reachability: .wan,
            allowsInsecureWAN: false,
            deviceID: nil,
            certificateFingerprint: nil
        )) { error in
            XCTAssertEqual(error as? RouterHostValidationError, .missingCertificateFingerprint)
        }

        XCTAssertThrowsError(try RouterHostValidator.validateCertificateFingerprint(
            expected: fingerprint,
            presented: String(repeating: "34", count: 32)
        )) { error in
            XCTAssertEqual(error as? RouterHostValidationError, .certificateFingerprintMismatch)
        }

        XCTAssertEqual(
            try RouterHostValidator.validateCertificateFingerprint(
                expected: fingerprint.lowercased().chunked(every: 2).joined(separator: ":"),
                presented: fingerprint
            ),
            fingerprint
        )
    }

    func testProductionHTTPSClientRequiresPinAndPinPolicyUsesCertificateSHA256() throws {
        let unpinned = RouterEndpoint(
            scheme: "https",
            host: "router.example.com",
            port: 443,
            certificateFingerprint: nil,
            allowsInsecureWAN: false
        )
        XCTAssertThrowsError(try HTTPClient(endpoint: unpinned)) { error in
            XCTAssertEqual(error as? RouterHostValidationError, .missingCertificateFingerprint)
        }

        let abcSHA256 = "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"
        XCTAssertEqual(RouterTLSFingerprintPolicy.fingerprint(of: Data("abc".utf8)), abcSHA256)
        XCTAssertTrue(RouterTLSFingerprintPolicy.matches(
            expected: abcSHA256.lowercased(),
            certificateData: Data("abc".utf8)
        ))
        XCTAssertFalse(RouterTLSFingerprintPolicy.matches(
            expected: String(repeating: "00", count: 32),
            certificateData: Data("abc".utf8)
        ))
    }

    func testCorruptHostPersistenceReturnsNoFabricatedHosts() async {
        let backend = HostBackendSpy(initialData: Data("not-json".utf8))
        let store = RouterHostStore(backend: backend)

        let hosts = await store.hosts()
        XCTAssertEqual(hosts, [])
    }
}

final class RouterCredentialStoreTests: XCTestCase {
    private let endpoint = RouterEndpoint(
        scheme: "http",
        host: "router.tailnet.ts.net",
        port: 8080,
        certificateFingerprint: nil,
        allowsInsecureWAN: false
    )

    func testTokenSaveReadDeleteUsesInjectedSecretBackend() async throws {
        let backend = CredentialBackendRecorder()
        let store = RouterCredentialStore(backend: backend)

        try await store.saveToken("bearer-secret", for: endpoint)
        let savedToken = try await store.readToken(for: endpoint)
        XCTAssertEqual(savedToken, "bearer-secret")
        let credential = try await store.credential(for: endpoint)
        XCTAssertFalse(String(describing: credential).contains("bearer-secret"))
        XCTAssertFalse(String(describing: store).contains("bearer-secret"))

        try await store.deleteToken(for: endpoint)
        let deletedToken = try await store.readToken(for: endpoint)
        XCTAssertNil(deletedToken)
        let operations = await backend.operations
        XCTAssertEqual(operations, [.save, .read, .read, .delete, .read])
    }

    func testMissingAndBackendFailuresSurfaceAsUnauthorizedWithoutLeakingToken() async {
        let missing = RouterCredentialStore(backend: CredentialBackendRecorder())
        do {
            _ = try await missing.credential(for: endpoint)
            XCTFail("expected missing credential failure")
        } catch {
            XCTAssertEqual(error as? NetworkError, .unauthorized)
        }

        let failing = RouterCredentialStore(
            backend: CredentialBackendRecorder(error: SecretBackendError("backend leaked bearer-secret"))
        )
        do {
            try await failing.saveToken("bearer-secret", for: endpoint)
            XCTFail("expected backend failure")
        } catch {
            XCTAssertEqual(error as? NetworkError, .unauthorized)
            XCTAssertFalse(String(describing: error).contains("bearer-secret"))
        }
    }

    func testEquivalentEndpointSpellingsShareOneCredentialAccount() async throws {
        let backend = CredentialBackendRecorder()
        let store = RouterCredentialStore(backend: backend)
        let equivalent = RouterEndpoint(
            scheme: "HTTP",
            host: "ROUTER.TAILNET.TS.NET.",
            port: 8080,
            certificateFingerprint: nil,
            allowsInsecureWAN: false
        )

        try await store.saveToken("bearer-secret", for: equivalent)
        let token = try await store.readToken(for: endpoint)

        XCTAssertEqual(token, "bearer-secret")
    }

    func testCredentialRolesUseDistinctAccountsAndPreserveClientAccount() async throws {
        let backend = CredentialBackendRecorder()
        let store = RouterCredentialStore(backend: backend)

        try await store.saveToken("client-secret", for: endpoint)
        try await store.saveToken("admin-secret", for: endpoint, role: .administrator)

        let uuid = endpoint.peripheralID.uuidString
        let savedAccounts = await backend.savedAccounts
        XCTAssertEqual(savedAccounts, [uuid, "\(uuid).administrator"])

        let credential = try await store.credential(for: endpoint)
        XCTAssertEqual(credential.token, "client-secret")
        let clientToken = try await store.readToken(for: endpoint)
        XCTAssertEqual(clientToken, "client-secret")
        let administratorToken = try await store.readToken(for: endpoint, role: .administrator)
        XCTAssertEqual(
            administratorToken,
            "admin-secret"
        )

        try await store.deleteToken(for: endpoint, role: .administrator)
        let deletedAdministratorToken = try await store.readToken(
            for: endpoint,
            role: .administrator
        )
        XCTAssertNil(deletedAdministratorToken)
        let retainedClientToken = try await store.readToken(for: endpoint)
        XCTAssertEqual(retainedClientToken, "client-secret")
        XCTAssertFalse(String(describing: store).contains("admin-secret"))
    }
}

private final class DiscoverySourceFixture: RouterDiscoverySource, @unchecked Sendable {
    private let lock = NSLock()
    private let storedSnapshots: [[RouterServiceRecord]]
    private var serviceTypes: [String] = []

    init(snapshots: [[RouterServiceRecord]]) { storedSnapshots = snapshots }

    var requestedServiceTypes: [String] { lock.withLock { serviceTypes } }

    func snapshots(serviceType: String) -> AsyncStream<[RouterServiceRecord]> {
        lock.withLock { serviceTypes.append(serviceType) }
        let pair = AsyncStream<[RouterServiceRecord]>.makeStream()
        storedSnapshots.forEach { pair.continuation.yield($0) }
        pair.continuation.finish()
        return pair.stream
    }
}

private final class HostBackendSpy: RouterHostKeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    init(initialData: Data? = nil) { data = initialData }
    var lastData: Data? { lock.withLock { data } }
    func data(forKey key: String) -> Data? { lastData }
    func set(_ data: Data, forKey key: String) { lock.withLock { self.data = data } }
    func removeValue(forKey key: String) { lock.withLock { data = nil } }
}

private actor CredentialBackendRecorder: RouterCredentialBackend {
    enum Operation: Equatable { case save, read, delete }
    private var values: [String: Data] = [:]
    private(set) var operations: [Operation] = []
    private(set) var savedAccounts: [String] = []
    private let error: Error?
    init(error: Error? = nil) { self.error = error }

    func read(account: String) async throws -> Data? {
        operations.append(.read)
        if let error { throw error }
        return values[account]
    }
    func save(_ data: Data, account: String) async throws {
        operations.append(.save)
        if let error { throw error }
        savedAccounts.append(account)
        values[account] = data
    }
    func delete(account: String) async throws {
        operations.append(.delete)
        if let error { throw error }
        values[account] = nil
    }
}

private struct SecretBackendError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private extension String {
    func chunked(every size: Int) -> [String] {
        stride(from: 0, to: count, by: size).map { offset in
            let start = index(startIndex, offsetBy: offset)
            let end = index(start, offsetBy: Swift.min(size, count - offset))
            return String(self[start..<end])
        }
    }
}
