import Foundation
import WattlineCore
import XCTest
@testable import WattlineNetwork

final class RouterCommandMapperTests: XCTestCase {
    private let mapper = RouterCommandMapper()

    func testMapsAllowListedActionsWithTelemetryReconcilers() throws {
        let dc = try mapper.route(for: .setDC(true))
        XCTAssertEqual(dc.method, "POST")
        XCTAssertEqual(dc.path, "/api/v1/device/action")
        XCTAssertEqual(try bodyString(dc, key: "action"), "dc_on")
        XCTAssertEqual(dc.confirmation, .telemetry(.dcEnabled(true), timeout: .seconds(3)))

        let typeC = try mapper.route(for: .setTypeCOutput(false))
        XCTAssertEqual(try bodyString(typeC, key: "action"), "usbc_off")
        XCTAssertEqual(typeC.confirmation, .telemetry(.typeCOutput(false), timeout: .seconds(3)))

        let bypass = try mapper.route(for: .setBypass(true))
        XCTAssertEqual(try bodyString(bypass, key: "action"), "bypass_on")
        XCTAssertEqual(bypass.confirmation, .telemetry(.bypass(true), timeout: .seconds(10)))
        XCTAssertTrue(bypass.ignoresResponseResult)
    }

    func testMapsPowerLimitSetClearAndGetToDocumentedContract() throws {
        let set = try mapper.route(for: .setPowerLimit(.output, level: .watts100))
        XCTAssertEqual(set.method, "POST")
        XCTAssertEqual(set.path, "/api/v1/device/usbc-limit")
        XCTAssertEqual(try bodyString(set, key: "type"), "output")
        XCTAssertEqual(try bodyInt(set, key: "watts"), 100)
        XCTAssertEqual(set.confirmation, .powerLimit(.output))

        let clear = try mapper.route(for: .clearPowerLimit(.input))
        XCTAssertEqual(try bodyString(clear, key: "type"), "input")
        XCTAssertEqual(try bodyBool(clear, key: "clear"), true)
        XCTAssertEqual(clear.confirmation, .powerLimit(.input))

        let get = try mapper.route(for: .getPowerLimit(.runtime))
        XCTAssertEqual(get.method, "GET")
        XCTAssertNil(get.body)
        XCTAssertEqual(get.confirmation, .powerLimit(.runtime))
    }

    func testRestartAndShutdownAreAllowListedButRawCommandsAreUnsupported() throws {
        let restart = try mapper.route(for: .restart)
        XCTAssertEqual(try bodyString(restart, key: "action"), "restart")
        XCTAssertEqual(restart.confirmation, .disconnect(.successThenReconnect))

        let shutdown = try mapper.route(for: .shutdown)
        XCTAssertEqual(try bodyString(shutdown, key: "action"), "shutdown")
        XCTAssertEqual(shutdown.confirmation, .disconnect(.successThenDisarmReconnect))

        for command in [DeviceCommand.enterOTA, .runningMode(.factory)] {
            XCTAssertThrowsError(try mapper.route(for: command)) { error in
                guard case .unsupported = error as? NetworkError else {
                    return XCTFail("expected unsupported, received \(error)")
                }
            }
        }
    }

    func testEveryAdvertisedSurfaceHasARouterRoute() throws {
        let features: FeatureFlags = [
            .dcControl, .usbOutputControl, .usbPowerLimit,
            .dcBypassControl, .dcScheduler, .shutdown,
        ]
        let capabilities = RouterCapabilities(
            features: features.rawValue,
            endpoints: [.actions, .usbCLimit, .bypassThreshold, .schedules]
        )

        for surface in capabilities.supportedSurfaces {
            switch surface {
            case .dcControl:
                _ = try mapper.route(for: .setDC(true))
            case .typeCOutput:
                _ = try mapper.route(for: .setTypeCOutput(true))
            case .powerLimits:
                _ = try mapper.route(for: .setPowerLimit(.output, level: .watts100))
            case .bypassControl:
                _ = try mapper.route(for: .setBypass(true))
            case .bypassThreshold:
                _ = try mapper.setBypassThreshold(volts: 19.6)
            case .schedules:
                _ = mapper.listSchedules()
            case .restart:
                _ = try mapper.route(for: .restart)
            case .shutdown:
                _ = try mapper.route(for: .shutdown)
            }
        }
    }

