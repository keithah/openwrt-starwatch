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

    func testStoredUnauthorizedDeletionCannotEraseReplacementSessionCredential() async throws {
        let backend = FirstDeleteGatedAdministrationBackend()
        let fixture = try await makeFixture(
            results: [
                .failure(NetworkError.unauthorized),
                AdminScriptedHTTP.ok("{}"),
                AdminScriptedHTTP.ok("{}"),
            ],
            credentialBackend: backend
        )
        try await fixture.credentialStore.saveToken(
            "stale-admin",
            for: fixture.host.endpoint,
            role: .administrator
        )

        let staleBegin = Task { await fixture.model.begin(host: fixture.host) }
        await backend.waitForFirstDeleteToStart()
        await fixture.model.begin(host: fixture.host)
        let replacementUnlock = Task {
            await fixture.model.unlock(token: "current-admin")
        }
        await fixture.http.waitForCallCount(3)
        await backend.releaseFirstDelete()
        await staleBegin.value
        await replacementUnlock.value

        XCTAssertEqual(fixture.model.host, fixture.host)
        XCTAssertEqual(fixture.model.access, .unlocked)
        let stored = try await fixture.credentialStore.readToken(
            for: fixture.host.endpoint,
            role: .administrator
        )
        XCTAssertEqual(stored, "current-admin")
    }

    func testStoredAdministratorReverificationDoesNotRewriteCredential() async throws {
        let backend = FirstDeleteGatedAdministrationBackend()
        let fixture = try await makeFixture(
            results: [AdminScriptedHTTP.ok("{}")],
            credentialBackend: backend
        )
        try await fixture.credentialStore.saveToken(
            "stored-admin",
            for: fixture.host.endpoint,
            role: .administrator
        )

        await fixture.model.begin(host: fixture.host)

        XCTAssertEqual(fixture.model.access, .unlocked)
        let saveCount = await backend.saveCount
        XCTAssertEqual(saveCount, 1)
    }

    func testLockInvalidatesInFlightUnlockSaveAndLeavesNoCredential() async throws {
        let backend = FirstSaveGatedAdministrationBackend()
        let fixture = try await makeFixture(
            results: [AdminScriptedHTTP.ok("{}")],
            credentialBackend: backend
        )
        await fixture.model.begin(host: fixture.host)

        let unlock = Task { await fixture.model.unlock(token: "current-admin") }
        await backend.waitForFirstSaveToStart()
        let lock = Task { await fixture.model.lock() }
        while fixture.model.access != .locked { await Task.yield() }
        await backend.releaseFirstSave()
        await unlock.value
        await lock.value

        XCTAssertEqual(fixture.model.access, .locked)
        let stored = try await fixture.credentialStore.readToken(
            for: fixture.host.endpoint,
            role: .administrator
        )
        XCTAssertNil(stored)
    }

    func testEndLocksAndStaleUnlockCannotPublishIntoNextSession() async throws {
        let fixture = try await makeFixture(
            results: [AdminScriptedHTTP.ok("{}")],
            gateRequests: true
        )
        await fixture.model.begin(host: fixture.host)

        let unlock = Task { await fixture.model.unlock(token: "boot-admin") }
        await fixture.http.waitForGateRegistration()
        await fixture.model.end()
        fixture.http.releaseGates()
        await unlock.value

        XCTAssertEqual(fixture.model.access, .locked)
    }

    func testAppModelOwnsInjectedAdministrationBoundToSuppliedConnections() async throws {
        let fixture = try await makeFixture(results: [AdminScriptedHTTP.ok("{}")])
        let suite = "RouterAdministrationModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let app = AppModel(
            persistence: AppPersistence(defaults: defaults),
            transportFactory: { fatalError("Bluetooth transport must remain lazy") },
            snapshotCoordinator: nil,
            widgetReloadAdapter: nil,
            routerConnections: fixture.connections,
            routerAdministration: fixture.model
        )

        XCTAssertTrue(app.routerConnections === fixture.connections)
        XCTAssertTrue(app.routerAdministration === fixture.model)
        await app.routerAdministration.begin(host: fixture.host)
        await app.routerAdministration.unlock(token: "injected-admin")

        let stored = try await fixture.credentialStore.readToken(
            for: fixture.host.endpoint,
            role: .administrator
        )
        XCTAssertEqual(stored, "injected-admin")
        XCTAssertEqual(fixture.http.calls.map(\.token), ["injected-admin"])
    }

    func testScanPresentationOffersAdministrationOnlyForSavedHost() async throws {
        let fixture = try await makeFixture(results: [])
        let saved = AppDeviceConnectionRecord(
            id: "saved",
            identity: nil,
            bluetoothDevice: nil,
            discoveredRouter: nil,
            routerHost: fixture.host,
            transportOptions: [.router],
            preferredTransport: .router
        )
        let unsaved = AppDeviceConnectionRecord(
            id: "unsaved",
            identity: nil,
            bluetoothDevice: DiscoveredDevice(
                id: UUID(),
                localName: "Link-Power",
                rssi: -40,
                mode: .application
            ),
            discoveredRouter: nil,
            routerHost: nil,
            transportOptions: [.bluetooth],
            preferredTransport: .bluetooth
        )

        XCTAssertTrue(ScanRecordPresentation(record: saved).offersRouterAdministration)
        XCTAssertFalse(ScanRecordPresentation(record: unsaved).offersRouterAdministration)
    }
}

