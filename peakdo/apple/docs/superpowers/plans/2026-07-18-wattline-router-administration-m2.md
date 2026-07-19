# Wattline Router Administration — Milestone 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the router administration foundation: role-scoped credentials, administrator-token verification against `GET /api/v1/settings`, router history, pairing-mode/QR administration, and managed-token listing/revocation.

**Architecture:** `WattlineNetwork` gains a `RouterCredentialRole` on the existing Keychain store, a generation-isolated `RouterAdministrationClient` actor for privileged requests, and typed history/pairing/token DTOs. A new iOS `RouterAdministrationModel` (app target) drives an unlock-gated administration screen reachable from saved-router scan rows. `WattlineUI` gains a pure history presentation that never imports networking.

**Tech Stack:** Swift 6, Swift Package Manager, SwiftUI + Observation, Swift Charts (history), URLSession behind the existing `RouterHTTPClient` protocol, Security/Keychain behind `RouterCredentialBackend`, XCTest.

This plan expands **Milestone 2 (Tasks 6–11)** of
`peakdo/apple/docs/superpowers/plans/2026-07-18-wattline-router-administration.md`
to executable fidelity and supersedes that document's compressed M2 section.
Design authority: `peakdo/apple/docs/superpowers/specs/2026-07-18-wattline-router-administration-design.md`
§§2.1, 2.3, 3, 5, 6, 11. Contract authority (read-only):
`/Users/keith/src/openwrt-wattline/docs/api.md`.

Execute in the `codex/wattline-phase-2` worktree at
`/Users/keith/.codex/worktrees/wattline-phase-2` on top of `60a8500a`.

## Global Constraints

- The canonical router contract is `/Users/keith/src/openwrt-wattline/docs/api.md` plus its handlers and tests; do not edit that repository.
- Do not edit `peakdo/Wattline-SPEC.md`, `peakdo/API.md`, `peakdo/src/*`, `scan.py`, or `verify*.py`.
- OTA, firmware transfer, device Timers, cloud services, analytics, app-originated webhooks, automatic BT/router failover, and deprecated compatibility routes are excluded.
- Bluetooth remains the primary transport and each app process owns exactly one active `DeviceTransport`/BLE session. The administration client issues HTTP only; it must never construct a BLE transport, `DeviceSession`, or `DeviceOperationBroker`.
- `WattlineCore` stays free of networking, Security, SwiftUI, UIKit, AppKit, ActivityKit, WidgetKit, AppIntents, UserNotifications, and ServiceManagement.
- `WattlineUI` stays cross-platform SwiftUI, depends only on `WattlineCore`, and imports neither networking nor Security frameworks.
- Networking and Keychain APIs remain confined to `WattlineNetwork`; AVFoundation/Vision/AppKit/UIKit stay in thin app adapters.
- Client and bootstrap-administrator tokens use distinct Keychain accounts and never enter UserDefaults, snapshots, logs, errors, notifications, QR payloads, or diagnostics. The pairing PIN and QR PNG exist only in memory while their view is visible.
- Telemetry and router readback are truth: no optimistic pairing-mode, token, or history state. Every admin mutation re-reads or re-lists authoritative state.
- Unsupported/client-only/admin-only surfaces are structurally absent from the view tree, not disabled.
- Milestone 2 adds **no** settings editor, TLS rotation, router BLE pairing, advanced device controls, or rules (Milestones 3–5).
- iOS deployment remains 17.0+, bundle ID `com.keithah.wattline`.
- Every behavior starts with a non-vacuous failing test, then minimal implementation, green suites, and a focused commit.
- Simulator commands use `WATTLINE_SIMULATOR_NAME=${WATTLINE_SIMULATOR_NAME:-Wattline-Tests-2}`.
- The six-argument `RouterTransport` initializer and `RouterCredentialProvider.credential(for:)` signatures must not change (ABI regression gate from Milestone 1).

---

## File and ownership map (Milestone 2)

- `WattlineNetwork/Sources/WattlineNetwork/RouterCredentials.swift` — add `RouterCredentialRole`; role-suffixed Keychain accounts (modify).
- `WattlineNetwork/Sources/WattlineNetwork/RouterAdministrationClient.swift` — generation-isolated administrator actor and error enum (create).
- `WattlineNetwork/Sources/WattlineNetwork/RouterHistory.swift` — history DTO + client-role fetch (create).
- `WattlineNetwork/Sources/WattlineNetwork/RouterPairingAdministration.swift` — pairing-mode/QR/token DTOs and admin API (create).
- `WattlineNetwork/Sources/WattlineNetwork/RouterEnrollment.swift` — decode `token_metadata.id` additively (modify, Task 10).
- `WattlineNetwork/Sources/WattlineNetwork/RouterHostStore.swift` — optional `tokenID` on `RouterHostMetadata` (modify, Task 10).
- `WattlineUI/Sources/WattlineUI/RouterHistoryPresentation.swift` — pure history presentation over UI-local value types (create).
- `Wattline/Wattline/RouterAdministration/RouterAdministrationModel.swift` — observable session model (create).
- `Wattline/Wattline/RouterAdministration/RouterAdministrationView.swift` — unlock UI + structurally gated sections (create).
- `Wattline/Wattline/RouterAdministration/RouterHistoryView.swift` (create, Task 8).
- `Wattline/Wattline/RouterAdministration/RouterPairingModeView.swift` (create, Task 9).
- `Wattline/Wattline/RouterAdministration/RouterTokensView.swift` (create, Task 10).
- `Wattline/Wattline/RouterConnectionModel.swift` — expose `credentialStore` internally; add `returnToEnrollment(_:)` (modify).
- `Wattline/Wattline/AppModel.swift` — own one `RouterAdministrationModel` (modify).
- `Wattline/Wattline/ScanView.swift` — administration entry on saved-router rows (modify).

**Deviations from the master plan's compressed M2 sketch (deliberate):**

1. `RouterAdministrationModel` lives in `Wattline/Wattline/RouterAdministration/`, not `Wattline/WattlineShared/`. The latter already exists but is compiled into multiple targets; this Milestone 2 model owns iOS-only administration presentation state and must not leak into the widget extension. Milestone 5 Task 22 can extract the cross-platform portions while adding the macOS target.
2. `verifyAdministrator(token:)` returns proof of role (`Void`), not a `RouterSettings` value. The full settings DTO is Milestone 3 Task 12; verification per design §2.1 needs only the `200/401/403` distinction. Task 12 later adds `settings()` to the same actor.
3. `RouterHistoryPresentation` consumes a `WattlineUI`-local `RouterHistoryPoint` value type instead of the `WattlineNetwork` DTO, because `WattlineUI`'s package manifest depends only on `WattlineCore` and must stay that way. The app target maps DTO → point.
4. Task 10 adds `token_metadata.id` capture at enrollment (`RouterEnrollmentResult.tokenID`, optional `RouterHostMetadata.tokenID`). Milestone 1 discarded the token ID, but design §6.2's "revoking the managed token used by this Wattline endpoint" warning and cleanup require knowing our own token ID. Hosts persisted before this change decode `tokenID == nil` and receive the generic revocation confirmation; a self-revocation they can't detect still degrades safely through the existing client-401 path.
5. App tests use a small behavior-equivalent HTTP fixture rather than copying the Network test fixture verbatim. Pairing-secret publication is guarded by both the administration session generation and a dedicated secret generation, so clearing on background, dismissal, expiry, re-lock, or session end also quarantines responses already in flight.

---

## Task 6: Separate router credential roles without migrating the client account

**Files:**
- Modify: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterCredentials.swift`
- Test: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/DiscoveryAndCredentialsTests.swift`

**Interfaces:**
- Consumes: existing `RouterCredentialStore`, `RouterCredentialBackend`, `RouterEndpoint.peripheralID`.
- Produces: `public enum RouterCredentialRole: String, Sendable { case client, administrator }`;
  `readToken(for:role:)`, `saveToken(_:for:role:)`, `deleteToken(for:role:)` with `role` defaulted to `.client`.
  The client account string stays the bare endpoint-UUID string (existing installs keep their token);
  the administrator account is `"\(uuid).administrator"`.
  `credential(for:)` (the `RouterCredentialProvider` requirement used by `RouterTransport`) is untouched and client-only.

- [ ] **Step 1: Write the failing test**

Extend `CredentialBackendRecorder` in `DiscoveryAndCredentialsTests.swift` (it currently records only operations) so account strings are observable, then add the role test to the same suite:

```swift
// Inside `private actor CredentialBackendRecorder` add:
    private(set) var savedAccounts: [String] = []
// and inside its `save(_:account:)`, after the error check, add:
        savedAccounts.append(account)

func testCredentialRolesUseDistinctAccountsAndPreserveClientAccount() async throws {
    let backend = CredentialBackendRecorder()
    let store = RouterCredentialStore(backend: backend)

    try await store.saveToken("client-secret", for: endpoint)
    try await store.saveToken("admin-secret", for: endpoint, role: .administrator)

    let uuid = endpoint.peripheralID.uuidString
    let savedAccounts = await backend.savedAccounts
    XCTAssertEqual(savedAccounts, [uuid, "\(uuid).administrator"])

    XCTAssertEqual(try await store.readToken(for: endpoint), "client-secret")
    XCTAssertEqual(
        try await store.readToken(for: endpoint, role: .administrator),
        "admin-secret"
    )

    try await store.deleteToken(for: endpoint, role: .administrator)
    XCTAssertNil(try await store.readToken(for: endpoint, role: .administrator))
    XCTAssertEqual(try await store.readToken(for: endpoint), "client-secret")
    XCTAssertFalse(String(describing: store).contains("admin-secret"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/keith/.codex/worktrees/wattline-phase-2 && swift test --package-path peakdo/apple/WattlineNetwork --filter DiscoveryAndCredentialsTests`

Expected: FAIL to compile — `extra argument 'role' in call` (the role API does not exist).

- [ ] **Step 3: Write minimal implementation**

In `RouterCredentials.swift`, add the role enum above the store and thread it through the account computation. Default parameters keep every existing call site (including `RouterTransport` wiring and Milestone 1 tests) source-compatible:

```swift
public enum RouterCredentialRole: String, Sendable {
    case client
    case administrator
}
```