    func testMapsBypassThresholdAndScheduleRoutes() throws {
        let threshold = try mapper.setBypassThreshold(volts: 19.6)
        XCTAssertEqual(threshold.path, "/api/v1/device/bypass-threshold")
        XCTAssertEqual(try bodyDouble(threshold, key: "volts"), 19.6, accuracy: 0.0001)
        XCTAssertEqual(threshold.confirmation, .bypassThreshold(19.6))

        let schedule = RouterSchedule(
            id: nil,
            status: 1,
            type: 1,
            hour: 22,
            minute: 30,
            repeatMask: 0,
            action: 0
        )
        let add = try mapper.upsertSchedule(schedule)
        XCTAssertEqual(add.method, "POST")
        XCTAssertEqual(add.path, "/api/v1/device/schedules")
        XCTAssertEqual(try bodyInt(add, key: "hour"), 22)
        XCTAssertEqual(add.confirmation, .scheduleMutation)

        XCTAssertEqual(mapper.listSchedules().path, "/api/v1/device/schedules")
        XCTAssertEqual(try mapper.deleteSchedule(id: 7).path, "/api/v1/device/schedules/7")
    }

    private func body(_ request: RouterRequest) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any] ?? [:]
    }

    private func bodyString(_ request: RouterRequest, key: String) throws -> String {
        try XCTUnwrap(body(request)[key] as? String)
    }

    private func bodyInt(_ request: RouterRequest, key: String) throws -> Int {
        try XCTUnwrap(body(request)[key] as? Int)
    }

    private func bodyBool(_ request: RouterRequest, key: String) throws -> Bool {
        try XCTUnwrap(body(request)[key] as? Bool)
    }

    private func bodyDouble(_ request: RouterRequest, key: String) throws -> Double {
        try XCTUnwrap(body(request)[key] as? Double)
    }
}

final class RouterCommandExecutionTests: XCTestCase {
    private let endpoint = RouterEndpoint(
        scheme: "http",
        host: "router.local",
        port: 8377,
        certificateFingerprint: nil,
        allowsInsecureWAN: false
    )
    private let credentials = TransientRouterCredentialProvider(token: "command-token")
    private let origin = RouterTimestampOrigin(
        wallClock: Date(timeIntervalSince1970: 1_752_739_200),
        deviceTimestamp: .seconds(40)
    )

    func testDCAcknowledgementDoesNotCompleteUntilMatchingTelemetry() async throws {
        let server = commandServer()
        let transport = makeTransport(server)
        try await connect(transport, server)
        let completion = CommandCompletionProbe()

        let command = Task {
            let outcome = try await transport.perform(.setDC(true))
            await completion.finish(outcome)
            return outcome
        }
        try await server.waitForRequest(method: "POST", path: "/api/v1/device/action")
        let finishedAfterAck = await completion.isFinished
        XCTAssertFalse(finishedAfterAck)
        XCTAssertTrue(server.push(snapshot(dcEnabled: false)))
        for _ in 0..<100 { await Task.yield() }
        let finishedAfterMismatch = await completion.isFinished
        XCTAssertFalse(finishedAfterMismatch)

        XCTAssertTrue(server.push(snapshot(dcEnabled: true)))
        let outcome = try await command.value
        XCTAssertEqual(outcome, .sent)
    }

    func testTypeCReconcilesFromModeNotEnabled() async throws {
        let server = commandServer()
        let transport = makeTransport(server)
        try await connect(transport, server)
        let completion = CommandCompletionProbe()

        let command = Task {
            let outcome = try await transport.perform(.setTypeCOutput(false))
            await completion.finish(outcome)
            return outcome
        }
        try await server.waitForRequest(method: "POST", path: "/api/v1/device/action")
        XCTAssertTrue(server.push(snapshot(typeCEnabled: true, mode: 3)))
        for _ in 0..<100 { await Task.yield() }
        let finishedFromEnabled = await completion.isFinished
        XCTAssertFalse(finishedFromEnabled, "enabled=true must not confirm output-off")

        XCTAssertTrue(server.push(snapshot(typeCEnabled: true, mode: 1)))
        let outcome = try await command.value
        XCTAssertEqual(outcome, .sent)
    }

