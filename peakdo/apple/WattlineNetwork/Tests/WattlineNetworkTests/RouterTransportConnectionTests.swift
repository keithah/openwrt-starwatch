import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import WattlineCore
import XCTest
@testable import WattlineNetwork

final class RouterTransportConnectionTests: XCTestCase {
    private let endpoint = RouterEndpoint(
        scheme: "http",
        host: "wattline-router.local",
        port: 8080,
        certificateFingerprint: nil,
        allowsInsecureWAN: false
    )
    private let credentials = TransientRouterCredentialProvider(token: "test-token")
    private let origin = RouterTimestampOrigin(
        wallClock: Date(timeIntervalSince1970: 1_752_739_200),
        deviceTimestamp: .seconds(40)
    )

    func testConnectionScopesUseStableEndpointIdentityAndFreshSessions() async {
        let server = FakeRouterServer()
        let transport = makeTransport(server: server)

        let first = await transport.makeConnectionScope(for: UUID())
        let second = await transport.makeConnectionScope(for: UUID())

        XCTAssertEqual(first.peripheralID, endpoint.peripheralID)
        XCTAssertEqual(second.peripheralID, endpoint.peripheralID)
        XCTAssertNotEqual(first.sessionID, second.sessionID)
    }

    func testEndpointIdentityNormalizesEquivalentAuthorityAndSeparatesDistinctEndpoints() {
        let equivalent = RouterEndpoint(
            scheme: "HTTP",
            host: "WATTLINE-ROUTER.LOCAL.",
            port: 8080,
            certificateFingerprint: "fingerprint",
            allowsInsecureWAN: true
        )
        let normalized = RouterEndpoint(
            scheme: "http",
            host: "wattline-router.local",
            port: 8080,
            certificateFingerprint: nil,
            allowsInsecureWAN: false
        )
        let distinct = [
            RouterEndpoint(
                scheme: "https",
                host: "wattline-router.local",
                port: 8080,
                certificateFingerprint: nil,
                allowsInsecureWAN: false
            ),
            RouterEndpoint(
                scheme: "http",
                host: "other-router.local",
                port: 8080,
                certificateFingerprint: nil,
                allowsInsecureWAN: false
            ),
            RouterEndpoint(
                scheme: "http",
                host: "wattline-router.local",
                port: 8081,
                certificateFingerprint: nil,
                allowsInsecureWAN: false
            ),
        ]

        XCTAssertEqual(equivalent.peripheralID, normalized.peripheralID)
        XCTAssertEqual(Set(distinct.map(\.peripheralID)).count, distinct.count)
        XCTAssertFalse(distinct.map(\.peripheralID).contains(normalized.peripheralID))
    }

    func testCredentialsAreInjectedTransientlyAndDescriptionsAreRedacted() async throws {
        let server = FakeRouterServer()
        server.setResponse(data: statusData(), for: "/api/v1/status")
        let provider = RecordingCredentialProvider(token: "test-token")
        let credential = RouterCredential(token: "test-token")
        let transport = RouterTransport(
            endpoint: endpoint,
            credentials: provider,
            client: server,
            events: server,
            clock: TestRouterClock(now: .zero, origin: origin),
            backoff: RouterReconnectBackoff(delays: [.seconds(1)])
        )
        addTeardownBlock { await transport.disconnect() }
        let scope = await transport.makeConnectionScope(for: endpoint.peripheralID)

        try await transport.connect(to: endpoint.peripheralID, scope: scope)
        try await server.waitForEventStreamCount(1)

        let requestedEndpoints = await provider.requestedEndpoints
        XCTAssertEqual(requestedEndpoints, [endpoint, endpoint])
        XCTAssertEqual(server.requests.map(\.authorization), ["Bearer test-token", "Bearer test-token"])
        XCTAssertFalse(String(describing: endpoint).contains("test-token"))
        XCTAssertFalse(String(reflecting: endpoint).contains("test-token"))
        XCTAssertFalse(String(describing: credential).contains("test-token"))
        XCTAssertFalse(String(reflecting: credential).contains("test-token"))
    }