Change the three method signatures and the private account helper:

```swift
    public func readToken(
        for endpoint: RouterEndpoint,
        role: RouterCredentialRole = .client
    ) async throws -> String? {
        do {
            guard let data = try await backend.read(account: account(for: endpoint, role: role)),
                  let token = String(data: data, encoding: .utf8),
                  !token.isEmpty
            else { return nil }
            return token
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NetworkError.unauthorized
        }
    }

    public func saveToken(
        _ token: String,
        for endpoint: RouterEndpoint,
        role: RouterCredentialRole = .client
    ) async throws {
        guard !token.isEmpty else { throw NetworkError.unauthorized }
        do {
            try await backend.save(Data(token.utf8), account: account(for: endpoint, role: role))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NetworkError.unauthorized
        }
    }

    public func deleteToken(
        for endpoint: RouterEndpoint,
        role: RouterCredentialRole = .client
    ) async throws {
        do {
            try await backend.delete(account: account(for: endpoint, role: role))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NetworkError.unauthorized
        }
    }

    private func account(for endpoint: RouterEndpoint, role: RouterCredentialRole) -> String {
        let base = endpoint.peripheralID.uuidString
        return role == .client ? base : "\(base).administrator"
    }
```

`credential(for:)` keeps calling `readToken(for:)` (client default) and stays byte-for-byte compatible.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path peakdo/apple/WattlineNetwork`

Expected: PASS, 110+ tests, zero failures (109 baseline + the new test).

- [ ] **Step 5: Commit**

```bash
git add peakdo/apple/WattlineNetwork
git commit -m "feat: separate router credential roles"
```

---

## Task 7: Generation-isolated administrator verification and gated administration shell

**Files:**
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterAdministrationClient.swift`
- Create: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/ScriptedRouterHTTPClient.swift`
- Test: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterAdministrationClientTests.swift`
- Create: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterAdministrationModel.swift`
- Create: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterAdministrationView.swift`
- Modify: `peakdo/apple/Wattline/Wattline/RouterConnectionModel.swift` (`private let credentialStore` → `let credentialStore`)
- Modify: `peakdo/apple/Wattline/Wattline/AppModel.swift`
- Modify: `peakdo/apple/Wattline/Wattline/ScanView.swift`
- Test: `peakdo/apple/Wattline/WattlineTests/RouterAdministrationModelTests.swift`

**Interfaces:**
- Consumes: Task 6 roles, `RouterHTTPClient`, `RouterHTTPErrorMapper` semantics (non-2xx throws `NetworkError`), `RouterEndpoint`, `RouterHostMetadata`.
- Produces:
  - `public enum RouterAdministrationError: Error, Equatable, Sendable { case notAttached, invalidAdministratorToken, clientTokenRejected, protectedToken, invalidResponse }`
  - `public actor RouterAdministrationClient` with `init(credentials: RouterCredentialStore, httpFactory: @escaping @Sendable (RouterEndpoint) throws -> any RouterHTTPClient)`, `attach(endpoint:) throws`, `detach()`, `verifyAdministrator(token:) async throws`, and the internal `send(_:_:body:) async throws -> (Data, HTTPURLResponse)` helper Tasks 9–10 build on.
  - App: `RouterAdministrationModel` (`AdminAccess` enum `.locked/.verifying/.unlocked`, `begin(host:)`, `end()`, `unlock(token:)`, `lock()`), `RouterAdministrationPresentation` (visible sections), `RouterAdministrationView(host:)`, `AppModel.routerAdministration`.
- Test double produced for later tasks: `ScriptedRouterHTTPClient` (records calls, replays scripted results, optional gate for in-flight suspension).

- [ ] **Step 1: Write the failing Network tests**

Create `ScriptedRouterHTTPClient.swift` (internal to the test module — Tasks 8–10 reuse it):

```swift
import Foundation
import WattlineNetwork
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Deterministic RouterHTTPClient double. Mirrors production HTTPClient behavior:
/// scripted errors are thrown pre-mapped (HTTPClient maps non-2xx via
/// RouterHTTPErrorMapper before returning), successes return (Data, 200-response).
final class ScriptedRouterHTTPClient: RouterHTTPClient, @unchecked Sendable {
    struct Call: Equatable {
        let method: String
        let path: String
        let body: Data?
        let token: String
    }

    private let lock = NSLock()
    private var results: [Result<(Data, HTTPURLResponse), Error>]
    private var pendingGates: [CheckedContinuation<Void, Never>] = []
    private var _calls: [Call] = []
    private let gateRequests: Bool

    init(
        results: [Result<(Data, HTTPURLResponse), Error>],
        gateRequests: Bool = false
    ) {
        self.results = results
        self.gateRequests = gateRequests
    }

    var calls: [Call] { lock.withLock { _calls } }

    static func ok(
        _ json: String,
        contentType: String = "application/json"
    ) -> Result<(Data, HTTPURLResponse), Error> {
        .success((
            Data(json.utf8),
            HTTPURLResponse(
                url: URL(string: "https://router.local:8378")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": contentType]
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
            _calls.append(Call(method: method, path: path, body: body, token: token))
        }
        if gateRequests {
            await withCheckedContinuation { continuation in
                lock.withLock { pendingGates.append(continuation) }
            }
        }
        let next = lock.withLock { results.isEmpty ? nil : results.removeFirst() }
        guard let next else { throw NetworkError.decode("ScriptedRouterHTTPClient exhausted") }
        return try next.get()
    }

    func releaseGates() {
        let gates = lock.withLock {
            let value = pendingGates
            pendingGates = []
            return value
        }
        gates.forEach { $0.resume() }
    }
}
```

Create `RouterAdministrationClientTests.swift`:

```swift
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
        http: ScriptedRouterHTTPClient
    ) -> (RouterAdministrationClient, RouterCredentialStore) {
        let store = RouterCredentialStore(backend: AdministrationCredentialBackend())
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
        XCTAssertNil(try await store.readToken(for: endpoint))
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
        XCTAssertNil(try await store.readToken(for: endpoint, role: .administrator))
    }

    func testStaleGenerationVerificationCannotSaveUnderReplacedEndpoint() async throws {
        let http = ScriptedRouterHTTPClient(
            results: [ScriptedRouterHTTPClient.ok("{}")],
            gateRequests: true
        )
        let (client, store) = makeClient(http: http)
        try await client.attach(endpoint: endpoint)

        let verification = Task { try await client.verifyAdministrator(token: "boot-admin") }
        while http.calls.isEmpty { await Task.yield() }
        try await client.attach(endpoint: otherEndpoint)
        http.releaseGates()

        do {
            try await verification.value
            XCTFail("expected stale verification to be discarded")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertNil(try await store.readToken(for: endpoint, role: .administrator))
        XCTAssertNil(try await store.readToken(for: otherEndpoint, role: .administrator))
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
}

private actor AdministrationCredentialBackend: RouterCredentialBackend {
    private var values: [String: Data] = [:]
    func read(account: String) async throws -> Data? { values[account] }
    func save(_ data: Data, account: String) async throws { values[account] = data }
    func delete(account: String) async throws { values[account] = nil }
}
```

- [ ] **Step 2: Run Network tests to verify they fail**

Run: `swift test --package-path peakdo/apple/WattlineNetwork --filter RouterAdministrationClientTests`

Expected: FAIL to compile — `cannot find 'RouterAdministrationClient' in scope`.

- [ ] **Step 3: Implement the actor**

Create `RouterAdministrationClient.swift`:

```swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum RouterAdministrationError: Error, Equatable, Sendable {
    case notAttached
    case invalidAdministratorToken
    case clientTokenRejected
    case protectedToken
    case invalidResponse
}

/// Serializes privileged router requests for one endpoint at a time.
/// Attaching a different endpoint increments a generation; completions from a
/// previous generation are discarded as CancellationError and can never save
/// credentials or publish results into the replacement session.
public actor RouterAdministrationClient {
    public typealias HTTPFactory = @Sendable (RouterEndpoint) throws -> any RouterHTTPClient

    private let credentials: RouterCredentialStore
    private let httpFactory: HTTPFactory
    private var generation: UInt64 = 0
    private var endpoint: RouterEndpoint?
    private var http: (any RouterHTTPClient)?

    public init(credentials: RouterCredentialStore, httpFactory: @escaping HTTPFactory) {
        self.credentials = credentials
        self.httpFactory = httpFactory
    }

    public func attach(endpoint: RouterEndpoint) throws {
        generation &+= 1
        self.endpoint = endpoint
        http = try httpFactory(endpoint)
    }

    public func detach() {
        generation &+= 1
        endpoint = nil
        http = nil
    }

    public func verifyAdministrator(token: String) async throws {
        guard let endpoint, let http else { throw RouterAdministrationError.notAttached }
        guard !token.isEmpty else { throw RouterAdministrationError.invalidAdministratorToken }
        let requestGeneration = generation
        do {
            _ = try await http.get("/api/v1/settings", token: token)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch NetworkError.unauthorized {
            throw RouterAdministrationError.invalidAdministratorToken
        } catch NetworkError.api(_, RouterAPIErrorCode.adminRequired, _) {
            throw RouterAdministrationError.clientTokenRejected
        }
        guard generation == requestGeneration else { throw CancellationError() }
        try await credentials.saveToken(token, for: endpoint, role: .administrator)
    }

    /// Shared admin-authenticated request path for pairing-mode and token routes.
    /// A missing stored administrator credential surfaces as
    /// invalidAdministratorToken so the model re-locks instead of retrying.
    func send(
        _ method: String,
        _ path: String,
        body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        guard let endpoint, let http else { throw RouterAdministrationError.notAttached }
        let requestGeneration = generation
        guard let token = try await credentials.readToken(
            for: endpoint, role: .administrator
        ) else { throw RouterAdministrationError.invalidAdministratorToken }
        guard generation == requestGeneration else { throw CancellationError() }
        do {
            let result = try await http.request(method, path, body: body, token: token)
            guard generation == requestGeneration else { throw CancellationError() }
            return result
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch NetworkError.unauthorized {
            throw RouterAdministrationError.invalidAdministratorToken
        }
    }
}
```

