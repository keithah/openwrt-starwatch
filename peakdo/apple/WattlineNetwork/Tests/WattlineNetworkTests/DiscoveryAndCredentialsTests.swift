import Foundation
import XCTest
@testable import WattlineNetwork

final class RouterDiscoveryTests: XCTestCase {
    func testParsesTXTIdentityAndFingerprintAndDeduplicatesMACFormats() async throws {
        let fingerprint = String(repeating: "AB", count: 32)
        let source = DiscoverySourceFixture(snapshots: [[
            RouterServiceRecord(
                serviceName: "wattline-one",
                domain: "local.",
                txt: ["id": Data("dc:04:5a:eb:72:2b".utf8), "fingerprint": Data(fingerprint.utf8)]
            ),
            RouterServiceRecord(
                serviceName: "wattline-duplicate",
                domain: "local.",
                txt: ["id": Data("DC-04-5A-EB-72-2B".utf8), "fingerprint": Data(fingerprint.lowercased().utf8)]
            ),
            RouterServiceRecord(serviceName: "invalid", domain: "local.", txt: [:]),
        ]])
        let discovery = RouterDiscovery(source: source)

        var iterator = discovery.routers().makeAsyncIterator()
        let nextRouters = await iterator.next()
        let routers = try XCTUnwrap(nextRouters)

        XCTAssertEqual(routers.count, 1)
        XCTAssertEqual(routers[0].deviceID, "DC045AEB722B")
        XCTAssertEqual(routers[0].certificateFingerprint, fingerprint)
        XCTAssertEqual(routers[0].serviceName, "wattline-duplicate")
        let requestedServiceTypes = source.requestedServiceTypes
        XCTAssertEqual(requestedServiceTypes, ["_wattline._tcp"])
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
