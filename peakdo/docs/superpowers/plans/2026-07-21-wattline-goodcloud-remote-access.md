# Wattline GoodCloud Remote Access Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add full off-LAN Wattline REST and SSE access through GoodCloud rtty while preserving LAN/Bonjour preference, Wattline bearer authentication, BLE ownership, and existing models.

**Architecture:** Extend GoodCloudKit with ordinary and streaming relay requests, then pin that exact upstream commit in `WattlineNetwork`. A shared actor provisions short-lived relay sessions for remote HTTP/SSE adapters, while a LAN-first route coordinator chooses existing direct clients before remote fallback. Account/device association is isolated behind testable services and shared iOS/macOS UI state.

**Tech Stack:** Swift 5.9/6, Swift Package Manager, Foundation `URLSession`, Swift concurrency/Observation, SwiftUI, XCTest, Keychain, UserDefaults, Xcode iOS/macOS targets.

## Global Constraints

- Base Wattline work on `codex/wattline-goodcloud`, created from committed `codex/wattline-phase-2` at `ec8425f2`; do not include or alter the dirty Phase-2 worktree.
- Base GoodCloudKit work on `main` at `20690c9`, create `codex/relay-http-request-stream`, push it, and pin Wattline to the resulting exact commit SHA.
- Target `wattlined` on port `8377`; canonical routes remain `/api/v1/...`.
- Pass Wattline's `Authorization: Bearer <token>` independently and verbatim through the relay.
- Preserve full SSE; do not substitute polling.
- LAN/Bonjour is preferred. Only reachability/transport failures may fall back to remote; TLS, authentication, API, decoding, and cancellation failures may not.
- Automatically replay at most one expired-relay GET/connect/SSE open. Never automatically replay POST, PUT, or DELETE.
- GoodCloud API code `-1010` means the account session expired and requires login. Wattlined `401/403` remains a Wattline credential error.
- GoodCloud FE tokens remain in GoodCloudKit Keychain storage; Wattline bearer tokens remain in the existing Wattline Keychain store; UserDefaults stores only non-secret association metadata.
- Do not log passwords, tokens, cookies, authorization headers, bodies, relay URLs, or unredacted GoodCloud server text.
- Do not change `wattlined`, `API.md`, BLE, the one-BLE-owner invariant, or existing LAN/Bonjour client implementations.
- All production behavior is test-first: add one focused test, run it and observe the expected failure, implement minimally, then rerun focused and package suites.
- No live-hardware success claim. Record the deferred replacement-router checks for `/api/v1/status`, a mutation, and `/api/v1/events`.

---

### Task 1: GoodCloudKit ordinary relay requests

**Repository:** `/Users/keith/src/goodcloudkit` (create isolated worktree `/Users/keith/.codex/worktrees/goodcloud-relay-http` on `codex/relay-http-request-stream` from `20690c9`)

**Files:**
- Modify: `Tests/GoodCloudKitTests/RelayHTTPClientTests.swift`
- Modify: `Sources/GoodCloudKit/RelayHTTPClient.swift`

**Interfaces:**
- Consumes: `RemoteAccessSession`, existing relay URL encoding, relay cookie installation, and GoodCloud-only redirect policy.
- Produces: `RelayHTTPClient.request(method:path:headers:body:)` and `get/post/put/delete` convenience methods with exact signatures from the design spec.

- [ ] **Step 1: Create the isolated GoodCloudKit branch and verify its baseline**

```bash
git -C /Users/keith/src/goodcloudkit worktree add \
  /Users/keith/.codex/worktrees/goodcloud-relay-http \
  -b codex/relay-http-request-stream 20690c9
swift test --package-path /Users/keith/.codex/worktrees/goodcloud-relay-http
```

Expected: 39 tests pass with zero failures.

- [ ] **Step 2: Write failing pass-through tests**

Add focused tests that capture the outgoing `URLRequest` and assert exact values:

```swift
func test_request_passesMethodHeadersAndBodyVerbatim() async throws {
    let body = Data(#"{"action":"dc_off"}"#.utf8)
    var captured: URLRequest?
    StubURLProtocol.handler = { request in
        captured = request
        return .init(status: 200, data: Data(), headers: [:])
    }
    let client = RelayHTTPClient(session: session(
        relayBase: "https://rttys-ssh-cloud-us.goodcloud.xyz/web/demo01/http/127.0.0.1%3A8377%2F",
        token: "FE-TOK"
    ), urlSession: StubURLProtocol.session())

    _ = try await client.request(
        method: "POST",
        path: "/api/v1/device/action",
        headers: [
            "Authorization": "Bearer wattline-token",
            "Content-Type": "application/json",
        ],
        body: body
    )

    XCTAssertEqual(captured?.httpMethod, "POST")
    XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer wattline-token")
    XCTAssertEqual(captured?.value(forHTTPHeaderField: "Content-Type"), "application/json")
    XCTAssertEqual(captured?.httpBody, body)
    XCTAssertEqual(captured?.url?.absoluteString,
        "https://rttys-ssh-cloud-us.goodcloud.xyz/web/demo01/http/127.0.0.1%3A8377%2Fapi%2Fv1%2Fdevice%2Faction")
}

func test_convenienceMethodsDelegateWithoutInventingHeadersOrBody() async throws {
    var requests: [URLRequest] = []
    StubURLProtocol.handler = { request in
        requests.append(request)
        return .init(status: 200, data: Data(), headers: [:])
    }
    let client = RelayHTTPClient(session: session(
        relayBase: "https://rttys-ssh-cloud-us.goodcloud.xyz/web/demo01/http/127.0.0.1%3A8377%2F",
        token: "FE-TOK"
    ), urlSession: StubURLProtocol.session())
    _ = try await client.get("api/v1/status", headers: ["Accept": "application/json"])
    _ = try await client.post("api/v1/rules", body: Data("{}".utf8))
    _ = try await client.put("api/v1/rules/night", body: Data("{}".utf8))
    _ = try await client.delete("api/v1/rules/night")

    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "PUT", "DELETE"])
    XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Accept"), "application/json")
    XCTAssertNil(requests[0].httpBody)
    XCTAssertEqual(requests[1].httpBody, Data("{}".utf8))
    XCTAssertEqual(requests[2].httpBody, Data("{}".utf8))
    XCTAssertNil(requests[3].httpBody)
}
```