@MainActor
private struct AdministrationFixture {
    let model: RouterAdministrationModel
    let connections: RouterConnectionModel
    let host: RouterHostMetadata
    let credentialStore: RouterCredentialStore
    let http: AdminScriptedHTTP
}

@MainActor
private func makeFixture(
    results: [Result<(Data, HTTPURLResponse), Error>],
    gateRequests: Bool = false,
    credentialBackend: any RouterCredentialBackend = AdministrationMemoryBackend()
) async throws -> AdministrationFixture {
    let host = try RouterHostValidator.validate(
        "https://router.local:8378",
        displayName: "Garage router",
        reachability: .lan,
        allowsInsecureWAN: false,
        deviceID: "DC:04:5A:EB:72:2B",
        certificateFingerprint: String(repeating: "0", count: 64)
    )
    let credentialStore = RouterCredentialStore(backend: credentialBackend)
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
        model: model,
        connections: connections,
        host: host,
        credentialStore: credentialStore,
        http: http
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
    private var gateRegistrationWaiters: [CheckedContinuation<Void, Never>] = []
    private var callCountWaiters: [(minimum: Int, continuation: CheckedContinuation<Void, Never>)] = []
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
        if shouldGate {
            await withCheckedContinuation { gate in
                let (gateWaiters, callWaiters) = lock.withLock {
                    recorded.append(Call(method: method, path: path, token: token))
                    gates.append(gate)
                    let gateWaiters = gateRegistrationWaiters
                    gateRegistrationWaiters = []
                    let callWaiters = removeSatisfiedCallCountWaiters()
                    return (gateWaiters, callWaiters)
                }
                gateWaiters.forEach { $0.resume() }
                callWaiters.forEach { $0.resume() }
            }
        } else {
            let callWaiters = lock.withLock {
                recorded.append(Call(method: method, path: path, token: token))
                return removeSatisfiedCallCountWaiters()
            }
            callWaiters.forEach { $0.resume() }
        }
        let result = lock.withLock { scripted.isEmpty ? nil : scripted.removeFirst() }
        guard let result else { throw NetworkError.decode("admin HTTP fixture exhausted") }
        return try result.get()
    }

    func waitForGateRegistration() async {
        await withCheckedContinuation { continuation in
            let isAlreadyRegistered = lock.withLock {
                guard gates.isEmpty else { return true }
                gateRegistrationWaiters.append(continuation)
                return false
            }
            if isAlreadyRegistered { continuation.resume() }
        }
    }

    func waitForCallCount(_ minimum: Int) async {
        await withCheckedContinuation { continuation in
            let isAlreadySatisfied = lock.withLock {
                guard recorded.count < minimum else { return true }
                callCountWaiters.append((minimum, continuation))
                return false
            }
            if isAlreadySatisfied { continuation.resume() }
        }
    }

    func releaseGates() {
        let pending = lock.withLock {
            let pending = gates
            gates.removeAll()
            return pending
        }
        pending.forEach { $0.resume() }
    }

    private func removeSatisfiedCallCountWaiters() -> [CheckedContinuation<Void, Never>] {
        let satisfied = callCountWaiters.filter { recorded.count >= $0.minimum }
        callCountWaiters.removeAll { recorded.count >= $0.minimum }
        return satisfied.map(\.continuation)
    }
}

private actor AdministrationMemoryBackend: RouterCredentialBackend {
    private var values: [String: Data] = [:]
    func read(account: String) async throws -> Data? { values[account] }
    func save(_ data: Data, account: String) async throws { values[account] = data }
    func delete(account: String) async throws { values[account] = nil }
}

private actor FirstDeleteGatedAdministrationBackend: RouterCredentialBackend {
    private var values: [String: Data] = [:]
    private(set) var saveCount = 0
    private var deleteCount = 0
    private var firstDeleteStarted = false
    private var firstDeleteStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstDeleteGate: CheckedContinuation<Void, Never>?

    func read(account: String) async throws -> Data? { values[account] }
    func save(_ data: Data, account: String) async throws {
        values[account] = data
        saveCount += 1
    }

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

private actor FirstSaveGatedAdministrationBackend: RouterCredentialBackend {
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