- [ ] **Step 4: Run Network tests to verify they pass**

Run: `swift test --package-path peakdo/apple/WattlineNetwork --filter RouterAdministrationClientTests && swift test --package-path peakdo/apple/WattlineNetwork`

Expected: PASS, zero failures.

- [ ] **Step 5: Write the failing app-model tests**

Create `RouterAdministrationModelTests.swift`. The fixture wires a real `RouterConnectionModel` (in-memory backends, as in `RouterAppWiringTests`) plus a `RouterAdministrationClient` whose HTTP is scripted per test:

```swift
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
```

Add the fixture and doubles at the bottom of the same file:

```swift
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
```

`AdminScriptedHTTP` is an app-test-local, behavior-equivalent `RouterHTTPClient`
fixture because app tests cannot import the Network test module. Do not copy the
Network fixture verbatim: keep only the call recording, scripted-result, and
targeted gate behavior these model tests exercise. `AdministrationMemoryBackend`
is a dictionary-backed `RouterCredentialBackend` actor;
`AdministrationHostBackend` is a dictionary-backed `RouterHostKeyValueStore`
(follow the protocol shape used by `DiscoveryHostBackend` without duplicating
unrelated helpers); `AdministrationNoopEnrollmentHTTP` conforms to
`RouterEnrollmentHTTPClient` and throws `NetworkError.unsupported("unused")`.

- [ ] **Step 6: Run app tests to verify they fail**

Run: `WATTLINE_SIMULATOR_NAME=${WATTLINE_SIMULATOR_NAME:-Wattline-Tests-2}; xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination "platform=iOS Simulator,name=${WATTLINE_SIMULATOR_NAME}" CODE_SIGNING_ALLOWED=NO -only-testing:WattlineTests/RouterAdministrationModelTests`

Expected: FAIL to compile — `cannot find 'RouterAdministrationModel' in scope`.

- [ ] **Step 7: Implement model, presentation, view, and wiring**

In `RouterConnectionModel.swift` change the store's access level (line ~55) so the app can share it with the administration client:

```swift
    let credentialStore: RouterCredentialStore
```

Create `RouterAdministrationModel.swift`:

```swift
import Foundation
import Observation
import WattlineNetwork

@MainActor
@Observable
final class RouterAdministrationModel {
    enum AdminAccess: Equatable {
        case locked
        case verifying
        case unlocked
    }

    private(set) var host: RouterHostMetadata?
    private(set) var access: AdminAccess = .locked
    private(set) var adminError: String?

    private let connections: RouterConnectionModel
    private let adminClient: RouterAdministrationClient
    private var sessionGeneration: UInt64 = 0

    init(connections: RouterConnectionModel, adminClient: RouterAdministrationClient) {
        self.connections = connections
        self.adminClient = adminClient
    }

    func begin(host: RouterHostMetadata) async {
        sessionGeneration &+= 1
        let generation = sessionGeneration
        self.host = host
        access = .locked
        adminError = nil
        do {
            try await adminClient.attach(endpoint: host.endpoint)
        } catch {
            guard sessionGeneration == generation else { return }
            adminError = "Could not prepare a connection to this router."
            return
        }
        guard sessionGeneration == generation,
              let stored = try? await connections.credentialStore.readToken(
                  for: host.endpoint, role: .administrator
              ),
              sessionGeneration == generation
        else { return }
        access = .verifying
        do {
            try await adminClient.verifyAdministrator(token: stored)
            guard sessionGeneration == generation else { return }
            access = .unlocked
        } catch {
            guard sessionGeneration == generation else { return }
            access = .locked
            await invalidateAdminCredentialIfRejected(error, endpoint: host.endpoint)
        }
    }

    func end() async {
        sessionGeneration &+= 1
        host = nil
        access = .locked
        adminError = nil
        await adminClient.detach()
    }

    func unlock(token: String) async {
        guard host != nil, access != .verifying else { return }
        let generation = sessionGeneration
        access = .verifying
        adminError = nil
        do {
            try await adminClient.verifyAdministrator(token: token)
            guard sessionGeneration == generation else { return }
            access = .unlocked
        } catch is CancellationError {
            guard sessionGeneration == generation else { return }
            access = .locked
        } catch {
            guard sessionGeneration == generation else { return }
            access = .locked
            adminError = Self.unlockMessage(for: error)
        }
    }

    func lock() async {
        guard let host else { return }
        access = .locked
        adminError = nil
        try? await connections.credentialStore.deleteToken(
            for: host.endpoint, role: .administrator
        )
    }

    private func invalidateAdminCredentialIfRejected(
        _ error: Error, endpoint: RouterEndpoint
    ) async {
        guard case RouterAdministrationError.invalidAdministratorToken = error else { return }
        try? await connections.credentialStore.deleteToken(
            for: endpoint, role: .administrator
        )
    }

    private static func unlockMessage(for error: Error) -> String {
        switch error {
        case RouterAdministrationError.invalidAdministratorToken:
            "That administrator token was rejected."
        case RouterAdministrationError.clientTokenRejected:
            "That is a managed client token. Administration needs the bootstrap administrator token."
        default:
            "Could not verify the administrator token. Try again."
        }
    }
}

struct RouterAdministrationPresentation: Equatable {
    enum Section: Equatable {
        case connectionAndHistory
        case clientEnrollment
        case apiClients
    }

    let visibleSections: [Section]
    let showsUnlockField: Bool

    init(access: RouterAdministrationModel.AdminAccess) {
        showsUnlockField = access != .unlocked
        visibleSections = access == .unlocked
            ? [.connectionAndHistory, .clientEnrollment, .apiClients]
            : [.connectionAndHistory]
    }
}
```

Create `RouterAdministrationView.swift` (sections beyond unlock/history are filled by Tasks 8–10; keep placeholders structurally absent, not disabled):

```swift
import SwiftUI
import WattlineNetwork

struct RouterAdministrationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var adminToken = ""
    let host: RouterHostMetadata

    private var admin: RouterAdministrationModel { model.routerAdministration }

    var body: some View {
        let presentation = RouterAdministrationPresentation(access: admin.access)
        NavigationStack {
            Form {
                Section("Router") {
                    LabeledContent("Name", value: host.displayName)
                    LabeledContent("Address", value: "\(host.host):\(host.port)")
                }

                if presentation.showsUnlockField {
                    Section("Administration") {
                        SecureField("Administrator token", text: $adminToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button(admin.access == .verifying ? "Verifying…" : "Unlock administration") {
                            let token = adminToken
                            adminToken = ""
                            Task { await admin.unlock(token: token) }
                        }
                        .disabled(adminToken.isEmpty || admin.access == .verifying)
                    } footer: {
                        Text("The administrator token is verified against the router and stored in Keychain. Wattline cannot promote a managed client token.")
                    }
                } else {
                    Section("Administration") {
                        Button("Lock administration", role: .destructive) {
                            Task { await admin.lock() }
                        }
                    }
                }

                if let message = admin.adminError {
                    Section { Text(message).foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Router Administration")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await admin.begin(host: host) }
            .onDisappear { Task { await admin.end() } }
        }
    }
}
```

In `AppModel.swift`, add the stored property next to `routerConnections` (line ~223) and construct it in `init` after `self.routerConnections = routerConnections`, with a defaulted parameter so existing tests are untouched:

```swift
    let routerAdministration: RouterAdministrationModel
```

```swift
        // In the init parameter list:
        routerAdministration: RouterAdministrationModel? = nil,
```

```swift
        // In the init body, immediately after self.routerConnections = routerConnections:
        self.routerAdministration = routerAdministration ?? RouterAdministrationModel(
            connections: routerConnections,
            adminClient: RouterAdministrationClient(
                credentials: routerConnections.credentialStore,
                httpFactory: { try HTTPClient(endpoint: $0) }
            )
        )
```

In `ScanView.swift`, add administration entry. Add state next to the other `@State` properties:

```swift
    @State private var administrationHost: RouterHostMetadata?
```

Replace the row `Menu` condition so saved-router rows always offer a menu, and add the item (currently the menu renders only when `presentation.offersRouterAction`):

```swift
                                    if presentation.offersRouterAction || record.routerHost != nil {
                                        Menu {
                                            if presentation.offersRouterAction {
                                                Button(record.routerHost == nil ? "Enroll with router" : "Connect via router") {
                                                    performRouterAction(record)
                                                }
                                            }
                                            if let host = record.routerHost {
                                                Button("Router administration") {
                                                    administrationHost = host
                                                }
                                            }
                                        } label: {
                                            Image(systemName: "ellipsis.circle")
                                                .font(.title3)
                                                .foregroundStyle(.secondary)
                                        }
                                        .accessibilityLabel("Router options for \(presentation.title)")
                                    }
```

Add the sheet alongside the existing sheets:

```swift
            .sheet(item: $administrationHost) { host in
                RouterAdministrationView(host: host)
            }
```

(`RouterHostMetadata` is already `Identifiable`.)

- [ ] **Step 8: Run app tests to verify they pass**

Run the Step 6 command, then the full scheme:
`xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination "platform=iOS Simulator,name=${WATTLINE_SIMULATOR_NAME}" CODE_SIGNING_ALLOWED=NO`

Expected: PASS, zero failures (177 baseline + 4 new).

- [ ] **Step 9: Commit**

```bash
git add peakdo/apple/WattlineNetwork peakdo/apple/Wattline/Wattline peakdo/apple/Wattline/WattlineTests
git commit -m "feat: verify router administrator sessions"
```

---

## Task 8: Decode and present router history