- [ ] **Step 3: Run the focused tests and confirm RED**

```bash
swift test --package-path /Users/keith/.codex/worktrees/goodcloud-relay-http \
  --filter RelayHTTPClientTests
```

Expected: compilation fails because `request`, header-aware `get`, `post`, `put`, and `delete` do not exist.

- [ ] **Step 4: Implement the minimal shared request path**

Refactor `get` to delegate to this implementation; keep URL building, cookie storage, and `RedirectPolicy` in one place:

```swift
public func request(
    method: String,
    path: String,
    headers: [String: String] = [:],
    body: Data? = nil
) async throws -> (Data, HTTPURLResponse) {
    guard let fe = session.feToken, !fe.isEmpty else {
        throw GoodCloudError.relayUnavailable
    }
    if let storage = urlSession.configuration.httpCookieStorage {
        setRelayCookies(into: storage)
    }
    var request = URLRequest(url: try url(forTargetPath: normalized(path)))
    request.httpMethod = method
    request.httpShouldHandleCookies = true
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    request.httpBody = body
    do {
        let (data, response) = try await urlSession.data(for: request, delegate: RedirectPolicy())
        guard let http = response as? HTTPURLResponse else {
            throw GoodCloudError.relayUnavailable
        }
        return (data, http)
    } catch let error as GoodCloudError {
        throw error
    } catch let error as URLError {
        throw GoodCloudError.transport(error)
    }
}

public func get(_ path: String, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
    try await request(method: "GET", path: path, headers: headers)
}

public func post(_ path: String, headers: [String: String] = [:], body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
    try await request(method: "POST", path: path, headers: headers, body: body)
}

public func put(_ path: String, headers: [String: String] = [:], body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
    try await request(method: "PUT", path: path, headers: headers, body: body)
}

public func delete(_ path: String, headers: [String: String] = [:], body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
    try await request(method: "DELETE", path: path, headers: headers, body: body)
}

private func normalized(_ path: String) -> String {
    String(path.drop(while: { $0 == "/" }))
}
```

- [ ] **Step 5: Verify GREEN and commit**

```bash
swift test --package-path /Users/keith/.codex/worktrees/goodcloud-relay-http \
  --filter RelayHTTPClientTests
swift test --package-path /Users/keith/.codex/worktrees/goodcloud-relay-http
git -C /Users/keith/.codex/worktrees/goodcloud-relay-http add \
  Sources/GoodCloudKit/RelayHTTPClient.swift \
  Tests/GoodCloudKitTests/RelayHTTPClientTests.swift
git -C /Users/keith/.codex/worktrees/goodcloud-relay-http commit \
  -m "feat: support arbitrary relay HTTP requests"
```

Expected: focused and full GoodCloudKit suites pass; commit succeeds.

---

### Task 2: GoodCloudKit streaming and relay-expiry detection

**Repository:** `/Users/keith/.codex/worktrees/goodcloud-relay-http`

**Files:**
- Modify: `Tests/GoodCloudKitTests/StubURLProtocol.swift`
- Modify: `Tests/GoodCloudKitTests/RelayHTTPClientTests.swift`
- Modify: `Sources/GoodCloudKit/RelayHTTPClient.swift`

**Interfaces:**
- Consumes: Task 1 shared request construction/cookies/redirect policy.
- Produces: public `RelayHTTPStreamEvent`, `RelayHTTPClient.stream(method:path:headers:body:)`, typed `.sessionExpired`, cancellation propagation, and the pushed GoodCloud commit SHA consumed by Task 3.

- [ ] **Step 1: Add a controllable streaming StubURLProtocol and failing tests**

Extend `Stub` without changing existing call sites:

```swift
struct Stub {
    let status: Int
    let data: Data
    let headers: [String: String]
    let chunks: [Data]
    let finish: Bool
    let responseURL: URL?

    init(status: Int, data: Data, headers: [String: String], chunks: [Data] = [],
         finish: Bool = true, responseURL: URL? = nil) {
        self.status = status
        self.data = data
        self.headers = headers
        self.chunks = chunks
        self.finish = finish
        self.responseURL = responseURL
    }
}
```

In `startLoading`, send `data` when `chunks` is empty, otherwise send each chunk separately; call `urlProtocolDidFinishLoading` only when `finish` is true. Record `stopLoading` via a locked static flag.

Add tests:

```swift
func test_stream_emitsResponseThenIncrementalBodyChunks() async throws {
    StubURLProtocol.handler = { request in
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer wattline-token")
        return .init(status: 200, data: Data(), headers: ["Content-Type": "text/event-stream"],
                     chunks: [Data("data: one\n\n".utf8), Data("data: two\n\n".utf8)],
                     finish: false)
    }
    let client = makeClient()
    let expectedBody = Data("data: one\n\ndata: two\n\n".utf8)
    let task = Task { () throws -> (HTTPURLResponse, Data) in
        var iterator = client.stream(
            method: "GET", path: "/api/v1/events",
            headers: ["Authorization": "Bearer wattline-token", "Accept": "text/event-stream"]
        ).makeAsyncIterator()
        guard case .response(let response) = try await iterator.next() else {
            XCTFail("response must be first")
            throw GoodCloudError.relayUnavailable
        }
        var body = Data()
        while body.count < expectedBody.count, let event = try await iterator.next() {
            if case .data(let chunk) = event { body.append(chunk) }
        }
        return (response, body)
    }
    let (response, body) = try await task.value
    task.cancel()

    XCTAssertEqual(response.statusCode, 200)
    XCTAssertEqual(body, expectedBody)
}

func test_requestAndStreamMapRelayErrorPageToSessionExpired() async {
    StubURLProtocol.handler = { request in
        .init(status: 404, data: Data(), headers: [:],
              responseURL: URL(string: "https://rttys-web-cloud-us.goodcloud.xyz/gl-rtty/error.html"))
    }
    await assertThrowsSessionExpired { _ = try await self.makeClient().get("api/v1/status") }
    await assertStreamThrowsSessionExpired(self.makeClient().stream(method: "GET", path: "api/v1/events"))
}
```

