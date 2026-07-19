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

    func testManualVerificationRejectsNon200SuccessWithoutSavingCredential() async throws {
        let backend = AdministrationCredentialBackend()
        let http = ScriptedRouterHTTPClient(results: [
            ScriptedRouterHTTPClient.response(status: 201, "{}"),
            ScriptedRouterHTTPClient.response(status: 204, ""),
        ])
        let (client, store) = makeClient(http: http, backend: backend)
        try await client.attach(endpoint: endpoint)

        for status in [201, 204] {
            do {
                try await client.verifyAdministrator(token: "candidate-\(status)")
                XCTFail("expected status \(status) rejection")
            } catch {
                XCTAssertEqual(error as? RouterAdministrationError, .invalidResponse)
            }
        }

        let stored = try await store.readToken(for: endpoint, role: .administrator)
        let saveCount = await backend.saveCount
        XCTAssertNil(stored)
        XCTAssertEqual(saveCount, 0)
    }

    func testStoredVerificationRequires200WithoutRewritingOrDeletingCredential() async throws {
        let backend = AdministrationCredentialBackend()
        let http = ScriptedRouterHTTPClient(results: [
            ScriptedRouterHTTPClient.response(status: 204, ""),
        ])
        let (client, store) = makeClient(http: http, backend: backend)
        try await store.saveToken("stored-admin", for: endpoint, role: .administrator)
        try await client.attach(endpoint: endpoint)

        do {
            try await client.verifyStoredAdministrator()
            XCTFail("expected exact-status rejection")
        } catch {
            XCTAssertEqual(error as? RouterAdministrationError, .invalidResponse)
        }

        let stored = try await store.readToken(for: endpoint, role: .administrator)
        let saveCount = await backend.saveCount
        XCTAssertEqual(stored, "stored-admin")
        XCTAssertEqual(saveCount, 1)
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

    func testStaleUnauthorizedSendIsCancellationBeforeAuthTranslation() async throws {
        let http = ScriptedRouterHTTPClient(
            results: [.failure(NetworkError.unauthorized)],
            gateRequests: true
        )
        let (client, store) = makeClient(http: http)
        try await store.saveToken("old-admin", for: endpoint, role: .administrator)
        try await client.attach(endpoint: endpoint)

        let stale = Task {
            try await client.send("GET", "/api/v1/pairing-mode")
        }
        await http.waitForGateRegistration()
        try await client.attach(endpoint: endpoint)
        http.releaseGates()

        do {
            _ = try await stale.value
            XCTFail("expected stale request cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testStaleMissingCredentialReadIsCancellationBeforeAuthTranslation() async throws {
        let backend = FirstReadGatedCredentialBackend()
        let store = RouterCredentialStore(backend: backend)
        let http = ScriptedRouterHTTPClient(results: [])
        let client = RouterAdministrationClient(credentials: store) { _ in http }
        try await client.attach(endpoint: endpoint)

        let stale = Task {
            try await client.send("GET", "/api/v1/pairing-mode")
        }
        await backend.waitForFirstReadToStart()
        try await client.attach(endpoint: endpoint)
        await backend.releaseFirstRead()

        do {
            _ = try await stale.value
            XCTFail("expected stale credential read cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(http.calls.isEmpty)
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

    func testStoredUnauthorizedDeletionFinishesBeforeReplacementCredentialSave() async throws {
        let http = ScriptedRouterHTTPClient(results: [
            .failure(NetworkError.unauthorized),
            ScriptedRouterHTTPClient.ok("{}"),
        ])
        let backend = FirstDeleteGatedCredentialBackend()
        let store = RouterCredentialStore(backend: backend)
        let client = RouterAdministrationClient(credentials: store) { _ in http }
        try await store.saveToken("stale-admin", for: endpoint, role: .administrator)
        try await client.attach(endpoint: endpoint)

        let stale = Task { try await client.verifyStoredAdministrator() }
        await backend.waitForFirstDeleteToStart()
        try await client.attach(endpoint: endpoint)
        let successor = Task {
            try await client.verifyAdministrator(token: "current-admin")
        }
        await http.waitForCallCount(2)
        await backend.releaseFirstDelete()

        try await successor.value
        do {
            try await stale.value
            XCTFail("expected stale stored-token verification to be discarded")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let stored = try await store.readToken(for: endpoint, role: .administrator)
        XCTAssertEqual(stored, "current-admin")
    }

    func testReattachBeforeStoredUnauthorizedDeletionSuppressesStaleDelete() async throws {
        let administratorAccount = "\(endpoint.peripheralID.uuidString).administrator"
        let backend = InitialValueCountingCredentialBackend(
            account: administratorAccount,
            value: Data("stale-admin".utf8)
        )
        let store = RouterCredentialStore(backend: backend)
        let http = ScriptedRouterHTTPClient(
            results: [.failure(NetworkError.unauthorized)],
            gateRequests: true
        )
        let client = RouterAdministrationClient(credentials: store) { _ in http }
        try await client.attach(endpoint: endpoint)

        let stale = Task { try await client.verifyStoredAdministrator() }
        await http.waitForGateRegistration()
        try await client.attach(endpoint: endpoint)
        http.releaseGates()

        do {
            try await stale.value
            XCTFail("expected old-generation work to be discarded")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let deleteCount = await backend.deleteCount
        XCTAssertEqual(deleteCount, 0)
        let stored = try await store.readToken(for: endpoint, role: .administrator)
        XCTAssertEqual(stored, "stale-admin")
    }

    func testExplicitClearFinishesBeforeLaterAdministratorSave() async throws {
        let http = ScriptedRouterHTTPClient(results: [ScriptedRouterHTTPClient.ok("{}")])
        let backend = FirstDeleteGatedCredentialBackend()
        let store = RouterCredentialStore(backend: backend)
        let client = RouterAdministrationClient(credentials: store) { _ in http }
        try await store.saveToken("old-admin", for: endpoint, role: .administrator)
        try await client.attach(endpoint: endpoint)

        let clear = Task { try await client.clearAdministratorCredential() }
        await backend.waitForFirstDeleteToStart()
        let successor = Task {
            try await client.verifyAdministrator(token: "current-admin")
        }
        await http.waitForCallCount(1)
        await backend.releaseFirstDelete()

        try await clear.value
        try await successor.value
        let stored = try await store.readToken(for: endpoint, role: .administrator)
        XCTAssertEqual(stored, "current-admin")
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

private actor FirstReadGatedCredentialBackend: RouterCredentialBackend {
    private var firstReadStarted = false
    private var firstReadStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstReadGate: CheckedContinuation<Void, Never>?

    func read(account: String) async throws -> Data? {
        guard firstReadStarted == false else { return nil }
        firstReadStarted = true
        let waiters = firstReadStartedWaiters
        firstReadStartedWaiters = []
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { firstReadGate = $0 }
        return nil
    }

    func save(_ data: Data, account: String) async throws {}
    func delete(account: String) async throws {}

    func waitForFirstReadToStart() async {
        if firstReadStarted { return }
        await withCheckedContinuation { firstReadStartedWaiters.append($0) }
    }

    func releaseFirstRead() {
        firstReadGate?.resume()
        firstReadGate = nil
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

private actor FirstDeleteGatedCredentialBackend: RouterCredentialBackend {
    private var values: [String: Data] = [:]
    private var deleteCount = 0
    private var firstDeleteStarted = false
    private var firstDeleteStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstDeleteGate: CheckedContinuation<Void, Never>?

    func read(account: String) async throws -> Data? { values[account] }
    func save(_ data: Data, account: String) async throws { values[account] = data }

    func delete(account: String) async throws {
        deleteCount += 1
        if deleteCount == 1 {
            firstDeleteStarted = true
            let waiters = firstDeleteStartedWaiters
            firstDeleteStartedWaiters = []
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { firstDeleteGate = $0 }
        }
        values[account] = nil
    }

    func waitForFirstDeleteToStart() async {
        if firstDeleteStarted { return }
        await withCheckedContinuation { firstDeleteStartedWaiters.append($0) }
    }

    func releaseFirstDelete() {
        firstDeleteGate?.resume()
        firstDeleteGate = nil
    }
}

private actor InitialValueCountingCredentialBackend: RouterCredentialBackend {
    private var values: [String: Data]
    private(set) var deleteCount = 0

    init(account: String, value: Data) {
        values = [account: value]
    }

    func read(account: String) async throws -> Data? { values[account] }
    func save(_ data: Data, account: String) async throws { values[account] = data }

    func delete(account: String) async throws {
        deleteCount += 1
        values[account] = nil
    }

}