**Files:**
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterHistory.swift`
- Test: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterHistoryTests.swift`
- Create: `peakdo/apple/WattlineUI/Sources/WattlineUI/RouterHistoryPresentation.swift`
- Test: `peakdo/apple/WattlineUI/Tests/WattlineUITests/RouterHistoryPresentationTests.swift`
- Create: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterHistoryView.swift`
- Modify: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterAdministrationModel.swift`
- Modify: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterAdministrationView.swift`
- Modify: `peakdo/apple/Wattline/Wattline/AppModel.swift`
- Test: `peakdo/apple/Wattline/WattlineTests/RouterAdministrationModelTests.swift`

**Interfaces:**
- Consumes: `RouterHTTPClient`, `RouterCredentialProvider` (client role — history is a client route), Task 7 model/session generation.
- Produces:
  - `public struct RouterHistorySample: Equatable, Sendable, Decodable` — `at: Date`, `level: Int`, `status: Int` (signed), `dcWatts: Double?`, `typeCWatts: Double?` from exact keys `at/level/status/dc_w/typec_w`.
  - `public struct RouterHistoryClient` — `init(httpClient:credentials:endpoint:)`, `fetch() async throws -> [RouterHistorySample]` (GET `/api/v1/history`, bearer = client credential).
  - WattlineUI: `public struct RouterHistoryPoint` (`at/level/dcWatts/typeCWatts`, public init), `public struct RouterHistoryPowerPoint` (`at/watts: Double?`, public init), `public struct RouterHistoryPresentation` (`init(points:fetchedAt:)`, `points` sorted ascending, `powerPoints` nil-honest aggregate, `isEmpty`, `fetchedAt`).
  - Model: `history: [RouterHistorySample]`, `historyFetchedAt: Date?`, `historyError: String?`, `reloadHistory() async`; init gains `historyClientFactory:` and `now:`.

- [ ] **Step 1: Write the failing Network test**

`RouterHistoryTests.swift`:

```swift
import Foundation
import XCTest
@testable import WattlineNetwork

final class RouterHistoryTests: XCTestCase {
    private let endpoint = RouterEndpoint(
        scheme: "https",
        host: "router.local",
        port: 8378,
        certificateFingerprint: String(repeating: "0", count: 64),
        allowsInsecureWAN: false
    )