Use test-only computed accessors to compare enum payloads; do not add test-only production APIs.

- [ ] **Step 2: Run focused tests and confirm RED**

```bash
swift test --package-path /Users/keith/.codex/worktrees/goodcloud-relay-http \
  --filter RelayHTTPClientTests
```

Expected: compilation fails because `RelayHTTPStreamEvent` and `stream` do not exist and ordinary requests do not map expiry.

- [ ] **Step 3: Implement delegate-backed streaming and shared expiry classification**

Add the public event and method using `URLSession.bytes(for:delegate:)`, which preserves the existing per-task redirect delegate and yields without buffering to EOF:

```swift
public enum RelayHTTPStreamEvent: @unchecked Sendable {
    case response(HTTPURLResponse)
    case data(Data)
}

public func stream(
    method: String,
    path: String,
    headers: [String: String] = [:],
    body: Data? = nil
) -> AsyncThrowingStream<RelayHTTPStreamEvent, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                let request = try makeRequest(method: method, path: path, headers: headers, body: body)
                let (bytes, response) = try await urlSession.bytes(for: request, delegate: RedirectPolicy())
                guard let http = response as? HTTPURLResponse else {
                    throw GoodCloudError.relayUnavailable
                }
                guard !Self.isExpiredRelay(response: http) else {
                    throw GoodCloudError.sessionExpired
                }
                continuation.yield(.response(http))
                for try await byte in bytes {
                    try Task.checkCancellation()
                    continuation.yield(.data(Data([byte])))
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch let error as URLError where error.code == .cancelled {
                continuation.finish()
            } catch let error as GoodCloudError {
                continuation.finish(throwing: error)
            } catch let error as URLError {
                continuation.finish(throwing: GoodCloudError.transport(error))
            } catch {
                continuation.finish(throwing: GoodCloudError.relayUnavailable)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
```

Refactor ordinary requests and streaming to the same `makeRequest` helper. Extend the stub response with an optional `responseURL` so expiry is tested from the final relay URL rather than by treating every target `404` as relay expiry. Add:

```swift
private static func isExpiredRelay(response: HTTPURLResponse) -> Bool {
    response.url?.path.hasSuffix("/gl-rtty/error.html") == true
}
```

Ordinary request checks the final response before returning. Streaming checks each response before emitting it.

- [ ] **Step 4: Verify focused/full suites, commit, and push**

```bash
swift test --package-path /Users/keith/.codex/worktrees/goodcloud-relay-http \
  --filter RelayHTTPClientTests
swift test --package-path /Users/keith/.codex/worktrees/goodcloud-relay-http
git -C /Users/keith/.codex/worktrees/goodcloud-relay-http add \
  Sources/GoodCloudKit/RelayHTTPClient.swift \
  Tests/GoodCloudKitTests/RelayHTTPClientTests.swift \
  Tests/GoodCloudKitTests/StubURLProtocol.swift
git -C /Users/keith/.codex/worktrees/goodcloud-relay-http commit \
  -m "feat: stream HTTP through relay"
git -C /Users/keith/.codex/worktrees/goodcloud-relay-http push \
  -u origin codex/relay-http-request-stream
git -C /Users/keith/.codex/worktrees/goodcloud-relay-http rev-parse HEAD
```

Expected: full suite passes, push succeeds, and the final command prints the immutable revision to use literally in Task 3.

---

### Task 3: Pin GoodCloudKit and add account/association services

**Repository:** `/Users/keith/.codex/worktrees/wattline-goodcloud`

**Files:**
- Modify: `peakdo/apple/WattlineNetwork/Package.swift`
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/GoodCloudAccountService.swift`
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/GoodCloudAssociationStore.swift`
- Create: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/GoodCloudAccountServiceTests.swift`
- Create: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/GoodCloudAssociationStoreTests.swift`

**Interfaces:**
- Consumes: exact GoodCloud commit printed by Task 2; `GoodCloudAuth`, `SignedAPIClient`, and `GoodCloudDevice`.
- Produces: `GoodCloudAccountServing`, `GoodCloudRelayProvisioning`, `GoodCloudAccountService`, `GoodCloudDeviceSummary`, `GoodCloudSessionState`, `GoodCloudAssociation`, and `GoodCloudAssociationStore`.

- [ ] **Step 1: Pin the immutable package revision**

Read Task 2's exact SHA and let SwiftPM write that immutable literal into the manifest:

```bash
goodcloud_revision=$(git -C /Users/keith/.codex/worktrees/goodcloud-relay-http rev-parse HEAD)
test "${#goodcloud_revision}" -eq 40
cd /Users/keith/.codex/worktrees/wattline-goodcloud/peakdo/apple/WattlineNetwork
swift package add-dependency https://github.com/keithah/goodcloudkit \
  --revision "$goodcloud_revision"
```

Use `apply_patch` to add `.product(name: "GoodCloudKit", package: "goodcloudkit")` to the `WattlineNetwork` target and test target dependencies. Verify `Package.swift` contains the 40-character literal printed by `rev-parse`, with no branch or version requirement.

- [ ] **Step 2: Write failing account-state tests**

Test a protocol-backed service rather than live auth:

```swift
func test_validateStoredSessionLoadsDevices() async throws {
    let client = FakeGoodCloudAccountClient(tokenPresent: true, devices: [.fixture])
    let service = GoodCloudAccountService(client: client)
    let state = await service.validateStoredSession()
    XCTAssertEqual(state, .authenticated([.fixture]))
}

func test_minus1010ClearsSessionAndRequiresLoginWithoutServerMessage() async {
    let client = FakeGoodCloudAccountClient(
        tokenPresent: true,
        error: GoodCloudError.api(code: -1010, message: "token=secret server text")
    )
    let service = GoodCloudAccountService(client: client)
    XCTAssertEqual(await service.refreshDevices(), .requiresLogin)
    XCTAssertEqual(await client.logoutCount, 1)
    XCTAssertFalse(String(describing: await service.state).contains("secret"))
}
```