    func testConnectAuthenticatesStatusThenEmitsHandshakeAndConnected() async throws {
        let server = FakeRouterServer()
        server.setResponse(data: statusData(), for: "/api/v1/status")
        let transport = makeTransport(server: server)
        let recorder = DeviceEventRecorder(stream: transport.events)
        let scope = await transport.makeConnectionScope(for: endpoint.peripheralID)

        try await transport.connect(to: endpoint.peripheralID, scope: scope)
        let values = try await recorder.waitForCount(2)

        guard case let .handshakeCompleted(identity, emittedScope) = values[0] else {
            return XCTFail("expected handshake first")
        }
        XCTAssertEqual(emittedScope, scope)
        XCTAssertEqual(identity.peripheralID, endpoint.peripheralID)
        XCTAssertEqual(identity.modelNumber, "BP4SL3V2")
        XCTAssertEqual(identity.macAddress, "DC:04:5A:EB:72:2B")
        XCTAssertEqual(values[1], .connected(scope))

        try await server.waitForEventStreamCount(1)
        XCTAssertEqual(server.requests.map(\.path), ["/api/v1/status", "/api/v1/events"])
        XCTAssertEqual(server.requests.map(\.authorization), ["Bearer test-token", "Bearer test-token"])
        await transport.disconnect()
    }

    func testConnectRedactsTokenFromInjectedClientErrors() async {
        let client = ThrowingHTTPClient(
            error: NetworkError.httpStatus(503, "router echoed test-token")
        )
        let transport = RouterTransport(
            endpoint: endpoint,
            credentials: credentials,
            client: client,
            events: FakeRouterServer(),
            clock: TestRouterClock(now: .zero, origin: origin),
            backoff: RouterReconnectBackoff(delays: [.seconds(1)])
        )
        let scope = await transport.makeConnectionScope(for: endpoint.peripheralID)

        do {
            try await transport.connect(to: endpoint.peripheralID, scope: scope)
            XCTFail("expected status failure")
        } catch {
            XCTAssertEqual(
                error as? NetworkError,
                .httpStatus(503, "router echoed [REDACTED]")
            )
            XCTAssertFalse(String(describing: error).contains("test-token"))
        }
    }

    func testCredentialProviderErrorsCannotExposeSecretMaterial() async {
        let transport = RouterTransport(
            endpoint: endpoint,
            credentials: ThrowingCredentialProvider(
                error: NetworkError.decode("credential lookup leaked test-token")
            ),
            client: FakeRouterServer(),
            events: FakeRouterServer(),
            clock: TestRouterClock(now: .zero, origin: origin),
            backoff: RouterReconnectBackoff(delays: [.seconds(1)])
        )
        let scope = await transport.makeConnectionScope(for: endpoint.peripheralID)

        do {
            try await transport.connect(to: endpoint.peripheralID, scope: scope)
            XCTFail("expected credential failure")
        } catch {
            XCTAssertEqual(error as? NetworkError, .unauthorized)
            XCTAssertFalse(String(describing: error).contains("test-token"))
        }
    }

    func testInitialSSESnapshotUsesInjectedTimestampOriginForTelemetry() async throws {
        let server = FakeRouterServer()
        server.setResponse(data: statusData(), for: "/api/v1/status")
        let clock = TestRouterClock(now: .seconds(900), origin: origin)
        let transport = makeTransport(server: server, clock: clock)
        let recorder = DeviceEventRecorder(stream: transport.events)
        let scope = await transport.makeConnectionScope(for: endpoint.peripheralID)

        try await transport.connect(to: endpoint.peripheralID, scope: scope)
        try await server.waitForEventStreamCount(1)
        XCTAssertTrue(server.pushPayload(snapshotData(level: 74, updatedAt: "2025-07-17T08:00:02.250Z")))
        let values = try await recorder.waitForCount(4)

        XCTAssertEqual(values[2], .connected(scope))
        guard case let .battery(battery, timestamp) = values[3] else {
            return XCTFail("expected initial SSE battery telemetry")
        }
        XCTAssertEqual(battery.level, 74)
        XCTAssertEqual(timestamp, .milliseconds(42_250))
        await transport.disconnect()
    }