    func testFetchDecodesExactContractFieldsWithClientToken() async throws {
        let body = #"""
        [{"at":"2026-07-17T19:59:00Z","level":77,"status":1,"dc_w":12.0,"typec_w":20.0},
         {"at":"2026-07-17T20:00:00Z","level":76,"status":-1}]
        """#
        let http = ScriptedRouterHTTPClient(results: [ScriptedRouterHTTPClient.ok(body)])
        let client = RouterHistoryClient(
            httpClient: http,
            credentials: TransientRouterCredentialProvider(token: "wlt_client"),
            endpoint: endpoint
        )

        let samples = try await client.fetch()

        XCTAssertEqual(http.calls, [.init(
            method: "GET", path: "/api/v1/history", body: nil, token: "wlt_client"
        )])
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0].level, 77)
        XCTAssertEqual(samples[0].status, 1)
        XCTAssertEqual(samples[0].dcWatts, 12.0)
        XCTAssertEqual(samples[0].typeCWatts, 20.0)
        XCTAssertEqual(samples[1].status, -1)
        XCTAssertNil(samples[1].dcWatts)
        XCTAssertNil(samples[1].typeCWatts)
        XCTAssertEqual(
            samples[1].at.timeIntervalSince(samples[0].at), 60, accuracy: 0.001
        )
    }

    func testEmptyArrayAndInvalidDateBehaveHonestly() async throws {
        let http = ScriptedRouterHTTPClient(results: [
            ScriptedRouterHTTPClient.ok("[]"),
            ScriptedRouterHTTPClient.ok(#"[{"at":"yesterday","level":1,"status":0}]"#),
        ])
        let client = RouterHistoryClient(
            httpClient: http,
            credentials: TransientRouterCredentialProvider(token: "wlt_client"),
            endpoint: endpoint
        )

        let empty = try await client.fetch()
        XCTAssertEqual(empty, [])

        do {
            _ = try await client.fetch()
            XCTFail("expected decode failure")
        } catch {
            guard case NetworkError.decode = error else {
                return XCTFail("expected NetworkError.decode, got \(error)")
            }
        }
    }
}
```

- [ ] **Step 2: Run to verify RED**

Run: `swift test --package-path peakdo/apple/WattlineNetwork --filter RouterHistoryTests`

Expected: FAIL to compile — `cannot find 'RouterHistoryClient' in scope`.

- [ ] **Step 3: Implement `RouterHistory.swift`**

```swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct RouterHistorySample: Equatable, Sendable, Decodable {
    public let at: Date
    public let level: Int
    public let status: Int
    public let dcWatts: Double?
    public let typeCWatts: Double?

    private enum CodingKeys: String, CodingKey {
        case at
        case level
        case status
        case dcWatts = "dc_w"
        case typeCWatts = "typec_w"
    }
}

/// Client-role history fetch. History is the router's bounded cache; Wattline
/// never fabricates samples or persists a second history database.
public struct RouterHistoryClient: Sendable {
    private let httpClient: any RouterHTTPClient
    private let credentials: any RouterCredentialProvider
    private let endpoint: RouterEndpoint

    public init(
        httpClient: any RouterHTTPClient,
        credentials: any RouterCredentialProvider,
        endpoint: RouterEndpoint
    ) {
        self.httpClient = httpClient
        self.credentials = credentials
        self.endpoint = endpoint
    }

    public func fetch() async throws -> [RouterHistorySample] {
        let credential = try await credentials.credential(for: endpoint)
        let (data, _) = try await httpClient.get("/api/v1/history", token: credential.token)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([RouterHistorySample].self, from: data)
        } catch {
            throw NetworkError.decode("History payload was not valid")
        }
    }
}
```

- [ ] **Step 4: Run Network suite GREEN**

Run: `swift test --package-path peakdo/apple/WattlineNetwork`

Expected: PASS, zero failures.

- [ ] **Step 5: Write the failing WattlineUI presentation test**

`RouterHistoryPresentationTests.swift` (in `peakdo/apple/WattlineUI/Tests/WattlineUITests/`):

```swift
import Foundation
import XCTest
@testable import WattlineUI

final class RouterHistoryPresentationTests: XCTestCase {
    func testPointsSortAscendingAndPowerAggregatesWithoutFabrication() {
        let earlier = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 1_060)
        let presentation = RouterHistoryPresentation(
            points: [
                RouterHistoryPoint(at: later, level: 76, dcWatts: nil, typeCWatts: nil),
                RouterHistoryPoint(at: earlier, level: 77, dcWatts: 12.0, typeCWatts: 20.0),
            ],
            fetchedAt: later
        )

        XCTAssertFalse(presentation.isEmpty)
        XCTAssertEqual(presentation.points.map(\.at), [earlier, later])
        XCTAssertEqual(presentation.powerPoints, [
            RouterHistoryPowerPoint(at: earlier, watts: 32.0),
            RouterHistoryPowerPoint(at: later, watts: nil),
        ])
        XCTAssertEqual(presentation.fetchedAt, later)
    }

    func testSingleNilSideStillAggregatesAndEmptyStateIsHonest() {
        let at = Date(timeIntervalSince1970: 2_000)
        let presentation = RouterHistoryPresentation(
            points: [RouterHistoryPoint(at: at, level: 50, dcWatts: nil, typeCWatts: 7.5)],
            fetchedAt: nil
        )
        XCTAssertEqual(presentation.powerPoints, [
            RouterHistoryPowerPoint(at: at, watts: 7.5)
        ])

        let empty = RouterHistoryPresentation(points: [], fetchedAt: nil)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertNil(empty.fetchedAt)
    }
}
```

- [ ] **Step 6: Run to verify RED**

Run: `swift test --package-path peakdo/apple/WattlineUI --filter RouterHistoryPresentationTests`

Expected: FAIL to compile — missing presentation types.

- [ ] **Step 7: Implement `RouterHistoryPresentation.swift` in WattlineUI**

```swift
import Foundation

public struct RouterHistoryPoint: Equatable, Sendable {
    public let at: Date
    public let level: Int
    public let dcWatts: Double?
    public let typeCWatts: Double?

    public init(at: Date, level: Int, dcWatts: Double?, typeCWatts: Double?) {
        self.at = at
        self.level = level
        self.dcWatts = dcWatts
        self.typeCWatts = typeCWatts
    }
}

public struct RouterHistoryPowerPoint: Equatable, Sendable {
    public let at: Date
    public let watts: Double?

    public init(at: Date, watts: Double?) {
        self.at = at
        self.watts = watts
    }
}

public struct RouterHistoryPresentation: Equatable, Sendable {
    public let points: [RouterHistoryPoint]
    public let powerPoints: [RouterHistoryPowerPoint]
    public let fetchedAt: Date?

    public var isEmpty: Bool { points.isEmpty }

    public init(points: [RouterHistoryPoint], fetchedAt: Date?) {
        let sorted = points.sorted { $0.at < $1.at }
        self.points = sorted
        powerPoints = sorted.map { point in
            let watts: Double? = switch (point.dcWatts, point.typeCWatts) {
            case (nil, nil): nil
            case let (dc, typeC): (dc ?? 0) + (typeC ?? 0)
            }
            return RouterHistoryPowerPoint(at: point.at, watts: watts)
        }
        self.fetchedAt = fetchedAt
    }
}
```

- [ ] **Step 8: Run UI suite GREEN**

Run: `swift test --package-path peakdo/apple/WattlineUI`

Expected: PASS, zero failures.

- [ ] **Step 9: Write the failing model test, then wire model and view**

Add to `RouterAdministrationModelTests.swift`:

```swift
    func testReloadHistoryIsLazyStampsFetchTimeAndQuarantinesStaleSessions() async throws {
        let sample = #"[{"at":"2026-07-17T19:59:00Z","level":77,"status":1,"dc_w":12.0,"typec_w":20.0}]"#
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try await makeFixture(
            results: [AdminScriptedHTTP.ok("{}")],
            historyResults: [AdminScriptedHTTP.ok(sample)],
            now: { fixedNow }
        )
        await fixture.model.begin(host: fixture.host)
        XCTAssertEqual(fixture.model.history, [])
        XCTAssertNil(fixture.model.historyFetchedAt)

        await fixture.model.reloadHistory()

        XCTAssertEqual(fixture.model.history.count, 1)
        XCTAssertEqual(fixture.model.history.first?.level, 77)
        XCTAssertEqual(fixture.model.historyFetchedAt, fixedNow)

        await fixture.model.end()
        XCTAssertEqual(fixture.model.history, [])
    }
```

Extend the fixture: `makeFixture` gains `historyResults: [Result<(Data, HTTPURLResponse), Error>] = []` and `now: @escaping () -> Date = { Date() }`, builds `let historyHTTP = AdminScriptedHTTP(results: historyResults, gateRequests: false)`, and passes to the model:

```swift
    let model = RouterAdministrationModel(
        connections: connections,
        adminClient: RouterAdministrationClient(credentials: credentialStore) { _ in http },
        historyClientFactory: { endpoint in
            RouterHistoryClient(
                httpClient: historyHTTP,
                credentials: credentialStore,
                endpoint: endpoint
            )
        },
        now: now
    )
```

The test also needs the client credential in place so the history fetch can authenticate — add to the fixture before returning:

```swift
    try await credentialStore.saveToken("wlt_client", for: host.endpoint)
```

Model changes (`RouterAdministrationModel.swift`) — new stored state, init parameters, `reloadHistory`, and clearing in `end()`:

```swift
    private(set) var history: [RouterHistorySample] = []
    private(set) var historyFetchedAt: Date?
    private(set) var historyError: String?

    private let historyClientFactory: (RouterEndpoint) throws -> RouterHistoryClient
    private let now: () -> Date

    init(
        connections: RouterConnectionModel,
        adminClient: RouterAdministrationClient,
        historyClientFactory: @escaping (RouterEndpoint) throws -> RouterHistoryClient,
        now: @escaping () -> Date = { Date() }
    ) {
        self.connections = connections
        self.adminClient = adminClient
        self.historyClientFactory = historyClientFactory
        self.now = now
    }

    func reloadHistory() async {
        guard let host else { return }
        let generation = sessionGeneration
        do {
            let client = try historyClientFactory(host.endpoint)
            let samples = try await client.fetch()
            guard sessionGeneration == generation else { return }
            history = samples
            historyFetchedAt = now()
            historyError = nil
        } catch {
            guard sessionGeneration == generation else { return }
            historyError = "Could not load router history."
        }
    }
```

In `end()`, after `adminError = nil`, add:

```swift
        history = []
        historyFetchedAt = nil
        historyError = nil
```

Update `AppModel.swift` default construction (Task 7 block) to pass the factory:

```swift
        self.routerAdministration = routerAdministration ?? RouterAdministrationModel(
            connections: routerConnections,
            adminClient: RouterAdministrationClient(
                credentials: routerConnections.credentialStore,
                httpFactory: { try HTTPClient(endpoint: $0) }
            ),
            historyClientFactory: { [credentials = routerConnections.credentialStore] endpoint in
                RouterHistoryClient(
                    httpClient: try HTTPClient(endpoint: endpoint),
                    credentials: credentials,
                    endpoint: endpoint
                )
            }
        )
```

Create `RouterHistoryView.swift`:

```swift
import Charts
import SwiftUI
import WattlineNetwork
import WattlineUI

struct RouterHistoryView: View {
    let model: RouterAdministrationModel

    private var presentation: RouterHistoryPresentation {
        RouterHistoryPresentation(
            points: model.history.map {
                RouterHistoryPoint(
                    at: $0.at, level: $0.level,
                    dcWatts: $0.dcWatts, typeCWatts: $0.typeCWatts
                )
            },
            fetchedAt: model.historyFetchedAt
        )
    }

    var body: some View {
        Group {
            if presentation.isEmpty {
                ContentUnavailableView {
                    Label("No history yet", systemImage: "chart.xyaxis.line")
                } description: {
                    Text("The router records about one sample per minute while it can reach the Link-Power.")
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Chart(presentation.points, id: \.at) { point in
                        LineMark(
                            x: .value("Time", point.at),
                            y: .value("Battery %", point.level)
                        )
                    }
                    .chartYScale(domain: 0...100)
                    .frame(minHeight: 160)

                    Chart(presentation.powerPoints.filter { $0.watts != nil }, id: \.at) { point in
                        LineMark(
                            x: .value("Time", point.at),
                            y: .value("Watts", point.watts ?? 0)
                        )
                    }
                    .frame(minHeight: 120)

                    if let fetchedAt = presentation.fetchedAt {
                        Text("Fetched \(fetchedAt.formatted(date: .omitted, time: .standard))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .task { await model.reloadHistory() }
    }
}
```

In `RouterAdministrationView.swift`, add the history section between the "Router" section and the unlock section (client-role surface — always present for a saved host, per `RouterAdministrationPresentation.visibleSections` containing `.connectionAndHistory`):

```swift
                Section("History") {
                    RouterHistoryView(model: admin)
                    if let message = admin.historyError {
                        Text(message).foregroundStyle(.orange)
                    }
                    Button("Refresh history") {
                        Task { await admin.reloadHistory() }
                    }
                }
```

- [ ] **Step 10: Run RED→GREEN and full suites**

Run the app suite command from Task 7 Step 6 (RED first if you wrote the test before the model change — expected compile failure on `historyClientFactory`), then after implementation:

```bash
swift test --package-path peakdo/apple/WattlineNetwork
swift test --package-path peakdo/apple/WattlineUI
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination "platform=iOS Simulator,name=${WATTLINE_SIMULATOR_NAME}" CODE_SIGNING_ALLOWED=NO
```

Expected: PASS, zero failures everywhere.

- [ ] **Step 11: Commit**

```bash
git add peakdo/apple/WattlineNetwork peakdo/apple/WattlineUI peakdo/apple/Wattline/Wattline peakdo/apple/Wattline/WattlineTests
git commit -m "feat: add router history"
```

---

## Task 9: Pairing-mode secret lifecycle and QR sharing

**Files:**
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterPairingAdministration.swift`
- Test: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterPairingAdministrationTests.swift`
- Create: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterPairingModeView.swift`
- Modify: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterAdministrationModel.swift`
- Modify: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterAdministrationView.swift`
- Test: `peakdo/apple/Wattline/WattlineTests/RouterAdministrationModelTests.swift`

**Interfaces:**
- Consumes: Task 7 `RouterAdministrationClient.send(_:_:body:)`, model session generation, injected `now`.
- Produces:
  - `public struct RouterPairingMode: Equatable, Sendable, Decodable` — `open: Bool`, `expiresAt: Date`, `pin: String?`; redacted `description`/`debugDescription`.
  - `RouterAdministrationClient` extensions: `pairingMode()`, `openPairingMode()` (POST, zero-byte body), `closePairingMode()` (DELETE, zero-byte body, decodes `{"open":false}`), `pairingQRCodePNG()` (GET `/api/v1/pairing-mode/qr.png`, no query, requires `image/png`).
  - Model: `pairingStatus: RouterPairingMode?`, `pairingQRPNG: Data?`, `pairingError: String?`, `reloadPairingMode()`, `openPairing()`, `closePairing()`, `loadPairingQR()`, `clearPairingSecrets()`, `expirePairingSecretsIfNeeded()`; admin-401 handling via `handleAdminFailure(_:)` that re-locks and clears secrets.

- [ ] **Step 1: Write the failing Network tests**

`RouterPairingAdministrationTests.swift`:

```swift
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

        try await client.closePairingMode()

        XCTAssertEqual(http.calls.map(\.method), ["GET", "POST", "DELETE"])
        XCTAssertEqual(
            http.calls.map(\.path),
            Array(repeating: "/api/v1/pairing-mode", count: 3)
        )
        XCTAssertEqual(http.calls.map(\.body), [nil, nil, nil])
    }

    func testQRFetchHasNoQueryRequiresPNGAndSurfacesClosedState() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let http = ScriptedRouterHTTPClient(results: [
            .success((
                png,
                HTTPURLResponse(
                    url: URL(string: "https://router.local:8378")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "image/png", "Cache-Control": "no-store"]
                )!
            )),
            ScriptedRouterHTTPClient.ok("{}"),
        ])
        let client = try await makeAttachedClient(http: http)

        let data = try await client.pairingQRCodePNG()
        XCTAssertEqual(data, png)
        XCTAssertEqual(http.calls[0].path, "/api/v1/pairing-mode/qr.png")
        XCTAssertNil(http.calls[0].body)

        do {
            _ = try await client.pairingQRCodePNG()
            XCTFail("expected non-PNG rejection")
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
```

- [ ] **Step 2: Run to verify RED**

Run: `swift test --package-path peakdo/apple/WattlineNetwork --filter RouterPairingAdministrationTests`

Expected: FAIL to compile — `pairingMode` and friends do not exist.

- [ ] **Step 3: Implement `RouterPairingAdministration.swift`**

```swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct RouterPairingMode: Equatable, Sendable, Decodable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    public let open: Bool
    public let expiresAt: Date
    public let pin: String?

    private enum CodingKeys: String, CodingKey {
        case open
        case expiresAt = "expires_at"
        case pin
    }

    public var description: String { "RouterPairingMode(open: \(open), pin: [REDACTED])" }
    public var debugDescription: String { description }
}

extension RouterAdministrationClient {
    public func pairingMode() async throws -> RouterPairingMode {
        let (data, _) = try await send("GET", "/api/v1/pairing-mode")
        return try Self.decodePairingMode(data)
    }

    public func openPairingMode() async throws -> RouterPairingMode {
        let (data, _) = try await send("POST", "/api/v1/pairing-mode")
        return try Self.decodePairingMode(data)
    }

    public func closePairingMode() async throws {
        struct Closed: Decodable { let open: Bool }
        let (data, _) = try await send("DELETE", "/api/v1/pairing-mode")
        guard let closed = try? JSONDecoder().decode(Closed.self, from: data),
              closed.open == false
        else { throw RouterAdministrationError.invalidResponse }
    }

    public func pairingQRCodePNG() async throws -> Data {
        let (data, response) = try await send("GET", "/api/v1/pairing-mode/qr.png")
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard contentType.hasPrefix("image/png"), !data.isEmpty else {
            throw RouterAdministrationError.invalidResponse
        }
        return data
    }

    private static func decodePairingMode(_ data: Data) throws -> RouterPairingMode {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let mode = try? decoder.decode(RouterPairingMode.self, from: data) else {
            throw RouterAdministrationError.invalidResponse
        }
        return mode
    }
}
```

- [ ] **Step 4: Run Network suite GREEN**

Run: `swift test --package-path peakdo/apple/WattlineNetwork`

Expected: PASS, zero failures.

- [ ] **Step 5: Write the failing model tests**

Add to `RouterAdministrationModelTests.swift` (extend `makeFixture` — the single scripted `http` already feeds the admin client, so pairing responses append to `results`):

```swift
    func testPairingSecretsExistOnlyWhileOpenAndClearOnExpiryEndAndAdmin401() async throws {
        let openBody = #"{"open":true,"expires_at":"2026-07-18T00:05:00Z","pin":"123456"}"#
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        var currentTime = ISO8601DateFormatter().date(from: "2026-07-18T00:00:00Z")!
        let fixture = try await makeFixture(
            results: [
                AdminScriptedHTTP.ok("{}"),        // unlock verification
                AdminScriptedHTTP.ok(openBody),    // POST open
                .success((png, AdminScriptedHTTP.pngResponse())),  // QR fetch
                .failure(NetworkError.unauthorized),               // later admin 401
            ],
            now: { currentTime }
        )
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")

        await fixture.model.openPairing()
        XCTAssertEqual(fixture.model.pairingStatus?.pin, "123456")

        await fixture.model.loadPairingQR()
        XCTAssertEqual(fixture.model.pairingQRPNG, png)

        currentTime = ISO8601DateFormatter().date(from: "2026-07-18T00:06:00Z")!
        fixture.model.expirePairingSecretsIfNeeded()
        XCTAssertNil(fixture.model.pairingStatus)
        XCTAssertNil(fixture.model.pairingQRPNG)

        await fixture.model.openPairing()   // scripted 401 → re-lock + clear
        XCTAssertEqual(fixture.model.access, .locked)
        XCTAssertNil(fixture.model.pairingStatus)
        XCTAssertNil(fixture.model.pairingQRPNG)
    }

    func testQRLoadIsStructurallyImpossibleWhileClosedOrLocked() async throws {
        let fixture = try await makeFixture(results: [AdminScriptedHTTP.ok("{}")])
        await fixture.model.begin(host: fixture.host)

        await fixture.model.loadPairingQR()   // locked → no HTTP
        XCTAssertNil(fixture.model.pairingQRPNG)

        await fixture.model.unlock(token: "boot-admin")
        await fixture.model.loadPairingQR()   // open != true → no HTTP
        XCTAssertNil(fixture.model.pairingQRPNG)
        XCTAssertEqual(fixture.http.calls.map(\.path), ["/api/v1/settings"])
    }

    func testClearingSecretsWhilePairingRequestIsInFlightPreventsLateResurrection() async throws {
        let openBody = #"{"open":true,"expires_at":"2026-07-18T00:05:00Z","pin":"123456"}"#
        let fixture = try await makeFixture(results: [
            AdminScriptedHTTP.ok("{}"),
            AdminScriptedHTTP.ok(openBody),
        ])
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")
        fixture.http.gateNextRequest()

        let opening = Task { await fixture.model.openPairing() }
        while fixture.http.calls.count < 2 { await Task.yield() }
        fixture.model.clearPairingSecrets() // models background/dismiss/expiry clearing
        fixture.http.releaseGates()
        await opening.value

        XCTAssertNil(fixture.model.pairingStatus)
        XCTAssertNil(fixture.model.pairingQRPNG)
    }
```

Add the PNG-response helper as a static on `AdminScriptedHTTP`:

```swift
    static func pngResponse() -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://router.local:8378")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "image/png"]
        )!
    }
```

- [ ] **Step 6: Run to verify RED**

Run the Task 7 Step 6 command. Expected: FAIL to compile — missing pairing members on the model.

- [ ] **Step 7: Implement model pairing state and the view**

Model additions:

```swift
    private(set) var pairingStatus: RouterPairingMode?
    private(set) var pairingQRPNG: Data?
    private(set) var pairingError: String?
    private var pairingSecretGeneration: UInt64 = 0

    func reloadPairingMode() async {
        pairingError = await performPairingAdmin { client in
            try await client.pairingMode()
        } apply: { [weak self] status in
            self?.pairingStatus = status
            if status.open == false { self?.pairingQRPNG = nil }
        }
    }

    func openPairing() async {
        pairingError = await performPairingAdmin { client in
            try await client.openPairingMode()
        } apply: { [weak self] status in
            self?.pairingStatus = status
        }
    }

    func closePairing() async {
        pairingError = await performPairingAdmin { client in
            try await client.closePairingMode()
        } apply: { [weak self] in
            self?.clearPairingSecrets()
        }
    }

    func loadPairingQR() async {
        guard pairingStatus?.open == true else { return }
        pairingError = await performPairingAdmin { client in
            try await client.pairingQRCodePNG()
        } apply: { [weak self] png in
            self?.pairingQRPNG = png
        }
    }

    func clearPairingSecrets() {
        pairingSecretGeneration &+= 1
        pairingStatus = nil
        pairingQRPNG = nil
    }

    func expirePairingSecretsIfNeeded() {
        guard let status = pairingStatus, status.open, status.expiresAt <= now() else { return }
        clearPairingSecrets()
    }

    /// Shared admin-call wrapper. The operation only talks to the router and
    /// returns a value; `apply` publishes it and runs strictly under the
    /// session-generation guard, so a stale completion racing end()/begin()
    /// can never resurrect cleared state or secrets. Returns a user-facing
    /// failure message for the caller's own error slot (nil on success,
    /// cancellation, stale session, or auth invalidation — auth invalidation
    /// re-locks and reports through adminError instead).
    private func performAdmin<Value>(
        _ operation: (RouterAdministrationClient) async throws -> Value,
        apply: (Value) -> Void
    ) async -> String? {
        guard host != nil, access == .unlocked else { return nil }
        let generation = sessionGeneration
        do {
            let value = try await operation(adminClient)
            guard sessionGeneration == generation else { return nil }
            apply(value)
            return nil
        } catch is CancellationError {
            return nil
        } catch RouterAdministrationError.invalidAdministratorToken {
            guard sessionGeneration == generation else { return nil }
            access = .locked
            clearPairingSecrets()
            adminError = "The administrator session is no longer valid."
            if let host {
                try? await connections.credentialStore.deleteToken(
                    for: host.endpoint, role: .administrator
                )
            }
            return nil
        } catch {
            guard sessionGeneration == generation else { return nil }
            return "The request failed. Try again."
        }
    }

    /// Pairing responses carry PIN/QR secrets. In addition to the session guard,
    /// they must match the secret generation so a response that completes after
    /// backgrounding, dismissal, expiry, re-lock, or explicit clearing cannot
    /// resurrect secret state.
    private func performPairingAdmin<Value>(
        _ operation: (RouterAdministrationClient) async throws -> Value,
        apply: (Value) -> Void
    ) async -> String? {
        let secretGeneration = pairingSecretGeneration
        return await performAdmin(operation) { [weak self] value in
            guard let self,
                  self.pairingSecretGeneration == secretGeneration
            else { return }
            apply(value)
        }
    }
```

In `end()`, add `clearPairingSecrets()` and `pairingError = nil`.

**Note:** the closure passed to `performAdmin` runs on the MainActor (the model is `@MainActor`), so `self?.pairingStatus = try await client...` assignments stay actor-isolated; `[weak self]` avoids a retain cycle through the stored model.

Create `RouterPairingModeView.swift`:

```swift
import SwiftUI
import UIKit
import WattlineNetwork

struct RouterPairingModeView: View {
    @Environment(\.scenePhase) private var scenePhase
    let model: RouterAdministrationModel

    var body: some View {
        Group {
            if let status = model.pairingStatus, status.open {
                if let pin = status.pin {
                    LabeledContent("Pairing PIN") {
                        Text(pin).monospacedDigit().textSelection(.enabled)
                    }
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Expires \(status.expiresAt.formatted(date: .omitted, time: .standard))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .onChange(of: context.date) {
                            model.expirePairingSecretsIfNeeded()
                        }
                }
                if let png = model.pairingQRPNG, let image = UIImage(data: png) {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(maxWidth: 240)
                        .accessibilityLabel("Router pairing QR code")
                    ShareLink(
                        item: Image(uiImage: image),
                        preview: SharePreview("Wattline pairing QR", image: Image(uiImage: image))
                    )
                } else {
                    Button("Show pairing QR") {
                        Task { await model.loadPairingQR() }
                    }
                }
                Button("Close pairing", role: .destructive) {
                    Task { await model.closePairing() }
                }
            } else {
                Text("Pairing is closed. Opening it shows a six-digit PIN and QR for about five minutes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Open pairing") {
                    Task { await model.openPairing() }
                }
            }
            if let message = model.pairingError {
                Text(message).foregroundStyle(.orange)
            }
        }
        .task { await model.reloadPairingMode() }
        .onDisappear { model.clearPairingSecrets() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.clearPairingSecrets() }
        }
    }
}
```

In `RouterAdministrationView.swift`, add after the unlock/lock section, gated structurally:

```swift
                if presentation.visibleSections.contains(.clientEnrollment) {
                    Section("Client enrollment") {
                        RouterPairingModeView(model: admin)
                    }
                }
```

- [ ] **Step 8: Run GREEN**

```bash
swift test --package-path peakdo/apple/WattlineNetwork
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination "platform=iOS Simulator,name=${WATTLINE_SIMULATOR_NAME}" CODE_SIGNING_ALLOWED=NO
```

Expected: PASS, zero failures.

- [ ] **Step 9: Commit**

```bash
git add peakdo/apple/WattlineNetwork peakdo/apple/Wattline/Wattline peakdo/apple/Wattline/WattlineTests
git commit -m "feat: administer router pairing mode"
```

---

## Task 10: List and revoke managed client tokens

**Files:**
- Modify: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterPairingAdministration.swift`
- Modify: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterEnrollment.swift`
- Modify: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterHostStore.swift`
- Test: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterPairingAdministrationTests.swift`
- Test: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterEnrollmentTests.swift`
- Create: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterTokensView.swift`
- Modify: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterAdministrationModel.swift`
- Modify: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterAdministrationView.swift`
- Modify: `peakdo/apple/Wattline/Wattline/RouterConnectionModel.swift`
- Test: `peakdo/apple/Wattline/WattlineTests/RouterAdministrationModelTests.swift`

**Interfaces:**
- Consumes: Task 7 `send`, Task 9 `performAdmin`/`handleAdminFailure`, `RouterEnrollmentClient`, `RouterHostValidator.validate`.
- Produces:
  - `public struct RouterTokenMetadata: Equatable, Sendable, Identifiable, Decodable` — `id/label/createdAt/lastSeenAt?/bootstrap` from `id/label/created_at/last_seen_at/bootstrap`. Metadata only; no secret field exists to decode.
  - `RouterAdministrationClient.tokens()`, `revokeToken(id:) -> String` (local empty/`bootstrap` rejection via `.protectedToken` before any HTTP; percent-encoded path; verifies `{"revoked": id}`).
  - `RouterEnrollmentResult.tokenID: String?` (decoded from `token_metadata.id`).
  - `RouterHostMetadata.tokenID: String?` (optional; legacy persisted hosts decode as nil). `RouterHostValidator.validate` gains `tokenID: String? = nil`.
  - `RouterConnectionModel.returnToEnrollment(_:)` — deletes only the client-role credential; host metadata and admin credential survive.
  - Model: `tokens: [RouterTokenMetadata]`, `tokensError: String?`, `reloadTokens()`, `revoke(_:)`, `isCurrentClient(_:)`.

- [ ] **Step 1: Write the failing Network tests**

Append to `RouterPairingAdministrationTests.swift`:

```swift
    func testTokenListDecodesMetadataOnly() async throws {
        let body = #"""
        [{"id":"bootstrap","label":"Bootstrap administrator","created_at":"2026-07-17T19:00:00Z","last_seen_at":"2026-07-17T20:00:00Z","bootstrap":true},
         {"id":"7dd64d22b0c14e7b","label":"Keith's iPhone","created_at":"2026-07-17T20:00:00Z","last_seen_at":null,"bootstrap":false}]
        """#
        let http = ScriptedRouterHTTPClient(results: [ScriptedRouterHTTPClient.ok(body)])
        let client = try await makeAttachedClient(http: http)

        let tokens = try await client.tokens()

        XCTAssertEqual(http.calls, [.init(
            method: "GET", path: "/api/v1/tokens", body: nil, token: "boot-admin"
        )])
        XCTAssertEqual(tokens.count, 2)
        XCTAssertTrue(tokens[0].bootstrap)
        XCTAssertNotNil(tokens[0].lastSeenAt)
        XCTAssertEqual(tokens[1].id, "7dd64d22b0c14e7b")
        XCTAssertNil(tokens[1].lastSeenAt)
        XCTAssertFalse(tokens[1].bootstrap)
    }

    func testRevokeRejectsProtectedIDsLocallyEncodesPathAndVerifiesResponse() async throws {
        let http = ScriptedRouterHTTPClient(results: [
            ScriptedRouterHTTPClient.ok(#"{"revoked":"7dd64d22b0c14e7b"}"#),
            ScriptedRouterHTTPClient.ok(#"{"revoked":"a b/c"}"#),
            ScriptedRouterHTTPClient.ok(#"{"revoked":"mismatch"}"#),
        ])
        let client = try await makeAttachedClient(http: http)

        for protected in ["", "bootstrap"] {
            do {
                _ = try await client.revokeToken(id: protected)
                XCTFail("expected local rejection for \(protected)")
            } catch {
                XCTAssertEqual(error as? RouterAdministrationError, .protectedToken)
            }
        }
        XCTAssertTrue(http.calls.isEmpty)

        let revoked = try await client.revokeToken(id: "7dd64d22b0c14e7b")
        XCTAssertEqual(revoked, "7dd64d22b0c14e7b")
        XCTAssertEqual(http.calls[0].method, "DELETE")
        XCTAssertEqual(http.calls[0].path, "/api/v1/tokens/7dd64d22b0c14e7b")

        _ = try await client.revokeToken(id: "a b/c")
        XCTAssertEqual(http.calls[1].path, "/api/v1/tokens/a%20b%2Fc")

        do {
            _ = try await client.revokeToken(id: "expected")
            XCTFail("expected revoked-ID mismatch rejection")
        } catch {
            XCTAssertEqual(error as? RouterAdministrationError, .invalidResponse)
        }
    }
```

Append to `RouterEnrollmentTests.swift` (reuse that file's existing fixture style for the enrollment HTTP double; the JSON below is the contract's exact `POST /pair` success):

```swift
    func testEnrollmentCapturesTokenMetadataIDAdditively() async throws {
        let body = #"""
        {"token":"wlt_7dd64d22b0c14e7bb86af967b63835f9f971b4234e83277b646d58e184a44af5","token_metadata":{"id":"7dd64d22b0c14e7b","label":"Keith's iPhone","created_at":"2026-07-17T20:00:00Z","last_seen_at":null,"bootstrap":false},"device_id":"DC:04:5A:EB:72:2B","base_urls":{"http":"http://wattline.lan:8377/api/v1"},"tls_sha256":"","magic_dns_name":""}
        """#
        let result = try await enroll(returning: body)   // this suite's existing helper pattern
        XCTAssertEqual(result.tokenID, "7dd64d22b0c14e7b")
        XCTAssertFalse(String(describing: result).contains("wlt_7dd64d22"))
    }

    func testLegacyHostMetadataWithoutTokenIDStillDecodes() throws {
        let legacy = #"""
        [{"id":"11111111-2222-3333-4444-555555555555","displayName":"Old router","scheme":"http","host":"router.lan","port":8377,"reachability":"lan","allowsInsecureWAN":false,"deviceID":"DC045AEB722B","certificateFingerprint":null}]
        """#
        let hosts = try JSONDecoder().decode([RouterHostMetadata].self, from: Data(legacy.utf8))
        XCTAssertEqual(hosts.count, 1)
        XCTAssertNil(hosts[0].tokenID)
    }
```

(If `RouterEnrollmentTests` has no single-call `enroll(returning:)` helper, inline the suite's existing enrollment-fixture invocation for a successful HTTP-only pair response — the assertion lines are what this step adds.)

- [ ] **Step 2: Run to verify RED**

Run: `swift test --package-path peakdo/apple/WattlineNetwork --filter 'RouterPairingAdministrationTests|RouterEnrollmentTests'`

Expected: FAIL to compile — `tokens()`, `revokeToken`, `tokenID` do not exist.

- [ ] **Step 3: Implement the Network changes**

Append to `RouterPairingAdministration.swift`:

```swift
public struct RouterTokenMetadata: Equatable, Sendable, Identifiable, Decodable {
    public let id: String
    public let label: String
    public let createdAt: Date
    public let lastSeenAt: Date?
    public let bootstrap: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case bootstrap
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
    }
}

extension RouterAdministrationClient {
    public func tokens() async throws -> [RouterTokenMetadata] {
        let (data, _) = try await send("GET", "/api/v1/tokens")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let list = try? decoder.decode([RouterTokenMetadata].self, from: data) else {
            throw RouterAdministrationError.invalidResponse
        }
        return list
    }

    @discardableResult
    public func revokeToken(id: String) async throws -> String {
        guard !id.isEmpty, id != "bootstrap" else {
            throw RouterAdministrationError.protectedToken
        }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw RouterAdministrationError.protectedToken
        }
        struct Revoked: Decodable { let revoked: String }
        let (data, _) = try await send("DELETE", "/api/v1/tokens/\(encoded)")
        guard let response = try? JSONDecoder().decode(Revoked.self, from: data),
              response.revoked == id
        else { throw RouterAdministrationError.invalidResponse }
        return response.revoked
    }
}
```

In `RouterEnrollment.swift`: add to `Response`

```swift
        struct TokenMetadata: Decodable {
            let id: String
        }
        let tokenMetadata: TokenMetadata?
```

with `case tokenMetadata = "token_metadata"` in its `CodingKeys`; add to `RouterEnrollmentResult`

```swift
    public let tokenID: String?
```

(the redacted `description` needs no change — the ID is server-listed metadata, but keep it out of the description anyway), and construct with `tokenID: decoded.tokenMetadata?.id` in `enroll`.

In `RouterHostStore.swift`: add to `RouterHostMetadata`

```swift
    public let tokenID: String?
```

Synthesized `Codable` decodes a missing key as nil, so previously persisted hosts load unchanged. Add `tokenID: String? = nil` as the last parameter of `RouterHostValidator.validate(...)` and pass it through to the struct construction.

In `RouterConnectionModel.swift`: thread the ID at the two enrollment construction sites — in `enroll(payload:...)` and in the private `host(result:...)` helper, pass `tokenID: result.tokenID` to `RouterHostValidator.validate`; `saveManualHost` relies on the default nil. Add:

```swift
    /// Design §6.2: after this endpoint's own managed token is revoked, drop only
    /// the client credential so the host row returns to enrollment. Host metadata
    /// and any administrator credential survive.
    func returnToEnrollment(_ host: RouterHostMetadata) async throws {
        try await credentialStore.deleteToken(for: host.endpoint, role: .client)
    }
```

- [ ] **Step 4: Run Network suite GREEN**

Run: `swift test --package-path peakdo/apple/WattlineNetwork`

Expected: PASS, zero failures.

- [ ] **Step 5: Write the failing model tests**

Append to `RouterAdministrationModelTests.swift`:

```swift
    func testRevokingCurrentClientDeletesOnlyClientCredentialAndRelists() async throws {
        let listBefore = #"[{"id":"7dd64d22b0c14e7b","label":"This iPhone","created_at":"2026-07-17T20:00:00Z","last_seen_at":null,"bootstrap":false}]"#
        let fixture = try await makeFixture(
            results: [
                AdminScriptedHTTP.ok("{}"),                         // unlock
                AdminScriptedHTTP.ok(listBefore),                   // initial list
                AdminScriptedHTTP.ok(#"{"revoked":"7dd64d22b0c14e7b"}"#),
                AdminScriptedHTTP.ok("[]"),                         // relist
            ],
            hostTokenID: "7dd64d22b0c14e7b"
        )
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")
        await fixture.model.reloadTokens()
        XCTAssertEqual(fixture.model.tokens.count, 1)
        XCTAssertTrue(fixture.model.isCurrentClient(fixture.model.tokens[0]))

        await fixture.model.revoke(fixture.model.tokens[0])

        XCTAssertEqual(fixture.model.tokens, [])
        let client = try await fixture.credentialStore.readToken(for: fixture.host.endpoint)
        XCTAssertNil(client)
        let admin = try await fixture.credentialStore.readToken(
            for: fixture.host.endpoint, role: .administrator
        )
        XCTAssertEqual(admin, "boot-admin")
    }

    func testRevokingAnotherClientPreservesThisEndpointsCredential() async throws {
        let list = #"[{"id":"other-token-id","label":"Other phone","created_at":"2026-07-17T20:00:00Z","last_seen_at":null,"bootstrap":false}]"#
        let fixture = try await makeFixture(
            results: [
                AdminScriptedHTTP.ok("{}"),
                AdminScriptedHTTP.ok(list),
                AdminScriptedHTTP.ok(#"{"revoked":"other-token-id"}"#),
                AdminScriptedHTTP.ok("[]"),
            ],
            hostTokenID: "7dd64d22b0c14e7b"
        )
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")
        await fixture.model.reloadTokens()
        XCTAssertFalse(fixture.model.isCurrentClient(fixture.model.tokens[0]))

        await fixture.model.revoke(fixture.model.tokens[0])

        let client = try await fixture.credentialStore.readToken(for: fixture.host.endpoint)
        XCTAssertEqual(client, "wlt_client")
    }

    func testBootstrapRowIsNeverRevocableFromTheModel() async throws {
        let list = #"[{"id":"bootstrap","label":"Bootstrap administrator","created_at":"2026-07-17T19:00:00Z","last_seen_at":null,"bootstrap":true}]"#
        let fixture = try await makeFixture(results: [
            AdminScriptedHTTP.ok("{}"),
            AdminScriptedHTTP.ok(list),
        ])
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")
        await fixture.model.reloadTokens()

        await fixture.model.revoke(fixture.model.tokens[0])

        XCTAssertEqual(fixture.http.calls.map(\.method), ["GET", "GET"])  // no DELETE issued
        XCTAssertEqual(fixture.model.tokens.count, 1)
    }
```

Extend `makeFixture` with `hostTokenID: String? = nil` and pass it into `RouterHostValidator.validate(..., tokenID: hostTokenID)`.

- [ ] **Step 6: Run to verify RED**

Run the Task 7 Step 6 command. Expected: FAIL to compile — missing token members on the model.

- [ ] **Step 7: Implement model tokens state and the view**

Model additions:

```swift
    private(set) var tokens: [RouterTokenMetadata] = []
    private(set) var tokensError: String?

    func reloadTokens() async {
        tokensError = await performAdmin { client in
            try await client.tokens()
        } apply: { [weak self] list in
            self?.tokens = list
        }
    }

    func isCurrentClient(_ token: RouterTokenMetadata) -> Bool {
        guard let currentID = host?.tokenID else { return false }
        return currentID == token.id
    }

    func revoke(_ token: RouterTokenMetadata) async {
        guard !token.bootstrap else { return }
        let wasCurrentClient = isCurrentClient(token)
        let revokedHost = host
        let connections = self.connections
        tokensError = await performAdmin { client in
            try await client.revokeToken(id: token.id)
            // Server-side revocation is already durable; dropping our own
            // now-dead client credential is correct even if the session ends
            // while this is in flight.
            if wasCurrentClient, let revokedHost {
                try? await connections.returnToEnrollment(revokedHost)
            }
            return try await client.tokens()
        } apply: { [weak self] (list: [RouterTokenMetadata]) in
            self?.tokens = list
        }
    }
```

In `end()`, also clear `tokens = []` and `tokensError = nil`.

Create `RouterTokensView.swift`:

```swift
import SwiftUI
import WattlineNetwork

struct RouterTokensView: View {
    let model: RouterAdministrationModel
    @State private var tokenPendingRevocation: RouterTokenMetadata?

    var body: some View {
        Group {
            ForEach(model.tokens) { token in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(token.label)
                        if token.bootstrap {
                            Text("Bootstrap")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                        if model.isCurrentClient(token) {
                            Text("This device")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.tint.opacity(0.2), in: Capsule())
                        }
                    }
                    Text(token.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text("Created \(token.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .swipeActions {
                    if !token.bootstrap {
                        Button("Revoke", role: .destructive) {
                            tokenPendingRevocation = token
                        }
                    }
                }
            }
            if let message = model.tokensError {
                Text(message).foregroundStyle(.orange)
            }
        }
        .task { await model.reloadTokens() }
        .confirmationDialog(
            "Revoke this client?",
            isPresented: Binding(
                get: { tokenPendingRevocation != nil },
                set: { if !$0 { tokenPendingRevocation = nil } }
            ),
            presenting: tokenPendingRevocation
        ) { token in
            Button("Revoke \(token.label)", role: .destructive) {
                Task { await model.revoke(token) }
            }
        } message: { token in
            if model.isCurrentClient(token) {
                Text("This is this device's own token. Live updates stop immediately and this router returns to setup.")
            } else {
                Text("Revocation is immediate and closes that client's live updates.")
            }
        }
    }
}
```

In `RouterAdministrationView.swift`, add after the client-enrollment section:

```swift
                if presentation.visibleSections.contains(.apiClients) {
                    Section("API clients") {
                        RouterTokensView(model: admin)
                    }
                }
```

- [ ] **Step 8: Run GREEN**

```bash
swift test --package-path peakdo/apple/WattlineNetwork
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination "platform=iOS Simulator,name=${WATTLINE_SIMULATOR_NAME}" CODE_SIGNING_ALLOWED=NO
```

Expected: PASS, zero failures.

- [ ] **Step 9: Commit**

```bash
git add peakdo/apple/WattlineNetwork peakdo/apple/Wattline/Wattline peakdo/apple/Wattline/WattlineTests
git commit -m "feat: manage router client tokens"
```

---

## Task 11: Milestone 2 verification and handoff

**Files:**
- Modify only if a regression is found: files from Tasks 6–10.

**Interfaces:**
- Produces: independently usable administration foundation (unlock, history, pairing-mode, tokens) with Milestones 3–5 untouched.

- [ ] **Step 1: Run package suites**

```bash
swift test --package-path peakdo/apple/WattlineCore
swift test --package-path peakdo/apple/WattlineUI
swift test --package-path peakdo/apple/WattlineNetwork
```

Expected: zero failures. Baselines grow from 156/27/109 only by this milestone's new tests (Core unchanged at 156).

- [ ] **Step 2: Run executed iOS suites and builds**

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination "platform=iOS Simulator,name=${WATTLINE_SIMULATOR_NAME}" CODE_SIGNING_ALLOWED=NO
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineWidgets -destination "platform=iOS Simulator,name=${WATTLINE_SIMULATOR_NAME}" CODE_SIGNING_ALLOWED=NO
xcodebuild build -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

Expected: zero failures; generic build succeeds.

- [ ] **Step 3: Run boundary, secret, and scope audits**

```bash
rg -n 'URLSession|NWBrowser|NWConnection|import Network|import Security' \
  peakdo/apple/WattlineCore/Sources peakdo/apple/WattlineUI/Sources
rg -n 'import WattlineNetwork' peakdo/apple/WattlineUI/Sources
rg -n '\b(print|debugPrint|dump)\s*\(|\b(Logger|os_log|NSLog)\b' \
  peakdo/apple/WattlineNetwork/Sources peakdo/apple/Wattline/Wattline
rg -n 'UserDefaults.*(token|pin)|(token|pin).*UserDefaults' -i peakdo/apple/Wattline/Wattline peakdo/apple/WattlineNetwork/Sources
rg -n '/device/action|/device/usbc-limit|/device/bypass-threshold|/device/schedules' peakdo/apple
git diff --check
git status --short
```

Expected: every search returns no matches (the `UserDefaults` search may match only `RouterHostMetadata` persistence lines that carry no secret — inspect any hit); clean diff check; clean tree after commits.

- [ ] **Step 4: Confirm milestone scope was not exceeded**

```bash
rg -n 'api/v1/(settings|tls|pairing/|rules|device/advanced|device/ota|device/clock)' \
  peakdo/apple/WattlineNetwork/Sources peakdo/apple/Wattline/Wattline
```

Expected: the only match is the single `GET /api/v1/settings` verification probe in `RouterAdministrationClient.verifyAdministrator`. No settings editor, TLS, router-BLE pairing, advanced, or rules code exists.

- [ ] **Step 5: Stop for review**

Report commits, exact per-suite pass counts, RED→GREEN evidence per task, and the simulator used. List external real-router checks that unit tests cannot prove: administrator verification against a live `wattlined`, pairing-mode open/QR scan by a second device, PIN TTL expiry, revoked-token SSE termination, and revocation of this device's own token returning it to enrollment. **Do not begin Milestone 3 without approval.**

---

## Self-review checklist

- Design §2.1 (roles, unsuffixed client account, admin suffix, GET /settings verification, no promotion) → Tasks 6–7. §2.3 (actor, generation, cancellation mapping) → Task 7. §5 (history exactness, laziness, honest fetch stamp) → Task 8. §6.1 (pairing-mode routes, secret lifetime, QR gating, share) → Task 9. §6.2 (metadata-only tokens, local bootstrap rejection, relist, self-revocation cleanup) → Task 10. §11 (admin-401 isolation, no 403 token replacement, redaction) → Tasks 7/9/10.
- Every later-task consumer (`send`, `performAdmin`, `ScriptedRouterHTTPClient`, `AdminScriptedHTTP`, `RouterCredentialRole`, `tokenID`) is introduced in an earlier task's Interfaces block.
- No placeholder text; every code step contains the code.
- Type names are consistent: `RouterAdministrationClient`, `RouterAdministrationError`, `RouterAdministrationModel`, `RouterAdministrationPresentation`, `RouterPairingMode`, `RouterTokenMetadata`, `RouterHistorySample`, `RouterHistoryClient`, `RouterHistoryPoint`, `RouterHistoryPowerPoint`, `RouterHistoryPresentation`.
- Milestone gates: Task 11 stops for review before Milestone 3.
