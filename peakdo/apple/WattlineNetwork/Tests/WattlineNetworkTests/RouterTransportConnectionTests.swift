import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import WattlineCore
import XCTest
@testable import WattlineNetwork

final class RouterTransportConnectionTests: XCTestCase {
    func testOriginalPublicInitializerRemainsAnExplicitABISymbol() {
        let constructor: (
            RouterEndpoint,
            any RouterCredentialProvider,
            any RouterHTTPClient,
            any RouterEventStream,
            any RouterConnectionClock,
            RouterReconnectBackoff
        ) -> RouterTransport = RouterTransport.init(
            endpoint:credentials:client:events:clock:backoff:
        )

        _ = constructor
    }

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
        server.setResponse(data: statusData(), for: "/api/v1/device")
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

    func testConnectAuthenticatesCanonicalDeviceThenEmitsHandshakeAndConnected() async throws {
        let server = FakeRouterServer()
        server.setResponse(data: statusData(), for: "/api/v1/device")
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
        XCTAssertEqual(server.requests.map(\.path), ["/api/v1/device", "/api/v1/events"])
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
        server.setResponse(data: statusData(), for: "/api/v1/device")
        let clock = TestRouterClock(now: .seconds(900), origin: origin)
        let transport = makeTransport(server: server, clock: clock)
        let recorder = DeviceEventRecorder(stream: transport.events)
        let scope = await transport.makeConnectionScope(for: endpoint.peripheralID)

        try await transport.connect(to: endpoint.peripheralID, scope: scope)
        try await server.waitForEventStreamCount(1)
        XCTAssertTrue(server.pushPayload(snapshotData(level: 74, updatedAt: "2025-07-17T08:00:02.250Z")))
        let values = try await recorder.waitForCount(3)

        guard case let .battery(battery, timestamp) = values[2] else {
            return XCTFail("expected initial SSE battery telemetry")
        }
        XCTAssertEqual(battery.level, 74)
        XCTAssertEqual(timestamp, .milliseconds(42_250))
        await transport.disconnect()
    }

    func testInvalidUTF8JSONIsRejectedWithoutPublishingTelemetry() async throws {
        let server = FakeRouterServer()
        server.setResponse(data: statusData(), for: "/api/v1/device")
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
        server.setResponse(data: statusData(), for: "/api/v1/device")
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
        _ = try await recorder.waitForCount(3)

        XCTAssertTrue(server.fail(NetworkError.streamEnded))
        let lost = try await recorder.waitForCount(4)
        XCTAssertEqual(lost[3], .reconnecting(scope))
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

        let reconnected = try await recorder.waitForCount(5)
        guard case let .battery(battery, _) = reconnected[4] else {
            return XCTFail("expected telemetry after stream reconnect")
        }
        XCTAssertEqual(battery.level, 41)
        await transport.disconnect()
    }

    func testRecoverableStreamLossDoesNotRetireScopeInDeviceSession() async throws {
        let server = FakeRouterServer()
        server.setResponse(data: statusData(), for: "/api/v1/device")
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
        XCTAssertTrue(server.pushPayload(snapshotData(level: 41)))
        try await states.waitUntil { $0.connection == .live && $0.battery?.level == 41 }
        await transport.disconnect()
        try await states.waitUntil { $0.connection == .disconnected }
    }

    func testSubsequentTelemetryDoesNotClearDeviceSessionOperationError() async throws {
        let server = FakeRouterServer()
        server.setResponse(data: statusData(), for: "/api/v1/device")
        let transport = makeTransport(server: server)
        addTeardownBlock { await transport.disconnect() }
        let session = DeviceSession(transport: transport, clock: sessionClock())
        let states = DeviceStateRecorder(stream: session.states)
        let scope = await transport.makeConnectionScope(for: endpoint.peripheralID)
        await session.start()

        try await transport.connect(to: endpoint.peripheralID, scope: scope)
        try await server.waitForEventStreamCount(1)
        XCTAssertTrue(server.pushPayload(snapshotData(level: 40)))
        try await states.waitUntil { $0.connection == .live && $0.battery?.level == 40 }

        do {
            _ = try await session.perform(DeviceCommand.runningMode(.factory))
            XCTFail("expected unsupported raw command")
        } catch {}
        let stateAfterError = await session.state
        let operationError = try XCTUnwrap(stateAfterError.lastError)

        XCTAssertTrue(server.pushPayload(snapshotData(level: 41)))
        try await states.waitUntil { $0.connection == .live && $0.battery?.level == 41 }
        let stateAfterTelemetry = await session.state
        XCTAssertEqual(stateAfterTelemetry.lastError, operationError)
    }