    func testBypassIgnoresHTTPResultButRequiresTelemetry() async throws {
        let server = commandServer()
        server.enqueue(method: "POST", path: "/api/v1/device/action", statusCode: 502, body: #"{"error":"device result fd"}"#)
        let transport = makeTransport(server)
        try await connect(transport, server)
        let completion = CommandCompletionProbe()

        let command = Task {
            let outcome = try await transport.perform(.setBypass(true))
            await completion.finish(outcome)
            return outcome
        }
        try await server.waitForRequest(method: "POST", path: "/api/v1/device/action")
        let finishedAfterErrorResponse = await completion.isFinished
        XCTAssertFalse(finishedAfterErrorResponse)
        XCTAssertTrue(server.push(snapshot(dcEnabled: true, bypass: false)))
        for _ in 0..<100 { await Task.yield() }
        let finishedAfterMismatch = await completion.isFinished
        XCTAssertFalse(finishedAfterMismatch)

        XCTAssertTrue(server.push(snapshot(dcEnabled: true, bypass: true)))
        let outcome = try await command.value
        XCTAssertEqual(outcome, .sent)
    }

    func testPowerLimitSetAndClearPerformPOSTThenGETAndReturnConfirmedLevel() async throws {
        let server = commandServer()
        server.enqueue(method: "POST", path: "/api/v1/device/usbc-limit", body: #"{"watts":100,"level":4}"#)
        server.enqueue(method: "GET", path: "/api/v1/device/usbc-limit", body: limitResponse(outputLevel: 4))
        let transport = makeTransport(server)
        try await connect(transport, server)

        let set = try await transport.perform(.setPowerLimit(.output, level: .watts100))
        XCTAssertEqual(replyLevel(set), 4)
        XCTAssertEqual(
            server.requests.filter { $0.path == "/api/v1/device/usbc-limit" }.map(\.method),
            ["POST", "GET"]
        )

        server.enqueue(method: "POST", path: "/api/v1/device/usbc-limit", body: #"{"status":"cleared"}"#)
        server.enqueue(method: "GET", path: "/api/v1/device/usbc-limit", body: limitResponse(outputLevel: 3))
        let clear = try await transport.perform(.clearPowerLimit(.output))
        XCTAssertEqual(replyLevel(clear), 3)
        XCTAssertEqual(
            server.requests.filter { $0.path == "/api/v1/device/usbc-limit" }.map(\.method),
            ["POST", "GET", "POST", "GET"]
        )
    }

    func testBypassThresholdAndSchedulesUseDocumentedRoutes() async throws {
        let server = commandServer()
        server.enqueue(method: "POST", path: "/api/v1/device/bypass-threshold", body: #"{"volts":19.6}"#)
        server.enqueue(method: "GET", path: "/api/v1/device/bypass-threshold", body: #"{"volts":19.6}"#)
        server.enqueue(method: "GET", path: "/api/v1/device/schedules", body: #"[{"id":0,"status":1,"type":1,"hour":3,"minute":0,"repeat":0,"action":1}]"#)
        server.enqueue(method: "POST", path: "/api/v1/device/schedules", body: #"{"id":3,"status":1,"type":1,"hour":6,"minute":30,"repeat":0,"action":1}"#)
        server.enqueue(method: "DELETE", path: "/api/v1/device/schedules/3", body: #"{"status":"deleted"}"#)
        let transport = makeTransport(server)
        try await connect(transport, server)

        let threshold = try await transport.setBypassThreshold(19.6)
        XCTAssertEqual(threshold, 19.6, accuracy: 0.0001)
        let schedules = try await transport.schedules()
        XCTAssertEqual(schedules.map(\.id), [0])
        let added = try await transport.upsertSchedule(RouterSchedule(
            id: nil, status: 1, type: 1, hour: 6, minute: 30, repeatMask: 0, action: 1
        ))
        XCTAssertEqual(added.id, 3)
        try await transport.deleteSchedule(id: 3)
    }

    func testRouterErrorsAndUnsupportedCommandsAreClear() async throws {
        let server = commandServer()
        server.enqueue(method: "POST", path: "/api/v1/device/action", statusCode: 502, body: "router command failed")
        let transport = makeTransport(server)
        try await connect(transport, server)

        do {
            _ = try await transport.perform(.setDC(true))
            XCTFail("expected router error")
        } catch {
            XCTAssertEqual(error as? NetworkError, .httpStatus(502, "router command failed"))
        }
        do {
            _ = try await transport.perform(.runningMode(.factory))
            XCTFail("expected unsupported raw command")
        } catch {
            guard case .unsupported = error as? NetworkError else {
                return XCTFail("expected unsupported, received \(error)")
            }
        }
    }

    func testRestartUsesRouterDisconnectAsSuccessContract() async throws {
        let server = commandServer()
        let transport = makeTransport(server)
        try await connect(transport, server)

        let outcome = try await transport.perform(.restart)
        XCTAssertEqual(outcome, .sent)
        let action = try XCTUnwrap(server.requests.last)
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(action.body)) as? [String: String]
        XCTAssertEqual(body?["action"], "restart")
    }

    func testShutdownRetiresConnectionWithoutReconnectingOrResubscribing() async throws {
        let server = commandServer()
        let clock = ControlledCommandClock(origin: origin)
        let transport = RouterTransport(
            endpoint: endpoint,
            credentials: credentials,
            client: server,
            events: server,
            clock: clock,
            backoff: RouterReconnectBackoff(delays: [.seconds(1)])
        )
        let recorder = CommandEventRecorder(transport.events)
        let scope = await transport.makeConnectionScope(for: endpoint.peripheralID)
        try await transport.connect(to: endpoint.peripheralID, scope: scope)
        try await server.waitForEventStream()
        addTeardownBlock { await transport.disconnect() }

        let outcome = try await transport.perform(.shutdown)
        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(server.eventStreamCount, 1)

        XCTAssertTrue(server.push(Data(#"{"connected":false}"#.utf8)))
        try await recorder.waitUntil { $0 == .disconnected(scope, nil) }
        XCTAssertFalse(recorder.events.contains(.reconnecting(scope)))

        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(server.eventStreamCount, 1)
    }

    func testRestartWriteErrorWhileStreamDisconnectsIsSuccess() async throws {
        let client = GatedRestartHTTPClient(status: statusBody())
        let events = CommandRouterServer()
        let transport = RouterTransport(
            endpoint: endpoint,
            credentials: credentials,
            client: client,
            events: events,
            clock: CommandTestClock(origin: origin),
            backoff: RouterReconnectBackoff(delays: [.seconds(1)])
        )
        let recorder = CommandEventRecorder(transport.events)
        let scope = await transport.makeConnectionScope(for: endpoint.peripheralID)
        try await transport.connect(to: endpoint.peripheralID, scope: scope)
        try await events.waitForEventStream()
        addTeardownBlock { await transport.disconnect() }

        let restart = Task { try await transport.perform(.restart) }
        await client.waitUntilRestartStarted()
        XCTAssertTrue(events.push(Data(#"{"connected":false}"#.utf8)))
        try await recorder.waitUntil { $0 == .reconnecting(scope) }
        await client.releaseWithDisconnectError()

        let outcome = try await restart.value
        XCTAssertEqual(outcome, .sent)
    }

    func testRestartWriteErrorBeforeStreamDisconnectStillSucceedsWithinGrace() async throws {
        let client = GatedRestartHTTPClient(status: statusBody())
        let events = CommandRouterServer()
        let clock = ControlledCommandClock(origin: origin)
        let transport = RouterTransport(
            endpoint: endpoint,
            credentials: credentials,
            client: client,
            events: events,
            clock: clock,
            backoff: RouterReconnectBackoff(delays: [.seconds(1)])
        )
        let recorder = CommandEventRecorder(transport.events)
        let scope = await transport.makeConnectionScope(for: endpoint.peripheralID)
        try await transport.connect(to: endpoint.peripheralID, scope: scope)
        try await events.waitForEventStream()
        addTeardownBlock { await transport.disconnect() }

        let restart = Task { try await transport.perform(.restart) }
        await client.waitUntilRestartStarted()
        await client.releaseWithDisconnectError()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertTrue(events.push(Data(#"{"connected":false}"#.utf8)))
        try await recorder.waitUntil { $0 == .reconnecting(scope) }

        let outcome = try await restart.value
        XCTAssertEqual(outcome, .sent)
        let requestedSleeps = await clock.requestedSleeps
        XCTAssertEqual(requestedSleeps.first, .seconds(2))
    }

    func testCommandCancellationMapsURLCancelledAndLateTelemetryIsSafe() async throws {
        let client = CommandCancellationHTTPClient(status: statusBody())
        let events = CommandRouterServer()
        let transport = RouterTransport(
            endpoint: endpoint,
            credentials: credentials,
            client: client,
            events: events,
            clock: CommandTestClock(origin: origin),
            backoff: RouterReconnectBackoff(delays: [.seconds(1)])
        )
        let scope = await transport.makeConnectionScope(for: endpoint.peripheralID)
        try await transport.connect(to: endpoint.peripheralID, scope: scope)
        try await events.waitForEventStream()
        addTeardownBlock { await transport.disconnect() }

        let command = Task { try await transport.perform(.setDC(true)) }
        await client.waitUntilCommandStarted()
        command.cancel()

        do {
            _ = try await command.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, received \(error)")
        }
        XCTAssertTrue(events.push(snapshot(dcEnabled: true)))
    }

    func testInjectedClockTimeoutCleansWaiterAndLateTelemetryCannotCompleteSuccessor() async throws {
        let server = commandServer()
        let clock = ControlledCommandClock(origin: origin)
        let transport = RouterTransport(
            endpoint: endpoint,
            credentials: credentials,
            client: server,
            events: server,
            clock: clock,
            backoff: RouterReconnectBackoff(delays: [.seconds(1)])
        )
        let scope = await transport.makeConnectionScope(for: endpoint.peripheralID)
        try await transport.connect(to: endpoint.peripheralID, scope: scope)
        try await server.waitForEventStream()
        addTeardownBlock { await transport.disconnect() }

        let timedOut = Task { try await transport.perform(.setDC(true)) }
        try await server.waitForRequestCount(method: "POST", path: "/api/v1/device/action", count: 1)
        await clock.waitForSleepCount(1)
        let firstSleeps = await clock.requestedSleeps
        guard firstSleeps == [.seconds(3)] else {
            timedOut.cancel()
            return XCTFail("reconciliation timeout bypassed injected clock: \(firstSleeps)")
        }
        await clock.advanceNext()
        do {
            _ = try await timedOut.value
            XCTFail("expected reconciliation timeout")
        } catch {
            XCTAssertEqual(error as? NetworkError, .timeout)
        }

        XCTAssertTrue(server.push(snapshot(dcEnabled: true)), "late telemetry remains publishable")
        let successor = Task { try await transport.perform(.setDC(false)) }
        try await server.waitForRequestCount(method: "POST", path: "/api/v1/device/action", count: 2)
        await clock.waitForSleepCount(2)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertTrue(server.push(snapshot(dcEnabled: false)))
        let successorOutcome = try await successor.value
        XCTAssertEqual(successorOutcome, .sent)
    }

    func testTelemetryBeforeInjectedClockTimeoutCompletesAndCancelsSleeper() async throws {
        let server = commandServer()
        let clock = ControlledCommandClock(origin: origin)
        let transport = RouterTransport(
            endpoint: endpoint,
            credentials: credentials,
            client: server,
            events: server,
            clock: clock,
            backoff: RouterReconnectBackoff(delays: [.seconds(1)])
        )
        let scope = await transport.makeConnectionScope(for: endpoint.peripheralID)
        try await transport.connect(to: endpoint.peripheralID, scope: scope)
        try await server.waitForEventStream()
        addTeardownBlock { await transport.disconnect() }

        let command = Task { try await transport.perform(.setDC(true)) }
        try await server.waitForRequestCount(method: "POST", path: "/api/v1/device/action", count: 1)
        await clock.waitForSleepCount(1)
        let requestedSleeps = await clock.requestedSleeps
        guard requestedSleeps == [.seconds(3)] else {
            command.cancel()
            return XCTFail("reconciliation timeout bypassed injected clock: \(requestedSleeps)")
        }
        XCTAssertTrue(server.push(snapshot(dcEnabled: true)))

        let outcome = try await command.value
        XCTAssertEqual(outcome, .sent)
        await clock.waitForActiveSleepCount(0)
        let activeSleepCount = await clock.activeSleepCount
        XCTAssertEqual(activeSleepCount, 0)
    }

    func testRefreshCompletingAfterReplacementPublishesNoStaleTelemetry() async throws {
        let client = GatedRefreshHTTPClient(status: statusBody(), telemetry: snapshot(dcEnabled: true))
        let events = CommandRouterServer()
        let transport = RouterTransport(
            endpoint: endpoint,
            credentials: credentials,
            client: client,
            events: events,
            clock: CommandTestClock(origin: origin),
            backoff: RouterReconnectBackoff(delays: [.seconds(1)])
        )
        let recorder = CommandEventRecorder(transport.events)
        let first = await transport.makeConnectionScope(for: endpoint.peripheralID)
        try await transport.connect(to: endpoint.peripheralID, scope: first)
        try await events.waitForEventStream()
        addTeardownBlock { await transport.disconnect() }

        let refresh = Task { try await transport.refreshTelemetry() }
        await client.waitUntilRefreshStarted()
        let second = await transport.makeConnectionScope(for: endpoint.peripheralID)
        try await transport.connect(to: endpoint.peripheralID, scope: second)
        await client.releaseRefresh()

        do {
            try await refresh.value
            XCTFail("expected stale refresh cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, received \(error)")
        }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertFalse(recorder.events.contains { if case .dc = $0 { true } else { false } })
    }

    private func commandServer() -> CommandRouterServer {
        let server = CommandRouterServer()
        server.enqueue(method: "GET", path: "/api/v1/device", body: String(decoding: statusBody(), as: UTF8.self))
        return server
    }

    private func statusBody() -> Data {
        Data(#"{"id":"DC:04:5A:EB:72:2B","model":"BP4SL3V2","hardware_revision":"V2","application_firmware":"1.4.9","ota_firmware":"1.0.3","cid":770,"features_raw":16496,"features":{},"available":{"current_time":true,"ota":true,"dc":true,"usbc":true},"mode":"app","connection":{"connected":true,"phase":"ready","reconnect":"armed"},"commands":{"active":[],"recent":[]},"magic_dns_name":"wattline.example.ts.net"}"#.utf8)
    }

    private func makeTransport(_ server: CommandRouterServer) -> RouterTransport {
        RouterTransport(
            endpoint: endpoint,
            credentials: credentials,
            client: server,
            events: server,
            clock: CommandTestClock(origin: origin),
            backoff: RouterReconnectBackoff(delays: [.seconds(1)])
        )
    }

    private func connect(_ transport: RouterTransport, _ server: CommandRouterServer) async throws {
        let scope = await transport.makeConnectionScope(for: endpoint.peripheralID)
        try await transport.connect(to: endpoint.peripheralID, scope: scope)
        try await server.waitForEventStream()
        addTeardownBlock { await transport.disconnect() }
    }

    private func snapshot(dcEnabled: Bool, bypass: Bool = false) -> Data {
        Data(#"{"connected":true,"dc":{"enabled":\#(dcEnabled),"status":0,"volts":20,"amps":0,"watts":0,"bypass":\#(bypass)}}"#.utf8)
    }

    private func snapshot(typeCEnabled: Bool, mode: UInt8) -> Data {
        Data(#"{"connected":true,"typec":{"enabled":\#(typeCEnabled),"status":0,"volts":20,"amps":0,"watts":0,"temp_c":25,"mode":\#(mode),"dc_input":false}}"#.utf8)
    }

    private func limitResponse(outputLevel: Int) -> String {
        #"{"global":{"level":3,"watts":65},"input":{"level":3,"watts":65},"output":{"level":\#(outputLevel),"watts":100},"runtime":{"level":-1,"watts":0}}"#
    }

    private func replyLevel(_ outcome: CommandOutcome) -> UInt8? {
        guard case let .reply(reply) = outcome else { return nil }
        return reply.payload.first
    }
}

private final class CommandRouterServer: RouterHTTPClient, RouterEventStream, @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let body: Data?
        let token: String
    }

    private struct Response {
        let statusCode: Int
        let body: Data
    }

    private let lock = NSLock()
    private var queued: [String: [Response]] = [:]
    private var storedRequests: [Request] = []
    private var eventContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var storedEventStreamCount = 0

    var requests: [Request] { lock.withLock { storedRequests } }
    var eventStreamCount: Int { lock.withLock { storedEventStreamCount } }

    func enqueue(method: String, path: String, statusCode: Int = 200, body: String = #"{"ok":true}"#) {
        lock.withLock {
            queued["\(method) \(path)", default: []].append(Response(statusCode: statusCode, body: Data(body.utf8)))
        }
    }

    func get(_ path: String, token: String) async throws -> (Data, HTTPURLResponse) {
        try await request("GET", path, body: nil, token: token)
    }

    func request(_ method: String, _ path: String, body: Data?, token: String) async throws -> (Data, HTTPURLResponse) {
        let response: Response = lock.withLock {
            storedRequests.append(Request(method: method, path: path, body: body, token: token))
            let key = "\(method) \(path)"
            if var values = queued[key], !values.isEmpty {
                let first = values.removeFirst()
                queued[key] = values
                return first
            }
            return Response(statusCode: 200, body: Data(#"{"ok":true}"#.utf8))
        }
        return (
            response.body,
            HTTPURLResponse(
                url: URL(string: "http://router.local\(path)")!,
                statusCode: response.statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }

    func events(path: String, token: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock {
                storedEventStreamCount += 1
                eventContinuation = continuation
            }
        }
    }

    func push(_ payload: Data) -> Bool {
        guard let continuation = lock.withLock({ eventContinuation }) else { return false }
        if case .terminated = continuation.yield(payload) { return false }
        return true
    }

    func waitForEventStream() async throws {
        for _ in 0..<20_000 {
            if lock.withLock({ eventContinuation != nil }) { return }
            await Task.yield()
        }
        throw CommandTestError.timedOut
    }

    func waitForRequest(method: String, path: String) async throws {
        for _ in 0..<20_000 {
            if requests.contains(where: { $0.method == method && $0.path == path }) { return }
            await Task.yield()
        }
        throw CommandTestError.timedOut
    }

    func waitForRequestCount(method: String, path: String, count: Int) async throws {
        for _ in 0..<20_000 {
            if requests.filter({ $0.method == method && $0.path == path }).count >= count { return }
            await Task.yield()
        }
        throw CommandTestError.timedOut
    }
}

private actor CommandCompletionProbe {
    private(set) var outcome: CommandOutcome?
    var isFinished: Bool { outcome != nil }
    func finish(_ outcome: CommandOutcome) { self.outcome = outcome }
}

private actor CommandTestClock: RouterConnectionClock {
    private var timestamp: DeviceTimestamp = .seconds(50)
    let origin: RouterTimestampOrigin

    init(origin: RouterTimestampOrigin) { self.origin = origin }
    var now: DeviceTimestamp { timestamp }
    func sampleTimestampOrigin() -> RouterTimestampOrigin { origin }
    func sleep(for duration: Duration) async throws {
        timestamp += duration
        try await Task.sleep(for: .milliseconds(1))
    }
}

private actor ControlledCommandClock: RouterConnectionClock {
    private struct Sleeper {
        let duration: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private var timestamp: DeviceTimestamp = .seconds(50)
    private var sleepers: [UUID: Sleeper] = [:]
    private var sleepOrder: [UUID] = []
    private(set) var requestedSleeps: [Duration] = []
    let origin: RouterTimestampOrigin

    init(origin: RouterTimestampOrigin) { self.origin = origin }
    var now: DeviceTimestamp { timestamp }
    func sampleTimestampOrigin() -> RouterTimestampOrigin { origin }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                requestedSleeps.append(duration)
                sleepOrder.append(id)
                sleepers[id] = Sleeper(duration: duration, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func advanceNext() {
        guard !sleepOrder.isEmpty else { return }
        let id = sleepOrder.removeFirst()
        guard let sleeper = sleepers.removeValue(forKey: id) else { return }
        timestamp += sleeper.duration
        sleeper.continuation.resume()
    }

    func waitForSleepCount(_ count: Int) async {
        for _ in 0..<20_000 {
            if requestedSleeps.count >= count { return }
            await Task.yield()
        }
    }

    var activeSleepCount: Int { sleepers.count }

    func waitForActiveSleepCount(_ count: Int) async {
        for _ in 0..<20_000 {
            if sleepers.count == count { return }
            await Task.yield()
        }
    }

    private func cancel(id: UUID) {
        sleepOrder.removeAll { $0 == id }
        sleepers.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }
}

private actor CommandCancellationHTTPClient: RouterHTTPClient {
    private let status: Data
    private var commandStarted = false

    init(status: Data) { self.status = status }

    func get(_ path: String, token: String) async throws -> (Data, HTTPURLResponse) {
        try await request("GET", path, body: nil, token: token)
    }

    func request(_ method: String, _ path: String, body: Data?, token: String) async throws -> (Data, HTTPURLResponse) {
        if path == "/api/v1/device" { return response(status, path: path) }
        commandStarted = true
        do {
            try await Task.sleep(for: .seconds(60))
            throw NetworkError.timeout
        } catch is CancellationError {
            throw URLError(.cancelled)
        }
    }

    func waitUntilCommandStarted() async {
        while !commandStarted { await Task.yield() }
    }

    private func response(_ data: Data, path: String) -> (Data, HTTPURLResponse) {
        (data, HTTPURLResponse(url: URL(string: "http://router.local\(path)")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor GatedRefreshHTTPClient: RouterHTTPClient {
    private let status: Data
    private let telemetry: Data
    private var refreshStarted = false
    private var refreshContinuation: CheckedContinuation<Void, Never>?

    init(status: Data, telemetry: Data) {
        self.status = status
        self.telemetry = telemetry
    }

    func get(_ path: String, token: String) async throws -> (Data, HTTPURLResponse) {
        try await request("GET", path, body: nil, token: token)
    }

    func request(_ method: String, _ path: String, body: Data?, token: String) async throws -> (Data, HTTPURLResponse) {
        if path == "/api/v1/telemetry" {
            refreshStarted = true
            await withCheckedContinuation { refreshContinuation = $0 }
            return response(telemetry, path: path)
        }
        return response(status, path: path)
    }

    func waitUntilRefreshStarted() async {
        while !refreshStarted { await Task.yield() }
    }

    func releaseRefresh() {
        refreshContinuation?.resume()
        refreshContinuation = nil
    }

    private func response(_ data: Data, path: String) -> (Data, HTTPURLResponse) {
        (data, HTTPURLResponse(url: URL(string: "http://router.local\(path)")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor GatedRestartHTTPClient: RouterHTTPClient {
    private let status: Data
    private var restartStarted = false
    private var restartContinuation: CheckedContinuation<Void, Never>?

    init(status: Data) { self.status = status }

    func get(_ path: String, token: String) async throws -> (Data, HTTPURLResponse) {
        try await request("GET", path, body: nil, token: token)
    }

    func request(_ method: String, _ path: String, body: Data?, token: String) async throws -> (Data, HTTPURLResponse) {
        if path == "/api/v1/device" { return response(status, path: path) }
        restartStarted = true
        await withCheckedContinuation { restartContinuation = $0 }
        throw URLError(.cancelled)
    }

    func waitUntilRestartStarted() async {
        while !restartStarted { await Task.yield() }
    }

    func releaseWithDisconnectError() {
        restartContinuation?.resume()
        restartContinuation = nil
    }

    private func response(_ data: Data, path: String) -> (Data, HTTPURLResponse) {
        (data, HTTPURLResponse(url: URL(string: "http://router.local\(path)")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private final class CommandEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [DeviceEvent] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<DeviceEvent>) {
        task = Task { [weak self] in
            for await event in stream { self?.lock.withLock { self?.stored.append(event) } }
        }
    }

    deinit { task?.cancel() }
    var events: [DeviceEvent] { lock.withLock { stored } }

    func waitUntil(_ predicate: (DeviceEvent) -> Bool) async throws {
        for _ in 0..<20_000 {
            if events.contains(where: predicate) { return }
            await Task.yield()
        }
        throw CommandTestError.timedOut
    }
}

private enum CommandTestError: Error { case timedOut }

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
