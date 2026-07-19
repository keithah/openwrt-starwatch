import Foundation
import WattlineCore
import WattlineNetwork
import XCTest
@testable import Wattline

@MainActor
final class RouterAdministrationModelTests: XCTestCase {
    func testUnlockRequiresSettings200AndGatesSectionsStructurally() async throws {
        let fixture = try await makeFixture(results: [AdminScriptedHTTP.ok("{}")])
        await fixture.model.begin(host: fixture.host)
        XCTAssertEqual(fixture.model.access, .locked)
        XCTAssertEqual(
            RouterAdministrationPresentation(access: fixture.model.access).visibleSections,
            [.connectionAndHistory]
        )

        await fixture.model.unlock(token: "boot-admin")

        XCTAssertEqual(fixture.model.access, .unlocked)
        XCTAssertNil(fixture.model.adminError)
        XCTAssertEqual(
            RouterAdministrationPresentation(access: fixture.model.access).visibleSections,
            [.connectionAndHistory, .clientEnrollment, .apiClients]
        )
        let stored = try await fixture.credentialStore.readToken(
            for: fixture.host.endpoint, role: .administrator
        )
        XCTAssertEqual(stored, "boot-admin")
    }

    func testClientTokenIsNeverPromotedToAdministrator() async throws {
        let fixture = try await makeFixture(results: [
            .failure(NetworkError.api(
                status: 403, code: .adminRequired, message: "Administrator token required"
            )),
        ])
        await fixture.model.begin(host: fixture.host)

        await fixture.model.unlock(token: "wlt_client")

        XCTAssertEqual(fixture.model.access, .locked)
        XCTAssertNotNil(fixture.model.adminError)
        let stored = try await fixture.credentialStore.readToken(
            for: fixture.host.endpoint, role: .administrator
        )
        XCTAssertNil(stored)
    }

    func testStoredAdminTokenReverifiesOnBeginAnd401DeletesOnlyAdminCredential() async throws {
        let fixture = try await makeFixture(results: [
            .failure(NetworkError.unauthorized),
        ])
        try await fixture.credentialStore.saveToken(
            "stale-admin", for: fixture.host.endpoint, role: .administrator
        )
        try await fixture.credentialStore.saveToken(
            "wlt_client", for: fixture.host.endpoint
        )

        await fixture.model.begin(host: fixture.host)

        XCTAssertEqual(fixture.model.access, .locked)
        let admin = try await fixture.credentialStore.readToken(
            for: fixture.host.endpoint, role: .administrator
        )
        XCTAssertNil(admin)
        let client = try await fixture.credentialStore.readToken(for: fixture.host.endpoint)
        XCTAssertEqual(client, "wlt_client")
    }

    func testEndLocksAndStaleUnlockCannotPublishIntoNextSession() async throws {
        let fixture = try await makeFixture(
            results: [AdminScriptedHTTP.ok("{}")],
            gateRequests: true
        )
        await fixture.model.begin(host: fixture.host)

        let unlock = Task { await fixture.model.unlock(token: "boot-admin") }
        while fixture.http.calls.isEmpty { await Task.yield() }
        await fixture.model.end()
        fixture.http.releaseGates()
        await unlock.value

        XCTAssertEqual(fixture.model.access, .locked)
    }
}

@MainActor
private struct AdministrationFixture {
    let model: RouterAdministrationModel
    let host: RouterHostMetadata
    let credentialStore: RouterCredentialStore
    let http: AdminScriptedHTTP
}

@MainActor
private func makeFixture(
    results: [Result<(Data, HTTPURLResponse), Error>],
    gateRequests: Bool = false
) async throws -> AdministrationFixture {
    let host = try RouterHostValidator.validate(
        "https://router.local:8378",
        displayName: "Garage router",
        reachability: .lan,
        allowsInsecureWAN: false,
        deviceID: "DC:04:5A:EB:72:2B",
        certificateFingerprint: String(repeating: "0", count: 64)
    )
    let credentialStore = RouterCredentialStore(backend: AdministrationMemoryBackend())
    let connections = RouterConnectionModel(
        hostStore: RouterHostStore(backend: AdministrationHostBackend()),
        credentialStore: credentialStore,
        enrollmentClientFactory: { _ in
            RouterEnrollmentClient(httpClient: AdministrationNoopEnrollmentHTTP())
        },
        transportFactory: { _, _ in throw NetworkError.unsupported("no transport in tests") }
    )
    let http = AdminScriptedHTTP(results: results, gateRequests: gateRequests)
    let model = RouterAdministrationModel(
        connections: connections,
        adminClient: RouterAdministrationClient(credentials: credentialStore) { _ in http }
    )
    return AdministrationFixture(
        model: model, host: host, credentialStore: credentialStore, http: http
    )
}

private final class AdminScriptedHTTP: RouterHTTPClient, @unchecked Sendable {
    struct Call: Equatable {
        let method: String
        let path: String
        let token: String
    }

    private let lock = NSLock()
    private var scripted: [Result<(Data, HTTPURLResponse), Error>]
    private var recorded: [Call] = []
    private var gates: [CheckedContinuation<Void, Never>] = []
    private let shouldGate: Bool

    init(results: [Result<(Data, HTTPURLResponse), Error>], gateRequests: Bool) {
        scripted = results
        shouldGate = gateRequests
    }

    var calls: [Call] {
        lock.withLock { recorded }
    }

    static func ok(_ json: String) -> Result<(Data, HTTPURLResponse), Error> {
        .success((
            Data(json.utf8),
            HTTPURLResponse(
                url: URL(string: "https://fixture.invalid")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
        ))
    }

    func get(_ path: String, token: String) async throws -> (Data, HTTPURLResponse) {
        try await request("GET", path, body: nil, token: token)
    }

    func request(
        _ method: String,
        _ path: String,
        body: Data?,
        token: String
    ) async throws -> (Data, HTTPURLResponse) {
        lock.withLock {
            recorded.append(Call(method: method, path: path, token: token))
        }
        if shouldGate {
            await withCheckedContinuation { continuation in
                lock.withLock { gates.append(continuation) }
            }
        }
        let result = lock.withLock { scripted.isEmpty ? nil : scripted.removeFirst() }
        guard let result else { throw NetworkError.decode("admin HTTP fixture exhausted") }
        return try result.get()
    }

    func releaseGates() {
        let pending = lock.withLock {
            let pending = gates
            gates.removeAll()
            return pending
        }
        pending.forEach { $0.resume() }
    }
}

private actor AdministrationMemoryBackend: RouterCredentialBackend {
    private var values: [String: Data] = [:]
    func read(account: String) async throws -> Data? { values[account] }
    func save(_ data: Data, account: String) async throws { values[account] = data }
    func delete(account: String) async throws { values[account] = nil }
}

private final class AdministrationHostBackend: RouterHostKeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(forKey key: String) -> Data? {
        lock.withLock { values[key] }
    }

    func set(_ data: Data, forKey key: String) throws {
        lock.withLock { values[key] = data }
    }

    func removeValue(forKey key: String) throws {
        lock.withLock { values[key] = nil }
    }
}

private struct AdministrationNoopEnrollmentHTTP: RouterEnrollmentHTTPClient {
    func publicRequest(
        _ method: String,
        _ path: String,
        body: Data?
    ) async throws -> (Data, HTTPURLResponse) {
        throw NetworkError.unsupported("unused")
    }
}