- [ ] **Step 3: Write failing association tests**

```swift
func test_exactNormalizedMACIsSuggestedButNotPersistedUntilSelected() async throws {
    let backend = MemoryAssociationBackend()
    let store = GoodCloudAssociationStore(backend: backend)
    let devices = [GoodCloudDeviceSummary(id: "42", name: "X3000", mac: "AA-BB-CC-DD-EE-FF",
        ddns: "x3000", model: "GL-X3000", isOnline: true)]
    XCTAssertEqual(store.suggestedDevice(forRouterMAC: "aa:bb:cc:dd:ee:ff", devices: devices)?.id, "42")
    XCTAssertNil(await store.association(forHostID: hostID))
    try await store.save(.init(hostID: hostID, routerMAC: "AA:BB:CC:DD:EE:FF", device: devices[0]))
    XCTAssertEqual(await store.association(forHostID: hostID)?.goodCloudDeviceID, "42")
}

func test_removingAssociationDoesNotInvokeRouterCredentialStorage() async throws {
    let backend = MemoryAssociationBackend()
    let store = GoodCloudAssociationStore(backend: backend)
    try await store.save(.fixture)
    try await store.remove(hostID: GoodCloudAssociation.fixture.hostID)
    XCTAssertNil(await store.association(forHostID: GoodCloudAssociation.fixture.hostID))
}
```

- [ ] **Step 4: Run focused tests and confirm RED**

```bash
cd /Users/keith/.codex/worktrees/wattline-goodcloud/peakdo/apple/WattlineNetwork
swift test --filter GoodCloudAccountServiceTests
swift test --filter GoodCloudAssociationStoreTests
```

Expected: compilation fails because the service/store types do not exist.

- [ ] **Step 5: Implement minimal redacted account and Codable association services**

Use these public values and protocol boundaries:

```swift
public struct GoodCloudDeviceSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let mac: String
    public let ddns: String?
    public let model: String
    public let isOnline: Bool
}

public enum GoodCloudSessionState: Equatable, Sendable {
    case loggedOut
    case loading
    case authenticated([GoodCloudDeviceSummary])
    case requiresLogin
    case failed(String)
}

public protocol GoodCloudAccountClient: Sendable {
    func hasStoredToken() async -> Bool
    func login(email: String, password: String) async throws
    func devices() async throws -> [GoodCloudDeviceSummary]
    func logout() async
}

public protocol GoodCloudAccountServing: Sendable {
    func validateStoredSession() async -> GoodCloudSessionState
    func login(email: String, password: String) async -> GoodCloudSessionState
    func refreshDevices() async -> GoodCloudSessionState
    func logout() async
}

public protocol GoodCloudRelayProvisioning: Sendable {
    func remoteAccess(deviceID: String, port: Int) async throws -> RemoteAccessSession
}

public struct GoodCloudAssociation: Codable, Equatable, Sendable {
    public let hostID: UUID
    public let routerMAC: String
    public let goodCloudDeviceID: String
    public let name: String
    public let mac: String
    public let ddns: String?
    public let model: String
    public let isOnline: Bool
}
```

`GoodCloudAccountService` is an actor conforming to `GoodCloudAccountServing` and `GoodCloudRelayProvisioning`, with a `state` property and `validateStoredSession`, `login`, `refreshDevices`, `logout`, and `remoteAccess(deviceID:port:)`. Its production initializer owns one `GoodCloudAuth`; each operation constructs `SignedAPIClient(tokens: PasswordTokenProvider(auth: auth))`, keeping authentication and relay provisioning on the same Keychain session. It maps only `GoodCloudError.api(code: -1010, ...)` to `.requiresLogin`, calls logout, and uses fixed redacted copy for all other failures. `GoodCloudAssociationStore` is an actor over a synchronous key-value backend, encodes an array under `wattline.goodCloudAssociations`, normalizes MAC through `DeviceIdentityDeduplicator`, and mutates only its own key.

- [ ] **Step 6: Verify and commit**

```bash
swift test --filter GoodCloudAccountServiceTests
swift test --filter GoodCloudAssociationStoreTests
swift test
git -C /Users/keith/.codex/worktrees/wattline-goodcloud add \
  peakdo/apple/WattlineNetwork/Package.swift \
  peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/GoodCloudAccountService.swift \
  peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/GoodCloudAssociationStore.swift \
  peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/GoodCloudAccountServiceTests.swift \
  peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/GoodCloudAssociationStoreTests.swift
git -C /Users/keith/.codex/worktrees/wattline-goodcloud commit \
  -m "feat: add GoodCloud account and router association"
```

Expected: focused tests and all WattlineNetwork tests pass.

---

### Task 4: Remote relay coordinator plus REST and SSE adapters

**Files:**
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/GoodCloudRelayCoordinator.swift`
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RemoteRouterHTTPClient.swift`
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RemoteRouterEventStream.swift`
- Create: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/GoodCloudRelayCoordinatorTests.swift`
- Create: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RemoteRouterTransportTests.swift`

**Interfaces:**
- Consumes: Task 2 `RelayHTTPClient.request/stream`; Task 3 selected device ID; existing `RouterHTTPClient`, `RouterEventStream`, `SSEFrameParser`, and `RouterHTTPErrorMapper`.
- Produces: `GoodCloudRelayProvisioning`, `GoodCloudRelayCoordinator`, `RemoteRouterHTTPClient`, and `RemoteRouterEventStream` fixed to port `8377`.

- [ ] **Step 1: Write failing coordinator tests for coalescing and retry safety**

```swift
func test_concurrentRESTAndSSELeaseShareOneProvisioning() async throws {
    let provisioner = SuspendedRelayProvisioner()
    let coordinator = GoodCloudRelayCoordinator(deviceID: "42", provisioner: provisioner)
    async let first = coordinator.session()
    async let second = coordinator.session()
    await provisioner.waitUntilCalled()
    await provisioner.resume(with: .fixture)
    _ = try await (first, second)
    XCTAssertEqual(await provisioner.calls, [.init(deviceID: "42", port: 8377)])
}

