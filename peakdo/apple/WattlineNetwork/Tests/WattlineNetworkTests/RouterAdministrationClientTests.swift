import Foundation
import XCTest
@testable import WattlineNetwork

final class RouterAdministrationClientTests: XCTestCase {
    private let endpoint = RouterEndpoint(
        scheme: "https",
        host: "router.local",
        port: 8378,
        certificateFingerprint: String(repeating: "0", count: 64),
        allowsInsecureWAN: false
    )
    private let otherEndpoint = RouterEndpoint(
        scheme: "https",
        host: "other.local",
        port: 8378,
        certificateFingerprint: String(repeating: "1", count: 64),
        allowsInsecureWAN: false
    )

    private func makeClient(
        http: ScriptedRouterHTTPClient,
        backend: AdministrationCredentialBackend = AdministrationCredentialBackend()
    ) -> (RouterAdministrationClient, RouterCredentialStore) {
        let store = RouterCredentialStore(backend: backend)
        let client = RouterAdministrationClient(credentials: store) { _ in http }
        return (client, store)
    }

    func testVerifySavesAdministratorTokenOnlyAfterSettingsReturns200() async throws {
        let http = ScriptedRouterHTTPClient(results: [ScriptedRouterHTTPClient.ok("{}")])
        let (client, store) = makeClient(http: http)
        try await client.attach(endpoint: endpoint)

        try await client.verifyAdministrator(token: "boot-admin")

        XCTAssertEqual(http.calls, [.init(
            method: "GET", path: "/api/v1/settings", body: nil, token: "boot-admin"
        )])
        let saved = try await store.readToken(for: endpoint, role: .administrator)
        XCTAssertEqual(saved, "boot-admin")
        let clientToken = try await store.readToken(for: endpoint)
        XCTAssertNil(clientToken)
    }

    func testInvalidTokenAndClientTokenAreDistinguishedAndNeverSaved() async throws {
        let http = ScriptedRouterHTTPClient(results: [
            .failure(NetworkError.unauthorized),
            .failure(NetworkError.api(
                status: 403, code: .adminRequired, message: "Administrator token required"
            )),
        ])
        let (client, store) = makeClient(http: http)
        try await client.attach(endpoint: endpoint)

        do {
            try await client.verifyAdministrator(token: "wrong")
            XCTFail("expected rejection")
        } catch {
            XCTAssertEqual(
                error as? RouterAdministrationError, .invalidAdministratorToken
            )
        }
        do {
            try await client.verifyAdministrator(token: "wlt_client")
            XCTFail("expected client-token rejection")
        } catch {
            XCTAssertEqual(error as? RouterAdministrationError, .clientTokenRejected)
        }
        let stored = try await store.readToken(for: endpoint, role: .administrator)
        XCTAssertNil(stored)
    }

    func testAdminRequiredWithWrongStatusIsNotClassifiedAsClientToken() async throws {
        let expected = NetworkError.api(
            status: 409,
            code: .adminRequired,
            message: "Pairing state conflict"
        )
        let http = ScriptedRouterHTTPClient(results: [.failure(expected)])
        let (client, store) = makeClient(http: http)
        try await client.attach(endpoint: endpoint)

        do {
            try await client.verifyAdministrator(token: "boot-admin")
            XCTFail("expected API error")
        } catch let error as NetworkError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let stored = try await store.readToken(for: endpoint, role: .administrator)
        XCTAssertNil(stored)
    }