    func testInvalidUTF8JSONIsRejectedWithoutPublishingTelemetry() async throws {
        let server = FakeRouterServer()
        server.setResponse(data: statusData(), for: "/api/v1/status")
        let transport = makeTransport(server: server)
        let recorder = DeviceEventRecorder(stream: transport.events)
        let scope = await transport.makeConnectionScope(for: endpoint.peripheralID)

        try await transport.connect(to: endpoint.peripheralID, scope: scope)
        try await server.waitForEventStreamCount(1)
        var invalidSnapshot = Data(#"{"bad":""#.utf8)
        invalidSnapshot.append(0xFF)
        invalidSnapshot.append(contentsOf: Data(#"","battery":{"enabled":true,"status":1,"full":false,"max_wh":99.5,"wh":73.25,"level":99,"volts":20.8,"amps":2.5,"watts":52.0,"remain_min":87},"connected":true}"#.utf8))
        XCTAssertTrue(server.pushPayload(invalidSnapshot))
        let values = try await recorder.waitForCount(3)

        XCTAssertEqual(values[2], .reconnecting(scope))
        XCTAssertFalse(values.contains { event in
            if case .battery = event { return true }
            return false
        })
        await transport.disconnect()
    }

    func testStreamLossMarksTelemetryStaleThenReconnectsSuccessfully() async throws {
        let server = FakeRouterServer()
        server.setResponse(data: statusData(), for: "/api/v1/status")
        let clock = TestRouterClock(now: .seconds(50), origin: origin)
        let transport = makeTransport(
            server: server,
            clock: clock,
            backoff: RouterReconnectBackoff(delays: [.seconds(1), .seconds(2)])
        )
        let recorder = DeviceEventRecorder(stream: transport.events)
        let scope = await transport.makeConnectionScope(for: endpoint.peripheralID)

        try await transport.connect(to: endpoint.peripheralID, scope: scope)
        try await server.waitForEventStreamCount(1)
        XCTAssertTrue(server.pushPayload(snapshotData(level: 40)))
        _ = try await recorder.waitForCount(4)

        XCTAssertTrue(server.fail(NetworkError.streamEnded))
        let lost = try await recorder.waitForCount(5)
        XCTAssertEqual(lost[4], .reconnecting(scope))
        XCTAssertFalse(lost.contains { event in
            if case .disconnected = event { return true }
            return false
        })

        await clock.waitForSleepCount(1)
        let firstSleepDurations = await clock.sleepDurations
        XCTAssertEqual(firstSleepDurations, [.seconds(1)])
        await clock.advance(by: .seconds(1))
        try await server.waitForEventStreamCount(2)
        XCTAssertTrue(server.pushPayload(snapshotData(level: 41)))

        let reconnected = try await recorder.waitForCount(7)
        XCTAssertEqual(reconnected[5], .connected(scope))
        guard case let .battery(battery, _) = reconnected[6] else {
            return XCTFail("expected telemetry after stream reconnect")
        }
        XCTAssertEqual(battery.level, 41)
        await transport.disconnect()
    }

    func testRecoverableStreamLossDoesNotRetireScopeInDeviceSession() async throws {
        let server = FakeRouterServer()
        server.setResponse(data: statusData(), for: "/api/v1/status")
        let clock = TestRouterClock(now: .seconds(50), origin: origin)
        let transport = makeTransport(
            server: server,
            clock: clock,
            backoff: RouterReconnectBackoff(delays: [.seconds(1)])
        )
        addTeardownBlock { await transport.disconnect() }
        let session = DeviceSession(
            transport: transport,
            clock: TestRouterClock(now: .seconds(50), origin: origin)
        )
        let states = DeviceStateRecorder(stream: session.states)
        let scope = await transport.makeConnectionScope(for: endpoint.peripheralID)
        await session.start()

        try await transport.connect(to: endpoint.peripheralID, scope: scope)
        try await server.waitForEventStreamCount(1)
        XCTAssertTrue(server.pushPayload(snapshotData(level: 40)))
        try await states.waitUntil { $0.connection == .live && $0.battery?.level == 40 }

        XCTAssertTrue(server.fail(NetworkError.streamEnded))
        try await states.waitUntil { $0.connection == .reconnecting }
        await clock.waitForSleepCount(1)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertFalse(states.values.contains { $0.connection == .disconnected })

        await clock.advance(by: .seconds(1))
        try await server.waitForEventStreamCount(2)
        XCTAssertTrue(server.pushPayload(Data(#"{"connected":true}"#.utf8)))
        try await states.waitUntil { $0.connection == .loading }
        XCTAssertFalse(states.values.contains { $0.connection == .disconnected })

        XCTAssertTrue(server.pushPayload(snapshotData(level: 41)))
        try await states.waitUntil { $0.connection == .live && $0.battery?.level == 41 }
        await transport.disconnect()
        try await states.waitUntil { $0.connection == .disconnected }
    }

    func testConnectedFalseSnapshotReconnectsBeforeLaterTelemetryRestoresLive() async throws {
        let server = FakeRouterServer()
        server.setResponse(data: statusData(), for: "/api/v1/status")
        let clock = TestRouterClock(now: .seconds(50), origin: origin)
        let transport = makeTransport(
            server: server,
            clock: clock,
            backoff: RouterReconnectBackoff(delays: [.seconds(1)])
        )
        addTeardownBlock { await transport.disconnect() }
        let recorder = DeviceEventRecorder(stream: transport.events)
        let scope = await transport.makeConnectionScope(for: endpoint.peripheralID)

        try await transport.connect(to: endpoint.peripheralID, scope: scope)
        try await server.waitForEventStreamCount(1)
        XCTAssertTrue(server.pushPayload(Data(#"{"connected":false}"#.utf8)))
        let loss = try await recorder.waitForCount(3)
        XCTAssertEqual(loss[2], .reconnecting(scope))
        XCTAssertFalse(loss.contains { event in
            if case .disconnected = event { return true }
            return false
        })

        await clock.waitForSleepCount(1)
        await clock.advance(by: .seconds(1))
        try await server.waitForEventStreamCount(2)
        XCTAssertTrue(server.pushPayload(snapshotData(level: 42)))
        let restored = try await recorder.waitForCount(5)
        XCTAssertEqual(restored[3], .connected(scope))
        guard case let .battery(battery, _) = restored[4] else {
            return XCTFail("expected telemetry after connected=false reconnect")
        }
        XCTAssertEqual(battery.level, 42)
        await transport.disconnect()
    }

    func testReconnectBackoffCapsAtLastConfiguredDelay() async throws {
        let server = FakeRouterServer()
        server.setResponse(data: statusData(), for: "/api/v1/status")
        let clock = TestRouterClock(now: .zero, origin: origin)
        let transport = makeTransport(
            server: server,
            clock: clock,
            backoff: RouterReconnectBackoff(delays: [.seconds(1), .seconds(2)])
        )
        let scope = await transport.makeConnectionScope(for: endpoint.peripheralID)

        try await transport.connect(to: endpoint.peripheralID, scope: scope)
        for attempt in 1...3 {
            try await server.waitForEventStreamCount(attempt)
            XCTAssertTrue(server.fail(NetworkError.streamEnded))
            await clock.waitForSleepCount(attempt)
            if attempt < 3 {
                await clock.advance(by: attempt == 1 ? .seconds(1) : .seconds(2))
            }
        }

        let sleepDurations = await clock.sleepDurations
        XCTAssertEqual(sleepDurations, [.seconds(1), .seconds(2), .seconds(2)])
        await transport.disconnect()
    }

    func testOlderStreamPayloadIsQuarantinedAfterNewConnectGenerationStarts() async throws {
        let client = GatedStatusClient(data: statusData())
        let streams = LeakyEventStream()
        let clock = TestRouterClock(now: .seconds(70), origin: origin)
        let transport = RouterTransport(
            endpoint: endpoint,
            credentials: credentials,
            client: client,
            events: streams,
            clock: clock,
            backoff: RouterReconnectBackoff(delays: [.seconds(1)])
        )
        addTeardownBlock { await transport.disconnect() }
        let recorder = DeviceEventRecorder(stream: transport.events)
        let firstScope = await transport.makeConnectionScope(for: endpoint.peripheralID)

        try await transport.connect(to: endpoint.peripheralID, scope: firstScope)
        await streams.waitForStreamCount(1)
        let firstPushAccepted = streams.pushPayload(snapshotData(level: 11), to: 0)
        XCTAssertTrue(firstPushAccepted)
        _ = try await recorder.waitForCount(4)

        await client.gateNextStatusRequest()
        let secondScope = await transport.makeConnectionScope(for: endpoint.peripheralID)
        let endpointID = endpoint.peripheralID
        let secondConnect = Task {
            try await transport.connect(to: endpointID, scope: secondScope)
        }
        await client.waitForGatedRequest()

        let stalePushAccepted = streams.pushPayload(snapshotData(level: 22), to: 0)
        XCTAssertTrue(stalePushAccepted)
        for _ in 0..<100 { await Task.yield() }
        let countAfterStalePush = recorder.count
        XCTAssertEqual(countAfterStalePush, 4)

        await client.releaseGatedRequest()
        try await secondConnect.value
        await streams.waitForStreamCount(2)
        let currentPushAccepted = streams.pushPayload(snapshotData(level: 33), to: 1)
        XCTAssertTrue(currentPushAccepted)
        let values = try await recorder.waitForCount(8)

        let levels = values.compactMap { event -> UInt8? in
            guard case let .battery(battery, _) = event else { return nil }
            return battery.level
        }
        XCTAssertEqual(levels, [11, 33])
        await transport.disconnect()
    }

    func testDisconnectDuringReplacementStatusFetchCancelsPreviousStream() async throws {
        let client = GatedStatusClient(data: statusData())
        let streams = LeakyEventStream()
        let transport = RouterTransport(
            endpoint: endpoint,
            credentials: credentials,
            client: client,
            events: streams,
            clock: TestRouterClock(now: .zero, origin: origin),
            backoff: RouterReconnectBackoff(delays: [.seconds(1)])
        )
        addTeardownBlock { await transport.disconnect() }
        let firstScope = await transport.makeConnectionScope(for: endpoint.peripheralID)
        try await transport.connect(to: endpoint.peripheralID, scope: firstScope)
        await streams.waitForStreamCount(1)

        await client.gateNextStatusRequest()
        let secondScope = await transport.makeConnectionScope(for: endpoint.peripheralID)
        let endpointID = endpoint.peripheralID
        let replacement = Task {
            try await transport.connect(to: endpointID, scope: secondScope)
        }
        await client.waitForGatedRequest()

        await transport.disconnect()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertFalse(streams.pushPayload(snapshotData(level: 55), to: 0))

        await client.releaseGatedRequest()
        await assertCancellation(of: replacement)
        XCTAssertEqual(streams.streamCount, 1)
    }

    func testDisconnectCancelsInFlightStatusAndConnectThrowsCancellation() async {
        let client = CancellationObservingStatusClient(data: statusData())
        let transport = RouterTransport(
            endpoint: endpoint,
            credentials: credentials,
            client: client,
            events: FakeRouterServer(),
            clock: TestRouterClock(now: .zero, origin: origin),
            backoff: RouterReconnectBackoff(delays: [.seconds(1)])
        )
        let scope = await transport.makeConnectionScope(for: endpoint.peripheralID)
        let endpointID = endpoint.peripheralID
        let connection = Task {
            try await transport.connect(to: endpointID, scope: scope)
        }
        await client.waitForRequestCount(1)

        await transport.disconnect()

        await assertCancellation(of: connection)
        await client.waitForCancellationCount(1)
    }

    func testCallerCancellationCancelsInFlightStatusAndRemainsCancellation() async {
        let client = CancellationObservingStatusClient(data: statusData())
        let transport = RouterTransport(
            endpoint: endpoint,
            credentials: credentials,
            client: client,
            events: FakeRouterServer(),
            clock: TestRouterClock(now: .zero, origin: origin),
            backoff: RouterReconnectBackoff(delays: [.seconds(1)])
        )
        addTeardownBlock { await transport.disconnect() }
        let scope = await transport.makeConnectionScope(for: endpoint.peripheralID)
        let endpointID = endpoint.peripheralID
        let connection = Task {
            try await transport.connect(to: endpointID, scope: scope)
        }
        await client.waitForRequestCount(1)

        connection.cancel()

        await assertCancellation(of: connection)
        await client.waitForCancellationCount(1)
    }

    func testReplacementConnectCancelsSupersededStatusAndCompletesNewConnect() async throws {
        let client = CancellationObservingStatusClient(data: statusData())
        let server = FakeRouterServer()
        let transport = RouterTransport(
            endpoint: endpoint,
            credentials: credentials,
            client: client,
            events: server,
            clock: TestRouterClock(now: .zero, origin: origin),
            backoff: RouterReconnectBackoff(delays: [.seconds(1)])
        )
        addTeardownBlock { await transport.disconnect() }
        let endpointID = endpoint.peripheralID
        let firstScope = await transport.makeConnectionScope(for: endpointID)
        let firstConnection = Task {
            try await transport.connect(to: endpointID, scope: firstScope)
        }
        await client.waitForRequestCount(1)

        await client.allowRequestsAfterFirst()
        let secondScope = await transport.makeConnectionScope(for: endpointID)
        try await transport.connect(to: endpointID, scope: secondScope)

        await assertCancellation(of: firstConnection)
        await client.waitForCancellationCount(1)
        try await server.waitForEventStreamCount(1)
        await transport.disconnect()
    }

    func testConnectionDeallocationCancelsStreamAndFinishesOutput() async throws {
        let server = FakeRouterServer()
        server.setResponse(data: statusData(), for: "/api/v1/status")
        let output = AsyncStream<DeviceEvent>.makeStream()
        let completion = EventStreamCompletionProbe(stream: output.stream)
        var connection: RouterConnection? = RouterConnection(
            endpoint: endpoint,
            credentials: credentials,
            client: server,
            events: server,
            clock: TestRouterClock(now: .zero, origin: origin),
            backoff: RouterReconnectBackoff(delays: [.seconds(1)]),
            output: output.continuation
        )
        let weakConnection = WeakReference(connection)
        let scope = await connection?.makeConnectionScope()

        try await connection?.connect(
            to: endpoint.peripheralID,
            scope: try XCTUnwrap(scope)
        )
        try await server.waitForEventStreamCount(1)
        connection = nil

        let didDeallocate = await waitForCondition { weakConnection.value == nil }
        if !didDeallocate {
            await weakConnection.value?.disconnect()
        }
        XCTAssertTrue(didDeallocate, "stream task retained RouterConnection")
        try await completion.waitForFinish()
        XCTAssertFalse(server.pushPayload(snapshotData(level: 88)))
    }

    func testManualScanIsNoOpAndCommandsAreClearlyUnsupported() async throws {
        let transport = makeTransport(server: FakeRouterServer())

        try await transport.startScan()
        await transport.stopScan()
        do {
            _ = try await transport.perform(DeviceCommand.setDC(true))
            XCTFail("expected Task 5 command placeholder")
        } catch {
            XCTAssertEqual(error as? NetworkError, .unsupported("Router commands are Task 5"))
        }
    }

    private func makeTransport(
        server: FakeRouterServer,
        clock: TestRouterClock? = nil,
        backoff: RouterReconnectBackoff = .init(delays: [.seconds(1)])
    ) -> RouterTransport {
        RouterTransport(
            endpoint: endpoint,
            credentials: credentials,
            client: server,
            events: server,
            clock: clock ?? TestRouterClock(now: .seconds(50), origin: origin),
            backoff: backoff
        )
    }

    private func statusData() -> Data {
        Data(#"{"connected":true,"device":{"model":"BP4SL3V2","hw_rev":"2.1","firmware":"1.4.9","mac":"DC:04:5A:EB:72:2B","cid":770,"features":16496}}"#.utf8)
    }

    private func snapshotData(level: UInt8, updatedAt: String? = nil) -> Data {
        let timestamp = updatedAt.map { #", "updated_at":"\#($0)""# } ?? ""
        return Data(#"{"battery":{"enabled":true,"status":1,"full":false,"max_wh":99.5,"wh":73.25,"level":\#(level),"volts":20.8,"amps":2.5,"watts":52.0,"remain_min":87},"connected":true\#(timestamp)}"#.utf8)
    }

    private func assertCancellation(
        of task: Task<Void, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await task.value
            XCTFail("expected CancellationError", file: file, line: line)
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, received \(error)", file: file, line: line)
        }
    }

    private func waitForCondition(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<20_000 {
            if condition() { return true }
            await Task.yield()
        }
        return false
    }
}

final class FakeRouterServerContractTests: XCTestCase {
    func testPushWithoutActiveContinuationIsObservable() {
        let server = FakeRouterServer()
        XCTAssertFalse(server.pushPayload(Data("orphan".utf8)))
    }

    func testStartingSecondEventStreamTerminatesFirst() async throws {
        let server = FakeRouterServer()
        let first = server.events(path: "/api/v1/events", token: "one")
        var firstIterator = first.makeAsyncIterator()
        let second = server.events(path: "/api/v1/events", token: "two")
        _ = second

        let firstEnd = try await firstIterator.next()
        XCTAssertNil(firstEnd)
        XCTAssertEqual(server.eventStreamCount, 2)
    }

    func testResponsesAreConfiguredPerStatusAndEventsPath() async throws {
        let server = FakeRouterServer()
        server.setResponse(data: Data("status".utf8), statusCode: 200, for: "/api/v1/status")
        server.setResponse(data: Data("events-down".utf8), statusCode: 503, for: "/api/v1/events")

        let (data, response) = try await server.get("/api/v1/status", token: "token")
        XCTAssertEqual(data, Data("status".utf8))
        XCTAssertEqual(response.statusCode, 200)

        var iterator = server.events(path: "/api/v1/events", token: "token").makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("expected per-path stream error")
        } catch {
            XCTAssertEqual(error as? NetworkError, .httpStatus(503, "events-down"))
        }
    }
}

private final class DeviceEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DeviceEvent] = []
    private var collectionTask: Task<Void, Never>?

    init(stream: AsyncStream<DeviceEvent>) {
        collectionTask = Task { [weak self] in
            for await event in stream {
                self?.append(event)
            }
        }
    }

    deinit {
        collectionTask?.cancel()
    }

    var count: Int { lock.withLock { values.count } }

    func waitForCount(_ expectedCount: Int) async throws -> [DeviceEvent] {
        for _ in 0..<20_000 {
            let snapshot = lock.withLock { values }
            if snapshot.count >= expectedCount { return snapshot }
            await Task.yield()
        }
        throw TestProbeError.timedOut("expected \(expectedCount) events, received \(count)")
    }

    private func append(_ event: DeviceEvent) {
        lock.withLock { values.append(event) }
    }
}

private final class DeviceStateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [DeviceState] = []
    private var collectionTask: Task<Void, Never>?

    init(stream: AsyncStream<DeviceState>) {
        collectionTask = Task { [weak self] in
            for await state in stream {
                self?.lock.withLock { self?.storedValues.append(state) }
            }
        }
    }

    deinit {
        collectionTask?.cancel()
    }

    var values: [DeviceState] { lock.withLock { storedValues } }

    func waitUntil(_ predicate: (DeviceState) -> Bool) async throws {
        for _ in 0..<20_000 {
            if values.contains(where: predicate) { return }
            await Task.yield()
        }
        throw TestProbeError.timedOut("expected DeviceSession state")
    }
}

private final class EventStreamCompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var didFinish = false
    private var collectionTask: Task<Void, Never>?

    init(stream: AsyncStream<DeviceEvent>) {
        collectionTask = Task { [weak self] in
            for await _ in stream {}
            self?.lock.withLock { self?.didFinish = true }
        }
    }

    deinit {
        collectionTask?.cancel()
    }

    func waitForFinish() async throws {
        for _ in 0..<20_000 {
            if lock.withLock({ didFinish }) { return }
            await Task.yield()
        }
        throw TestProbeError.timedOut("expected transport event stream to finish")
    }
}

private actor TestRouterClock: RouterConnectionClock, DeviceClock {
    private(set) var now: DeviceTimestamp
    let origin: RouterTimestampOrigin
    private var sleeps: [Duration] = []
    private var sleepers: [CheckedContinuation<Void, Never>] = []

    init(now: DeviceTimestamp, origin: RouterTimestampOrigin) {
        self.now = now
        self.origin = origin
    }

    var sleepDurations: [Duration] { sleeps }

    func sampleTimestampOrigin() async -> RouterTimestampOrigin {
        origin
    }

    func sleep(for duration: Duration) async throws {
        sleeps.append(duration)
        await withCheckedContinuation { sleepers.append($0) }
    }

    func waitForSleepCount(_ count: Int) async {
        for _ in 0..<20_000 {
            if sleeps.count >= count { return }
            await Task.yield()
        }
    }

    func advance(by duration: Duration) {
        now += duration
        guard !sleepers.isEmpty else { return }
        sleepers.removeFirst().resume()
    }
}

private actor CancellationObservingStatusClient: RouterHTTPClient {
    private let data: Data
    private var requestCount = 0
    private var cancellationCount = 0
    private var shouldBlock = true

    init(data: Data) {
        self.data = data
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
        requestCount += 1
        if shouldBlock {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch is CancellationError {
                cancellationCount += 1
                throw CancellationError()
            }
        }
        let response = HTTPURLResponse(
            url: URL(string: "http://fake.local\(path)")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }

    func allowRequestsAfterFirst() {
        shouldBlock = false
    }

    func waitForRequestCount(_ expectedCount: Int) async {
        for _ in 0..<20_000 {
            if requestCount >= expectedCount { return }
            await Task.yield()
        }
    }

    func waitForCancellationCount(_ expectedCount: Int) async {
        for _ in 0..<20_000 {
            if cancellationCount >= expectedCount { return }
            await Task.yield()
        }
    }
}

private actor RecordingCredentialProvider: RouterCredentialProvider {
    private let token: String
    private(set) var requestedEndpoints: [RouterEndpoint] = []

    init(token: String) {
        self.token = token
    }

    func credential(for endpoint: RouterEndpoint) async throws -> RouterCredential {
        requestedEndpoints.append(endpoint)
        return RouterCredential(token: token)
    }
}

private actor GatedStatusClient: RouterHTTPClient {
    private let data: Data
    private var shouldGate = false
    private var gatedRequestStarted = false
    private var gateContinuation: CheckedContinuation<Void, Never>?

    init(data: Data) {
        self.data = data
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
            shouldGate = false
            gatedRequestStarted = true
            await withCheckedContinuation { gateContinuation = $0 }
        }
        let response = HTTPURLResponse(
            url: URL(string: "http://fake.local\(path)")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }

    func gateNextStatusRequest() {
        shouldGate = true
    }

    func waitForGatedRequest() async {
        while !gatedRequestStarted { await Task.yield() }
    }

    func releaseGatedRequest() {
        gateContinuation?.resume()
        gateContinuation = nil
    }
}

private struct ThrowingHTTPClient: RouterHTTPClient {
    let error: NetworkError

    func get(_ path: String, token: String) async throws -> (Data, HTTPURLResponse) {
        throw error
    }

    func request(
        _ method: String,
        _ path: String,
        body: Data?,
        token: String
    ) async throws -> (Data, HTTPURLResponse) {
        throw error
    }
}

private struct ThrowingCredentialProvider: RouterCredentialProvider {
    let error: NetworkError

    func credential(for endpoint: RouterEndpoint) async throws -> RouterCredential {
        throw error
    }
}

private final class WeakReference<Value: AnyObject>: @unchecked Sendable {
    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}

private final class LeakyEventStream: RouterEventStream, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncThrowingStream<Data, Error>.Continuation] = []

    var streamCount: Int { lock.withLock { continuations.count } }

    func events(path: String, token: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { continuations.append(continuation) }
        }
    }

    func pushPayload(_ payload: Data, to index: Int) -> Bool {
        lock.withLock {
            guard continuations.indices.contains(index) else { return false }
            if case .terminated = continuations[index].yield(payload) { return false }
            return true
        }
    }

    func waitForStreamCount(_ expectedCount: Int) async {
        while streamCount < expectedCount { await Task.yield() }
    }
}

private enum TestProbeError: Error {
    case timedOut(String)
}