func test_expiredGETReprovisionsOnceButMutationDoesNotReplay() async throws {
    let relay = ScriptedRelay(results: [.failure(GoodCloudError.sessionExpired), .success(.ok)])
    let coordinator = makeCoordinator(relay: relay)
    _ = try await coordinator.request(method: "GET", path: "/api/v1/status", headers: [:], body: nil)
    XCTAssertEqual(await relay.requestCount, 2)

    let mutationRelay = ScriptedRelay(results: [.failure(GoodCloudError.sessionExpired)])
    let mutationCoordinator = makeCoordinator(relay: mutationRelay)
    await XCTAssertThrowsErrorAsync {
        _ = try await mutationCoordinator.request(method: "POST", path: "/api/v1/device/action",
            headers: [:], body: Data("{}".utf8))
    }
    XCTAssertEqual(await mutationRelay.requestCount, 1)
}
```

- [ ] **Step 2: Write failing REST and SSE adapter tests**

```swift
func test_remoteHTTPPassesWattlineAuthorizationAndJSONBody() async throws {
    let coordinator = RecordingRemoteCoordinator(response: .ok)
    let client = RemoteRouterHTTPClient(coordinator: coordinator)
    let body = Data(#"{"action":"dc_off"}"#.utf8)
    _ = try await client.request("POST", "/api/v1/device/action", body: body, token: "wattline-token")
    XCTAssertEqual(await coordinator.lastRequest?.headers["Authorization"], "Bearer wattline-token")
    XCTAssertEqual(await coordinator.lastRequest?.headers["Content-Type"], "application/json")
    XCTAssertEqual(await coordinator.lastRequest?.body, body)
}

func test_remoteSSEParsesFramesAndForwardsBearer() async throws {
    let coordinator = RecordingRemoteCoordinator(streamEvents: [
        .response(.ok),
        .data(Data("data: {\"type\":\"snapshot\"}\n\n".utf8)),
    ])
    let stream = RemoteRouterEventStream(coordinator: coordinator)
    var iterator = stream.events(path: "/api/v1/events", token: "wattline-token").makeAsyncIterator()
    XCTAssertEqual(try await iterator.next(), Data(#"{"type":"snapshot"}"#.utf8))
    XCTAssertEqual(await coordinator.lastStream?.headers["Authorization"], "Bearer wattline-token")
    XCTAssertEqual(await coordinator.lastStream?.headers["Accept"], "text/event-stream")
}
```

- [ ] **Step 3: Run focused tests and confirm RED**

```bash
cd /Users/keith/.codex/worktrees/wattline-goodcloud/peakdo/apple/WattlineNetwork
swift test --filter GoodCloudRelayCoordinatorTests
swift test --filter RemoteRouterTransportTests
```

Expected: compilation fails because coordinator and adapters do not exist.

- [ ] **Step 4: Implement the coordinator and adapters**

Use Task 3's `GoodCloudRelayProvisioning` and define the injectable relay client boundary:

```swift
protocol RemoteRelayClient: Sendable {
    func request(method: String, path: String, headers: [String: String], body: Data?) async throws
        -> (Data, HTTPURLResponse)
    func stream(method: String, path: String, headers: [String: String], body: Data?)
        -> AsyncThrowingStream<RelayHTTPStreamEvent, Error>
}
```

`GoodCloudRelayCoordinator` stores `currentSession`, one `Task<RemoteAccessSession, Error>?`, and factories for provisioning/relay clients. `session()` coalesces the task. `request` retries once only when `method == "GET"` and the thrown error is `.sessionExpired`; mutation expiry invalidates then rethrows. `stream` invalidates and performs one fresh open when expiry happens before/while consuming the stream. Normalize `-1010` into `NetworkError.goodCloudSessionExpired` using fixed, secret-free enum cases.

`RemoteRouterHTTPClient` constructs authorization/content headers and calls `RouterHTTPErrorMapper` for non-2xx responses exactly like `HTTPClient`. `RemoteRouterEventStream` validates the first `.response`, parses `.data` chunks line-by-line with `SSEFrameParser`, preserves truncated-frame behavior, and cancels its relay stream when terminated.

- [ ] **Step 5: Verify and commit**

```bash
swift test --filter GoodCloudRelayCoordinatorTests
swift test --filter RemoteRouterTransportTests
swift test
git -C /Users/keith/.codex/worktrees/wattline-goodcloud add \
  peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/GoodCloudRelayCoordinator.swift \
  peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RemoteRouterHTTPClient.swift \
  peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RemoteRouterEventStream.swift \
  peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/GoodCloudRelayCoordinatorTests.swift \
  peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RemoteRouterTransportTests.swift
git -C /Users/keith/.codex/worktrees/wattline-goodcloud commit \
  -m "feat: tunnel Wattline REST and SSE through GoodCloud"
```

Expected: focused tests and all WattlineNetwork tests pass.

---

### Task 5: LAN-first route policy and production transport wiring

**Files:**
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/PreferredRouterRoute.swift`
- Create: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/PreferredRouterRouteTests.swift`
- Modify: `peakdo/apple/WattlineShared/RouterConnectionModel.swift`
- Modify: `peakdo/apple/Wattline/WattlineTests/RouterAppWiringTests.swift`
- Modify: `peakdo/apple/Wattline/WattlineTests/RouterDiscoveryLifecycleTests.swift`

**Interfaces:**
- Consumes: direct LAN `HTTPClient`/`SSEClient`, Task 4 remote adapters, saved-host association lookup.
- Produces: shared `PreferredRouterRoute`, `PreferredRouterHTTPClient`, `PreferredRouterEventStream`, observable `RouterRouteKind.local/remote`, and production construction without changing `RouterTransport`.

- [ ] **Step 1: Write failing route classification and selection tests**

```swift
func test_LANSuccessNeverConstructsRemote() async throws {
    let lan = ScriptedRouterHTTPClient(results: [.ok(#"{"ok":true}"#)])
    let remote = CountingRouterHTTPClient()
    let route = PreferredRouterRoute(lanHTTP: lan, lanEvents: EmptyEventStream(),
        remoteHTTP: remote, remoteEvents: EmptyEventStream())
    _ = try await PreferredRouterHTTPClient(route: route).get("/api/v1/status", token: "token")
    XCTAssertEqual(remote.callCount, 0)
    XCTAssertEqual(await route.selected, .local)
}

func test_reachabilityFailureFallsBackButTLSAuthAPIAndCancellationDoNot() async throws {
    for error in [
        NetworkError.unauthorized,
        NetworkError.decode("bad json"),
        NetworkError.httpStatus(500, "server"),
        CancellationError(),
    ] as [Error] {
        let remote = CountingRouterHTTPClient()
        let route = makeRoute(lanError: error, remote: remote)
        await XCTAssertThrowsErrorAsync { _ = try await route.http.get("/api/v1/status", token: "token") }
        XCTAssertEqual(remote.callCount, 0)
    }
    let remote = CountingRouterHTTPClient(response: .ok)
    let route = makeRoute(lanError: URLError(.notConnectedToInternet), remote: remote)
    _ = try await route.http.get("/api/v1/status", token: "token")
    XCTAssertEqual(remote.callCount, 1)
}

func test_eachSSEReconnectAttemptsLANBeforeRemote() async throws {
    let route = makeRoute(lanEventResults: [.failure(URLError(.cannotConnectToHost)), .success(.fixture)])
    _ = try await first(route.events.events(path: "/api/v1/events", token: "token"))
    _ = try await first(route.events.events(path: "/api/v1/events", token: "token"))
    XCTAssertEqual(route.lanEventOpenCount, 2)
    XCTAssertEqual(route.remoteEventOpenCount, 1)
}
```

- [ ] **Step 2: Run focused tests and confirm RED**

```bash
cd /Users/keith/.codex/worktrees/wattline-goodcloud/peakdo/apple/WattlineNetwork
swift test --filter PreferredRouterRouteTests
```

Expected: compilation fails because preferred route types do not exist.

- [ ] **Step 3: Implement explicit fallback classification and shared route state**

```swift
public enum RouterRouteKind: Equatable, Sendable { case local, remote }

enum RouterRouteFallbackPolicy {
    static func permitsRemoteFallback(_ error: Error) -> Bool {
        guard !Task.isCancelled, !(error is CancellationError) else { return false }
        if let urlError = error as? URLError {
            return [.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
                    .networkConnectionLost, .timedOut, .dnsLookupFailed].contains(urlError.code)
        }
        if case NetworkError.transport = error { return true }
        return false
    }
}
```

`PreferredRouterRoute` is an actor that starts each connection/SSE-open batch at local, records the selected route, and exposes HTTP/event operations. The HTTP wrapper attempts local only while selection is undecided/local, sets remote only after an allowed failure, and then sends through remote for the batch. The event wrapper always probes local on each new `events(...)` call; on allowed failure it opens remote. Do not inspect localized error text.

- [ ] **Step 4: Add failing production-wiring tests**

Extend `RouterAppWiringTests` to assert that production has injectable GoodCloud account/association factories and still constructs exactly one BLE transport owner. Extend discovery lifecycle tests to assert starting/stopping Bonjour does not call GoodCloud and saved LAN records remain unchanged.

Run:

```bash
cd /Users/keith/.codex/worktrees/wattline-goodcloud/peakdo/apple/Wattline
xcodebuild test -project Wattline.xcodeproj -scheme Wattline \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:WattlineTests/RouterAppWiringTests \
  -only-testing:WattlineTests/RouterDiscoveryLifecycleTests
```

Expected: tests fail because production wiring does not expose or construct preferred routes.

- [ ] **Step 5: Wire production factories without changing BLE or LAN implementations**

Extend `RouterConnectionModel.production` to create one shared `GoodCloudAccountService` and `GoodCloudAssociationStore`, then for an associated host construct:

```swift
let route = PreferredRouterRoute(
    lanHTTP: HTTPClient(baseURL: baseURL, session: lanSession),
    lanEvents: SSEClient(baseURL: baseURL, session: lanSession),
    remoteHTTP: RemoteRouterHTTPClient(coordinator: relayCoordinator),
    remoteEvents: RemoteRouterEventStream(coordinator: relayCoordinator)
)
return RouterTransport(
    endpoint: endpoint,
    accessLevel: .client,
    credentials: credentials,
    client: PreferredRouterHTTPClient(route: route),
    events: PreferredRouterEventStream(route: route),
    clock: SystemRouterConnectionClock(),
    backoff: RouterReconnectBackoff(delays: [.seconds(1), .seconds(2), .seconds(5), .seconds(10)])
)
```

When no association or authenticated account exists, retain the direct LAN transport; do not make login a prerequisite for LAN.

- [ ] **Step 6: Verify and commit**

```bash
cd /Users/keith/.codex/worktrees/wattline-goodcloud/peakdo/apple/WattlineNetwork
swift test --filter PreferredRouterRouteTests
swift test
cd ../Wattline
xcodebuild test -project Wattline.xcodeproj -scheme Wattline \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:WattlineTests/RouterAppWiringTests \
  -only-testing:WattlineTests/RouterDiscoveryLifecycleTests
git -C /Users/keith/.codex/worktrees/wattline-goodcloud add \
  peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/PreferredRouterRoute.swift \
  peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/PreferredRouterRouteTests.swift \
  peakdo/apple/WattlineShared/RouterConnectionModel.swift \
  peakdo/apple/Wattline/WattlineTests/RouterAppWiringTests.swift \
  peakdo/apple/Wattline/WattlineTests/RouterDiscoveryLifecycleTests.swift
git -C /Users/keith/.codex/worktrees/wattline-goodcloud commit \
  -m "feat: prefer LAN with GoodCloud fallback"
```

Expected: focused package/app tests pass and existing discovery behavior is unchanged.

---

### Task 6: Shared account model and iOS login/device association UI

**Files:**
- Create: `peakdo/apple/WattlineShared/RemoteAccess/GoodCloudSettingsModel.swift`
- Create: `peakdo/apple/WattlineShared/RemoteAccess/GoodCloudLoginView.swift`
- Create: `peakdo/apple/WattlineShared/RemoteAccess/GoodCloudDevicePickerView.swift`
- Create: `peakdo/apple/WattlineShared/RemoteAccess/GoodCloudSettingsSection.swift`
- Modify: `peakdo/apple/Wattline/Wattline/AppModel.swift`
- Modify: `peakdo/apple/Wattline/Wattline/Settings/SettingsView.swift`
- Create: `peakdo/apple/Wattline/WattlineTests/GoodCloudSettingsModelTests.swift`
- Create: `peakdo/apple/Wattline/WattlineTests/GoodCloudSettingsPresentationTests.swift`

**Interfaces:**
- Consumes: Task 3 account/association services and saved `RouterHostMetadata`.
- Produces: a shared observable settings model, redacted presentation state, login sheet, explicit device picker, and iOS Settings section.

- [ ] **Step 1: Write failing model and presentation tests**

```swift
func test_loginClearsPasswordBindingAndLoadsDevices() async {
    let service = FakeGoodCloudAccountService(loginResult: .authenticated([.fixture]))
    let model = GoodCloudSettingsModel(account: service, associations: .memory())
    var password = "secret-password"
    await model.login(email: "owner@example.com", password: password)
    password = ""
    XCTAssertEqual(password, "")
    XCTAssertEqual(model.state, .authenticated)
    XCTAssertEqual(model.devices, [.fixture])
    XCTAssertFalse(String(describing: model).contains("secret-password"))
}

func test_selectionIsExplicitAndRemovalLeavesHostAvailable() async throws {
    let fixture = makeSettingsFixture()
    XCTAssertEqual(fixture.model.suggestedDevice?.id, "42")
    XCTAssertNil(fixture.model.association)
    try await fixture.model.associate(deviceID: "42")
    XCTAssertEqual(fixture.model.association?.goodCloudDeviceID, "42")
    try await fixture.model.removeAssociation()
    XCTAssertNil(fixture.model.association)
    XCTAssertEqual(fixture.connections.savedHosts, [fixture.host])
}

func test_errorPresentationUsesFixedCopyForMinus1010AndGenericFailures() {
    XCTAssertEqual(GoodCloudSettingsPresentation(.requiresLogin).message,
        "Your GoodCloud session ended. Sign in again.")
    XCTAssertEqual(GoodCloudSettingsPresentation(.failed("redacted")).message,
        "Remote access is unavailable. Please try again.")
}
```

- [ ] **Step 2: Run focused app tests and confirm RED**

```bash
cd /Users/keith/.codex/worktrees/wattline-goodcloud/peakdo/apple/Wattline
xcodebuild test -project Wattline.xcodeproj -scheme Wattline \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:WattlineTests/GoodCloudSettingsModelTests \
  -only-testing:WattlineTests/GoodCloudSettingsPresentationTests
```

Expected: compilation fails because settings model/presentation types do not exist.

- [ ] **Step 3: Implement the shared observable state**

```swift
@MainActor
@Observable
final class GoodCloudSettingsModel {
    enum State: Equatable { case loggedOut, loading, authenticated, requiresLogin, failed }
    private(set) var state: State = .loggedOut
    private(set) var devices: [GoodCloudDeviceSummary] = []
    private(set) var association: GoodCloudAssociation?
    private(set) var errorMessage: String?
    var suggestedDevice: GoodCloudDeviceSummary? { /* exact normalized-MAC match only */ }

    func load() async
    func login(email: String, password: String) async
    func logout() async
    func associate(deviceID: String) async throws
    func removeAssociation() async throws
}
```

The model accepts protocols/factories in tests and production services in `AppModel`. It stores no password property. `login` receives a value, forwards it once, and does not reflect it in errors/descriptions.

- [ ] **Step 4: Implement iOS SwiftUI surfaces**

`GoodCloudLoginView` follows the tester sample: local `@State` email/password, `SecureField`, focused fields, loading state, and fixed error copy. Clear password in `defer` after submit and in `onDisappear`/scene deactivation.

`GoodCloudDevicePickerView` lists name/model/MAC/DDNS/online state, labels exact match as “Suggested,” requires a tap plus confirmation, and disables offline selection. `GoodCloudSettingsSection` shows sign-in when logged out; otherwise account status, association, change/remove, logout, and Local/Remote status when available. Add it to iOS `SettingsView` without modifying BLE controls.

- [ ] **Step 5: Verify and commit**

```bash
xcodebuild test -project Wattline.xcodeproj -scheme Wattline \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:WattlineTests/GoodCloudSettingsModelTests \
  -only-testing:WattlineTests/GoodCloudSettingsPresentationTests \
  -only-testing:WattlineTests/RouterAppWiringTests
git -C /Users/keith/.codex/worktrees/wattline-goodcloud add \
  peakdo/apple/WattlineShared/RemoteAccess \
  peakdo/apple/Wattline/Wattline/AppModel.swift \
  peakdo/apple/Wattline/Wattline/Settings/SettingsView.swift \
  peakdo/apple/Wattline/WattlineTests/GoodCloudSettingsModelTests.swift \
  peakdo/apple/Wattline/WattlineTests/GoodCloudSettingsPresentationTests.swift
git -C /Users/keith/.codex/worktrees/wattline-goodcloud commit \
  -m "feat: add GoodCloud login and router selection"
```

Expected: focused UI/model/wiring tests pass; password values are absent from failures and descriptions.

---

### Task 7: macOS surface, project verification, and live-validation handoff

**Files:**
- Modify: `peakdo/apple/Wattline/WattlineMac/MacAppModel.swift`
- Modify: `peakdo/apple/Wattline/WattlineMac/MacRootView.swift`
- Modify: `peakdo/apple/Wattline/WattlineMacTests/MacAppModelTests.swift`
- Modify: `peakdo/apple/Wattline/WattlineMacTests/MacRouterAdministrationTests.swift`
- Modify: `peakdo/apple/Wattline/WattlineTests/Phase2ProjectConfigurationTests.swift`
- Create: `peakdo/docs/goodcloud-live-validation.md`

**Interfaces:**
- Consumes: Task 6 shared GoodCloud settings model/views.
- Produces: identical macOS account/association controls, project dependency verification, and an honest hardware-validation checklist.

- [ ] **Step 1: Write failing macOS lifecycle and project tests**

```swift
func test_productionSharesGoodCloudSettingsWithRouterServicesWithoutAddingBLEOwner() {
    var bleFactoryCount = 0
    let remote = GoodCloudSettingsModel.fixture()
    let model = MacAppModel(
        transportFactory: { bleFactoryCount += 1; return RecordingTransport() },
        goodCloudSettings: remote
    )
    model.start()
    model.start()
    XCTAssertEqual(bleFactoryCount, 1)
    XCTAssertTrue(model.goodCloudSettings === remote)
}

func test_projectPinsGoodCloudKitByRevisionAndBothAppsUseWattlineNetwork() throws {
    let package = try String(contentsOf: TestProjectFiles.url("../WattlineNetwork/Package.swift"))
    XCTAssertTrue(package.contains("https://github.com/keithah/goodcloudkit"))
    XCTAssertTrue(package.contains("revision:"))
    XCTAssertFalse(package.contains("branch:"))
    XCTAssertFalse(package.contains("from: \"0.1.0\""))
}
```

- [ ] **Step 2: Run focused tests and confirm RED**

```bash
cd /Users/keith/.codex/worktrees/wattline-goodcloud/peakdo/apple/Wattline
xcodebuild test -project Wattline.xcodeproj -scheme WattlineMac \
  -destination 'platform=macOS' \
  -only-testing:WattlineMacTests/MacAppModelTests \
  -only-testing:WattlineMacTests/MacRouterAdministrationTests
xcodebuild test -project Wattline.xcodeproj -scheme Wattline \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:WattlineTests/Phase2ProjectConfigurationTests
```

Expected: macOS tests fail because the model/view do not expose GoodCloud settings; project test fails until exact dependency assertions are present.

- [ ] **Step 3: Wire macOS to the shared surface**

Add `goodCloudSettings: GoodCloudSettingsModel` to `MacAppModel`, construct it with the same production account/association services used by router services, and render `GoodCloudSettingsSection` inside `MacSettingsView`. Keep `transportFactory` invocation guarded by the existing `started` flag; do not construct BLE in the remote model or views.

- [ ] **Step 4: Write the live-validation handoff**

Create `peakdo/docs/goodcloud-live-validation.md` with these executable checks and expected results:

```markdown
# GoodCloud live validation

Hardware dependency: replacement GL-X3000 running Wattline/wattlined.

1. Sign in and associate the X3000 by exact MAC/device ID.
2. Leave the router LAN and provision `remoteAccess(deviceID: association.goodCloudDeviceID, port: 8377)`.
3. Send `GET /api/v1/status` with the Wattline bearer. Expect HTTP 200 and wattlined JSON.
4. Send one reversible JSON mutation. Confirm authorization and exact JSON body reach wattlined once.
5. Open `GET /api/v1/events` with `Accept: text/event-stream`. Expect live SSE frames.
6. Rejoin LAN, force an SSE reconnect, and confirm the active route returns to Local.
7. Log into GoodCloud elsewhere. Expect API -1010 to show Wattline's login surface while LAN/BLE credentials remain intact.

Until these checks pass, client-side tests prove request construction and pass-through only; they do not prove the deployed GL.iNet relay forwards headers/body/SSE end-to-end.
```

- [ ] **Step 5: Run full verification**

```bash
swift test --package-path /Users/keith/.codex/worktrees/goodcloud-relay-http
swift test --package-path /Users/keith/.codex/worktrees/wattline-goodcloud/peakdo/apple/WattlineCore
swift test --package-path /Users/keith/.codex/worktrees/wattline-goodcloud/peakdo/apple/WattlineNetwork
swift test --package-path /Users/keith/.codex/worktrees/wattline-goodcloud/peakdo/apple/WattlineUI
cd /Users/keith/.codex/worktrees/wattline-goodcloud/peakdo/apple/Wattline
xcodebuild test -project Wattline.xcodeproj -scheme Wattline \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
xcodebuild test -project Wattline.xcodeproj -scheme WattlineMac \
  -destination 'platform=macOS'
xcodebuild build -project Wattline.xcodeproj -scheme Wattline \
  -destination 'generic/platform=iOS Simulator'
xcodebuild build -project Wattline.xcodeproj -scheme WattlineMac \
  -destination 'platform=macOS'
```

Expected: all package and app tests pass; both app builds exit 0. Compare warnings with the baseline and introduce no new secret-bearing or Swift concurrency diagnostics.

- [ ] **Step 6: Commit the final task**

```bash
git -C /Users/keith/.codex/worktrees/wattline-goodcloud add \
  peakdo/apple/Wattline/WattlineMac/MacAppModel.swift \
  peakdo/apple/Wattline/WattlineMac/MacRootView.swift \
  peakdo/apple/Wattline/WattlineMacTests/MacAppModelTests.swift \
  peakdo/apple/Wattline/WattlineMacTests/MacRouterAdministrationTests.swift \
  peakdo/apple/Wattline/WattlineTests/Phase2ProjectConfigurationTests.swift \
  peakdo/docs/goodcloud-live-validation.md
git -C /Users/keith/.codex/worktrees/wattline-goodcloud commit \
  -m "feat: complete GoodCloud remote access surfaces"
```

Expected: commit succeeds only after the full verification output in Step 5 is recorded in the task report.

---

## Final review and branch handoff

After every task has passed its task-scoped spec/code-quality review:

1. Generate a whole-branch review package from merge base `ec8425f2` through Wattline HEAD.
2. Generate a separate GoodCloudKit review package from `20690c9` through its feature HEAD.
3. Dispatch one most-capable final reviewer with both packages, this plan, the approved design spec, test reports, and the ledger's minor-finding list.
4. If findings exist, dispatch one fix agent with the complete list, rerun covering tests, regenerate both review packages, and re-review.
5. Run the full Task 7 verification commands fresh after the final review/fixes.
6. Report both branch names and commits, the immutable GoodCloud revision pinned by Wattline, exact test/build evidence, and the deferred hardware limitation. Do not claim the deployed relay preserves headers/body/SSE until the live checklist passes.