    func testConnectedFalseSnapshotReconnectsBeforeLaterTelemetryRestoresLive() async throws {
        let server = FakeRouterServer()
        server.setResponse(data: statusData(), for: "/api/v1/device")
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
        let restored = try await recorder.waitForCount(4)
        guard case let .battery(battery, _) = restored[3] else {
            return XCTFail("expected telemetry after connected=false reconnect")
        }
        XCTAssertEqual(battery.level, 42)
        await transport.disconnect()
    }

    func testReconnectBackoffCapsAtLastConfiguredDelay() async throws {
        let server = FakeRouterServer()
        server.setResponse(data: statusData(), for: "/api/v1/device")
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

    func testSuccessfulReplacementRetiresEstablishedScopeBeforeCommittingNewScopeInDeviceSession() async throws {
        let client = GatedStatusClient(data: statusData())
        let streams = LeakyEventStream()
        let transport = replacementTransport(client: client, streams: streams)
        addTeardownBlock { await transport.disconnect() }
        let session = DeviceSession(transport: transport, clock: sessionClock())
        let states = DeviceStateRecorder(stream: session.states)
        let firstScope = await transport.makeConnectionScope(for: endpoint.peripheralID)
        await session.start()

        try await establish(
            transport: transport,
            streams: streams,
            scope: firstScope,
            level: 11,
            states: states
        )

        await client.gateNextStatusRequest()
        let secondScope = await transport.makeConnectionScope(for: endpoint.peripheralID)
        let endpointID = endpoint.peripheralID
        let replacement = Task {
            try await transport.connect(to: endpointID, scope: secondScope)
        }
        await client.waitForGatedRequest()

        XCTAssertFalse(streams.pushPayload(snapshotData(level: 22), to: 0))
        try await states.waitUntil { $0.connection == .disconnected }

        await client.releaseGatedRequest()
        try await replacement.value
        await streams.waitForStreamCount(2)
        XCTAssertTrue(streams.pushPayload(snapshotData(level: 33), to: 1))
        try await states.waitUntil { $0.connection == .live && $0.battery?.level == 33 }

        await transport.disconnect()
        try await waitUntil(session: session) {
            $0.connection == .disconnected && $0.battery?.level == 33
        }
    }

    func testDecodedFrameCannotPublishAfterReplacementRetiresItsScope() async throws {
        let client = GatedStatusClient(data: statusData())
        let streams = LeakyEventStream()
        let gate = PreSnapshotYieldGate()
        let transport = RouterTransport(
            endpoint: endpoint,
            credentials: credentials,
            client: client,
            events: streams,
            clock: TestRouterClock(now: .seconds(70), origin: origin),
            backoff: RouterReconnectBackoff(delays: [.seconds(1)]),
            beforeSnapshotYield: { await gate.waitIfArmed() }
        )
        addTeardownBlock { await transport.disconnect() }
        let session = DeviceSession(transport: transport, clock: sessionClock())
        let states = DeviceStateRecorder(stream: session.states)
        let firstScope = await transport.makeConnectionScope(for: endpoint.peripheralID)
        await session.start()

        try await establish(
            transport: transport,
            streams: streams,
            scope: firstScope,
            level: 11,
            states: states
        )

        await gate.arm()
        XCTAssertTrue(streams.pushPayload(snapshotData(level: 22), to: 0))
        await gate.waitUntilEntered()

        let secondScope = await transport.makeConnectionScope(for: endpoint.peripheralID)
        try await transport.connect(to: endpoint.peripheralID, scope: secondScope)
        try await states.waitUntil { $0.connection == .disconnected }
        await streams.waitForStreamCount(2)

        await gate.release()
        await gate.waitUntilExited()
        let staleFrameWasApplied = await waitForCondition {
            states.values.contains { $0.connection == .live && $0.battery?.level == 22 }
        }
        XCTAssertFalse(staleFrameWasApplied)

        XCTAssertTrue(streams.pushPayload(snapshotData(level: 33), to: 1))
        try await states.waitUntil { $0.connection == .live && $0.battery?.level == 33 }
        let firstDisconnect = try XCTUnwrap(states.values.firstIndex { $0.connection == .disconnected })
        XCTAssertFalse(states.values.dropFirst(firstDisconnect).contains {
            $0.connection == .live && $0.battery?.level == 22
        })
    }

    func testFailedReplacementLeavesDeviceSessionDisconnectedWithoutNewScopeLifecycle() async throws {
        let client = GatedStatusClient(data: statusData())
        let streams = LeakyEventStream()
        let transport = replacementTransport(client: client, streams: streams)
        addTeardownBlock { await transport.disconnect() }
        let session = DeviceSession(transport: transport, clock: sessionClock())
        let states = DeviceStateRecorder(stream: session.states)
        let firstScope = await transport.makeConnectionScope(for: endpoint.peripheralID)
        await session.start()

        try await establish(
            transport: transport,
            streams: streams,
            scope: firstScope,
            level: 44,
            states: states
        )

        await client.gateNextStatusRequest()
        await client.failNextStatusRequest(with: .timeout)
        let secondScope = await transport.makeConnectionScope(for: endpoint.peripheralID)
        let endpointID = endpoint.peripheralID
        let replacement = Task {
            try await transport.connect(to: endpointID, scope: secondScope)
        }
        await client.waitForGatedRequest()

        try await states.waitUntil { $0.connection == .disconnected }
        await client.releaseGatedRequest()

        do {
            try await replacement.value
            XCTFail("expected replacement status failure")
        } catch {
            XCTAssertEqual(error as? NetworkError, .timeout)
        }
        let finalState = await session.state
        XCTAssertEqual(finalState.connection, .disconnected)
    }

    func testCallerCancelledReplacementLeavesDeviceSessionDisconnectedWithoutNewScopeLifecycle() async throws {
        let client = GatedStatusClient(data: statusData())
        let streams = LeakyEventStream()
        let transport = replacementTransport(client: client, streams: streams)
        addTeardownBlock { await transport.disconnect() }
        let session = DeviceSession(transport: transport, clock: sessionClock())
        let states = DeviceStateRecorder(stream: session.states)
        let firstScope = await transport.makeConnectionScope(for: endpoint.peripheralID)
        await session.start()

        try await establish(
            transport: transport,
            streams: streams,
            scope: firstScope,
            level: 45,
            states: states
        )

        await client.gateNextStatusRequest()
        let secondScope = await transport.makeConnectionScope(for: endpoint.peripheralID)
        let endpointID = endpoint.peripheralID
        let replacement = Task {
            try await transport.connect(to: endpointID, scope: secondScope)
        }
        await client.waitForGatedRequest()

        try await states.waitUntil { $0.connection == .disconnected }
        replacement.cancel()
        await client.releaseGatedRequest()

        await assertCancellation(of: replacement)
        let finalState = await session.state
        XCTAssertEqual(finalState.connection, .disconnected)
    }

    func testExplicitDisconnectWhileReplacementPendingRetiresOnlyEstablishedScopeInDeviceSession() async throws {
        let client = GatedStatusClient(data: statusData())
        let streams = LeakyEventStream()
        let transport = replacementTransport(client: client, streams: streams)
        addTeardownBlock { await transport.disconnect() }
        let session = DeviceSession(transport: transport, clock: sessionClock())
        let states = DeviceStateRecorder(stream: session.states)
        let firstScope = await transport.makeConnectionScope(for: endpoint.peripheralID)
        await session.start()

        try await establish(
            transport: transport,
            streams: streams,
            scope: firstScope,
            level: 46,
            states: states
        )

        await client.gateNextStatusRequest()
        let secondScope = await transport.makeConnectionScope(for: endpoint.peripheralID)
        let endpointID = endpoint.peripheralID
        let replacement = Task {
            try await transport.connect(to: endpointID, scope: secondScope)
        }
        await client.waitForGatedRequest()

        try await states.waitUntil { $0.connection == .disconnected }
        await transport.disconnect()

        await client.releaseGatedRequest()
        await assertCancellation(of: replacement)
        XCTAssertEqual(streams.streamCount, 1)
        let finalState = await session.state
        XCTAssertEqual(finalState.connection, .disconnected)
    }

    func testExplicitDisconnectWhileReplacementPendingEmitsOnlyEstablishedScopeTerminalEvent() async throws {
        let client = GatedStatusClient(data: statusData())
        let streams = LeakyEventStream()
        let transport = replacementTransport(client: client, streams: streams)
        addTeardownBlock { await transport.disconnect() }
        let recorder = DeviceEventRecorder(stream: transport.events)
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
        _ = try await recorder.waitForCount(3)

        await transport.disconnect()
        await client.releaseGatedRequest()
        await assertCancellation(of: replacement)
        for _ in 0..<100 { await Task.yield() }

        let disconnectedScopes = recorder.snapshot.compactMap { event -> DeviceConnectionScope? in
            guard case let .disconnected(scope, _) = event else { return nil }
            return scope
        }
        XCTAssertEqual(disconnectedScopes, [firstScope])
    }

    func testCallerCancellationAfterStatusAwaitDoesNotCommitLifecycle() async throws {
        let server = FakeRouterServer()
        server.setResponse(data: statusData(), for: "/api/v1/device")
        let output = AsyncStream<DeviceEvent>.makeStream()
        let recorder = DeviceEventRecorder(stream: output.stream)
        let gate = PostStatusAwaitGate()
        let connection = RouterConnection(
            endpoint: endpoint,
            credentials: credentials,
            client: server,
            events: server,
            clock: TestRouterClock(now: .zero, origin: origin),
            backoff: RouterReconnectBackoff(delays: [.seconds(1)]),
            output: output.continuation,
            afterStatusAwait: { await gate.wait() }
        )
        let scope = await connection.makeConnectionScope()
        let endpointID = endpoint.peripheralID
        let connect = Task {
            try await connection.connect(to: endpointID, scope: scope)
        }
        await gate.waitUntilEntered()

        connect.cancel()
        await gate.release()

        await assertCancellation(of: connect)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(recorder.count, 0)
        XCTAssertEqual(server.eventStreamCount, 0)
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

    func testCallerCancellationRemainsCancellationWhenHTTPClientThrowsURLCancelled() async {
        let client = URLSessionLikeCancellationClient()
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
        await client.waitUntilStarted()

        connection.cancel()

        await assertCancellation(of: connection)
    }

    func testURLTimeoutMapsToNetworkTimeout() async {
        let transport = makeTransport(client: URLFailureHTTPClient(code: .timedOut))
        let scope = await transport.makeConnectionScope(for: endpoint.peripheralID)

        do {
            try await transport.connect(to: endpoint.peripheralID, scope: scope)
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? NetworkError, .timeout)
        }
    }

    func testOtherURLErrorsMapToTransportFailureInsteadOfDecode() async {
        let code = URLError.notConnectedToInternet
        let transport = makeTransport(client: URLFailureHTTPClient(code: code))
        let scope = await transport.makeConnectionScope(for: endpoint.peripheralID)

        do {
            try await transport.connect(to: endpoint.peripheralID, scope: scope)
            XCTFail("expected transport failure")
        } catch {
            XCTAssertEqual(
                error as? NetworkError,
                .transport("URL error \(code.rawValue)")
            )
        }
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
        server.setResponse(data: statusData(), for: "/api/v1/device")
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

    func testManualScanIsNoOpAndCommandsRequireAConnection() async throws {
        let transport = makeTransport(server: FakeRouterServer())

        try await transport.startScan()
        await transport.stopScan()
        do {
            _ = try await transport.perform(DeviceCommand.setDC(true))
            XCTFail("expected disconnected command failure")
        } catch {
            XCTAssertEqual(error as? NetworkError, .transport("Router device is not connected"))
        }
    }

    func testEstablishedStreamUnauthorizedIsTerminalInsteadOfRetryingForever() async throws {
        let server = FakeRouterServer()
        server.setResponse(data: statusData(), for: "/api/v1/device")
        let clock = TestRouterClock(now: .seconds(50), origin: origin)
        let transport = makeTransport(server: server, clock: clock)
        let recorder = DeviceEventRecorder(stream: transport.events)
        let scope = await transport.makeConnectionScope(for: endpoint.peripheralID)
        try await transport.connect(to: endpoint.peripheralID, scope: scope)
        try await server.waitForEventStreamCount(1)

        server.setResponse(data: Data(), statusCode: 401, for: "/api/v1/events")
        XCTAssertTrue(server.fail(NetworkError.streamEnded))
        await clock.waitForSleepCount(1)
        await clock.advance(by: .seconds(1))

        let events = try await recorder.waitForCount(4)
        XCTAssertEqual(events[2], .reconnecting(scope))
        guard case let .disconnected(disconnectedScope, failure) = events[3] else {
            return XCTFail("expected terminal authorization event")
        }
        XCTAssertEqual(disconnectedScope, scope)
        XCTAssertEqual(failure?.message, "Router authorization expired")
        for _ in 0..<100 { await Task.yield() }
        let sleepCount = await clock.sleepDurations.count
        XCTAssertEqual(sleepCount, 1, "401 must not enter an infinite retry loop")
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

    private func makeTransport(client: any RouterHTTPClient) -> RouterTransport {
        RouterTransport(
            endpoint: endpoint,
            credentials: credentials,
            client: client,
            events: FakeRouterServer(),
            clock: TestRouterClock(now: .zero, origin: origin),
            backoff: RouterReconnectBackoff(delays: [.seconds(1)])
        )
    }

    private func replacementTransport(
        client: GatedStatusClient,
        streams: LeakyEventStream
    ) -> RouterTransport {
        RouterTransport(
            endpoint: endpoint,
            credentials: credentials,
            client: client,
            events: streams,
            clock: TestRouterClock(now: .seconds(70), origin: origin),
            backoff: RouterReconnectBackoff(delays: [.seconds(1)])
        )
    }

    private func sessionClock() -> TestRouterClock {
        TestRouterClock(now: .seconds(70), origin: origin)
    }

    private func establish(
        transport: RouterTransport,
        streams: LeakyEventStream,
        scope: DeviceConnectionScope,
        level: UInt8,
        states: DeviceStateRecorder
    ) async throws {
        try await transport.connect(to: endpoint.peripheralID, scope: scope)
        await streams.waitForStreamCount(1)
        XCTAssertTrue(streams.pushPayload(snapshotData(level: level), to: 0))
        try await states.waitUntil { $0.connection == .live && $0.battery?.level == level }
    }

    private func waitUntil(
        session: DeviceSession,
        predicate: (DeviceState) -> Bool
    ) async throws {
        for _ in 0..<20_000 {
            if predicate(await session.state) { return }
            await Task.yield()
        }
        throw TestProbeError.timedOut("expected current DeviceSession state")
    }

    private func statusData() -> Data {
        Data(#"{"id":"DC:04:5A:EB:72:2B","model":"BP4SL3V2","hardware_revision":"V2","application_firmware":"1.4.9","ota_firmware":"1.0.3","cid":770,"features_raw":16496,"features":{},"available":{"current_time":true,"ota":true,"dc":true,"usbc":true},"mode":"app","connection":{"connected":true,"phase":"ready","reconnect":"armed"},"commands":{"active":[],"recent":[]},"magic_dns_name":"wattline.example.ts.net"}"#.utf8)
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
        server.setResponse(data: Data("status".utf8), statusCode: 200, for: "/api/v1/device")
        server.setResponse(data: Data("events-down".utf8), statusCode: 503, for: "/api/v1/events")

        let (data, response) = try await server.get("/api/v1/device", token: "token")
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
    var snapshot: [DeviceEvent] { lock.withLock { values } }

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

private actor URLSessionLikeCancellationClient: RouterHTTPClient {
    private var started = false

    func get(_ path: String, token: String) async throws -> (Data, HTTPURLResponse) {
        try await request("GET", path, body: nil, token: token)
    }

    func request(
        _ method: String,
        _ path: String,
        body: Data?,
        token: String
    ) async throws -> (Data, HTTPURLResponse) {
        started = true
        do {
            try await Task.sleep(for: .seconds(60))
            throw NetworkError.timeout
        } catch is CancellationError {
            throw URLError(.cancelled)
        }
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }
}

private struct URLFailureHTTPClient: RouterHTTPClient {
    let code: URLError.Code

    func get(_ path: String, token: String) async throws -> (Data, HTTPURLResponse) {
        throw URLError(code)
    }

    func request(
        _ method: String,
        _ path: String,
        body: Data?,
        token: String
    ) async throws -> (Data, HTTPURLResponse) {
        throw URLError(code)
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
    private var nextError: NetworkError?

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
        if let nextError {
            self.nextError = nil
            throw nextError
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
        gatedRequestStarted = false
    }

    func failNextStatusRequest(with error: NetworkError) {
        nextError = error
    }

    func waitForGatedRequest() async {
        while !gatedRequestStarted { await Task.yield() }
    }

    func releaseGatedRequest() {
        gateContinuation?.resume()
        gateContinuation = nil
    }
}

private actor PostStatusAwaitGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor PreSnapshotYieldGate {
    private var armed = false
    private var entered = false
    private var exited = false
    private var continuation: CheckedContinuation<Void, Never>?

    func arm() {
        armed = true
        entered = false
        exited = false
    }

    func waitIfArmed() async {
        guard armed else { return }
        armed = false
        entered = true
        await withCheckedContinuation { continuation = $0 }
        exited = true
    }

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func waitUntilExited() async {
        while !exited { await Task.yield() }
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