    func testStaleGenerationVerificationCannotSaveUnderReplacedEndpoint() async throws {
        let http = ScriptedRouterHTTPClient(
            results: [ScriptedRouterHTTPClient.ok("{}")],
            gateRequests: true
        )
        let (client, store) = makeClient(http: http)
        try await client.attach(endpoint: endpoint)

        let verification = Task { try await client.verifyAdministrator(token: "boot-admin") }
        await http.waitForGateRegistration()
        try await client.attach(endpoint: otherEndpoint)
        http.releaseGates()

        do {
            try await verification.value
            XCTFail("expected stale verification to be discarded")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let oldStored = try await store.readToken(for: endpoint, role: .administrator)
        let newStored = try await store.readToken(for: otherEndpoint, role: .administrator)
        XCTAssertNil(oldStored)
        XCTAssertNil(newStored)
    }

    func testReattachDuringCredentialSaveRemovesStaleAdministratorToken() async throws {
        let http = ScriptedRouterHTTPClient(results: [ScriptedRouterHTTPClient.ok("{}")])
        let backend = AdministrationCredentialBackend(gateSaves: true)
        let (client, store) = makeClient(http: http, backend: backend)
        try await client.attach(endpoint: endpoint)

        let verification = Task { try await client.verifyAdministrator(token: "boot-admin") }
        await backend.waitForSaveToStart()
        try await client.attach(endpoint: otherEndpoint)
        await backend.releaseSave()

        do {
            try await verification.value
            XCTFail("expected stale verification to be discarded")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let oldStored = try await store.readToken(for: endpoint, role: .administrator)
        let newStored = try await store.readToken(for: otherEndpoint, role: .administrator)
        XCTAssertNil(oldStored)
        XCTAssertNil(newStored)
    }

    func testSameAccountSuccessorCredentialSurvivesStaleSaveCompletion() async throws {
        let http = ScriptedRouterHTTPClient(results: [
            ScriptedRouterHTTPClient.ok("{}"),
            ScriptedRouterHTTPClient.ok("{}"),
        ])
        let backend = FirstSaveGatedCredentialBackend()
        let store = RouterCredentialStore(backend: backend)
        let client = RouterAdministrationClient(credentials: store) { _ in http }
        try await client.attach(endpoint: endpoint)

        let stale = Task {
            try await client.verifyAdministrator(token: "stale-admin")
        }
        await backend.waitForFirstSaveToStart()
        try await client.attach(endpoint: endpoint)

        let successor = Task {
            try await client.verifyAdministrator(token: "current-admin")
        }
        while http.calls.count < 2 { await Task.yield() }
        await backend.releaseFirstSave()
        try await successor.value

        do {
            try await stale.value
            XCTFail("expected stale save to be discarded")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let stored = try await store.readToken(for: endpoint, role: .administrator)
        XCTAssertEqual(stored, "current-admin")
    }

    func testSameAccountStaleSaveWithoutSuccessorLeavesNoCredential() async throws {
        let http = ScriptedRouterHTTPClient(results: [ScriptedRouterHTTPClient.ok("{}")])
        let backend = FirstSaveGatedCredentialBackend()
        let store = RouterCredentialStore(backend: backend)
        let client = RouterAdministrationClient(credentials: store) { _ in http }
        try await client.attach(endpoint: endpoint)

        let stale = Task {
            try await client.verifyAdministrator(token: "stale-admin")
        }
        await backend.waitForFirstSaveToStart()
        try await client.attach(endpoint: endpoint)
        await backend.releaseFirstSave()

        do {
            try await stale.value
            XCTFail("expected stale save to be discarded")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let stored = try await store.readToken(for: endpoint, role: .administrator)
        XCTAssertNil(stored)
    }

    func testCancelledURLErrorMapsToCancellationErrorAndDetachRequiresReattach() async throws {
        let http = ScriptedRouterHTTPClient(results: [
            .failure(URLError(.cancelled)),
        ])
        let (client, _) = makeClient(http: http)
        try await client.attach(endpoint: endpoint)

        do {
            try await client.verifyAdministrator(token: "boot-admin")
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        await client.detach()
        do {
            try await client.verifyAdministrator(token: "boot-admin")
            XCTFail("expected notAttached")
        } catch {
            XCTAssertEqual(error as? RouterAdministrationError, .notAttached)
        }
    }

    func testFailedReplacementAttachCannotReusePreviousRouterHTTPClient() async throws {
        let http = ScriptedRouterHTTPClient(results: [ScriptedRouterHTTPClient.ok("{}")])
        let store = RouterCredentialStore(backend: AdministrationCredentialBackend())
        let client = RouterAdministrationClient(credentials: store) { endpoint in
            guard endpoint.host != "other.local" else { throw NetworkError.invalidURL }
            return http
        }
        try await client.attach(endpoint: endpoint)

        do {
            try await client.attach(endpoint: otherEndpoint)
            XCTFail("expected replacement HTTP construction to fail")
        } catch NetworkError.invalidURL {
        } catch {
            XCTFail("unexpected attach error: \(error)")
        }
        do {
            try await client.verifyAdministrator(token: "boot-admin")
            XCTFail("expected failed replacement attach to leave the client detached")
        } catch {
            XCTAssertEqual(error as? RouterAdministrationError, .notAttached)
        }

        XCTAssertTrue(http.calls.isEmpty)
        let stored = try await store.readToken(for: otherEndpoint, role: .administrator)
        XCTAssertNil(stored)
    }
}

private actor AdministrationCredentialBackend: RouterCredentialBackend {
    private var values: [String: Data] = [:]
    private let gateSaves: Bool
    private var saveStarted = false
    private var saveStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var saveGate: CheckedContinuation<Void, Never>?

    init(gateSaves: Bool = false) {
        self.gateSaves = gateSaves
    }

    func read(account: String) async throws -> Data? { values[account] }

    func save(_ data: Data, account: String) async throws {
        saveStarted = true
        let waiters = saveStartedWaiters
        saveStartedWaiters = []
        waiters.forEach { $0.resume() }
        if gateSaves {
            await withCheckedContinuation { saveGate = $0 }
        }
        values[account] = data
    }

    func delete(account: String) async throws { values[account] = nil }

    func waitForSaveToStart() async {
        if saveStarted { return }
        await withCheckedContinuation { saveStartedWaiters.append($0) }
    }

    func releaseSave() {
        saveGate?.resume()
        saveGate = nil
    }
}

private actor FirstSaveGatedCredentialBackend: RouterCredentialBackend {
    private var values: [String: Data] = [:]
    private var saveCount = 0
    private var firstSaveStarted = false
    private var firstSaveStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstSaveGate: CheckedContinuation<Void, Never>?

    func read(account: String) async throws -> Data? { values[account] }

    func save(_ data: Data, account: String) async throws {
        saveCount += 1
        if saveCount == 1 {
            firstSaveStarted = true
            let waiters = firstSaveStartedWaiters
            firstSaveStartedWaiters = []
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { firstSaveGate = $0 }
        }
        values[account] = data
    }

    func delete(account: String) async throws { values[account] = nil }

    func waitForFirstSaveToStart() async {
        if firstSaveStarted { return }
        await withCheckedContinuation { firstSaveStartedWaiters.append($0) }
    }

    func releaseFirstSave() {
        firstSaveGate?.resume()
        firstSaveGate = nil
    }
}
