import Foundation
import WattlineCore
import XCTest
@testable import WattlineNetwork

final class RouterDevicePairingTests: XCTestCase {
    private let endpoint = RouterEndpoint(
        scheme: "https", host: "router.local", port: 8378,
        certificateFingerprint: String(repeating: "a", count: 64),
        allowsInsecureWAN: false
    )

    func testStatusDecodesExactDeviceFieldsAndUsesClientCredential() async throws {
        let (client, http) = try await makeClient(results: [ScriptedRouterHTTPClient.ok(idle)])
        let status = try await client.status()
        XCTAssertEqual(status, .init(stage: .idle, target: nil, devices: [
            .init(mac: "DC:04:5A:EB:72:2B", name: "PeakDo", rssi: -57, paired: false),
        ], error: nil))
        XCTAssertEqual(http.calls.map(\.token), ["managed-client"])
    }

    func testScanUsesGETThenBodyless202POSTAndPollsToTerminal() async throws {
        let clock = ImmediatePairingClock()
        let (client, http) = try await makeClient(results: [
            ScriptedRouterHTTPClient.ok(idle),
            ScriptedRouterHTTPClient.response(status: 202, scanAccepted),
            ScriptedRouterHTTPClient.ok(scanning), ScriptedRouterHTTPClient.ok(connected),
        ], clock: clock)
        let status = try await client.scan()
        XCTAssertEqual(status.stage, .connected)
        XCTAssertEqual(http.calls.map { ($0.method, $0.path) }.map { "\($0.0) \($0.1)" }, [
            "GET /api/v1/pairing/status", "POST /api/v1/pairing/scan",
            "GET /api/v1/pairing/status", "GET /api/v1/pairing/status",
        ])
        XCTAssertNil(http.calls[1].body)
    }

    func testPairNormalizesMACAndSendsExactPINIncludingEmptyPIN() async throws {
        for pin in ["020555", ""] {
            let (client, http) = try await makeClient(results: [
                ScriptedRouterHTTPClient.ok(idle),
                ScriptedRouterHTTPClient.response(status: 202, pairAccepted),
                ScriptedRouterHTTPClient.ok(connected),
            ])
            _ = try await client.pair(mac: "dc-04-5a-eb-72-2b", pin: pin)
            XCTAssertEqual(http.calls[1].body,
                Data(#"{"mac":"DC:04:5A:EB:72:2B","pin":"\#(pin)"}"#.utf8))
            XCTAssertEqual(http.calls.map(\.token), Array(repeating: "managed-client", count: 3))
        }
    }

    func testExistingActivityIsAdoptedWithoutSecondPOST() async throws {
        let (client, http) = try await makeClient(results: [
            ScriptedRouterHTTPClient.ok(pairing), ScriptedRouterHTTPClient.ok(connected),
        ])
        let value = try await client.scan()
        XCTAssertEqual(value.stage, .connected)
        XCTAssertEqual(http.calls.map(\.method), ["GET", "GET"])
    }

    func testOperationInProgressIsAdoptedWithoutRetryingPOST() async throws {
        let (client, http) = try await makeClient(results: [
            ScriptedRouterHTTPClient.ok(idle),
            .failure(NetworkError.api(status: 409, code: .operationInProgress, message: "busy")),
            ScriptedRouterHTTPClient.ok(pairing), ScriptedRouterHTTPClient.ok(connected),
        ])
        let status = try await client.scan()
        XCTAssertEqual(status.stage, .connected)
        XCTAssertEqual(http.calls.map(\.method), ["GET", "POST", "GET", "GET"])
    }

    func testPollingTimesOutOnInjectedClock() async throws {
        let (client, http) = try await makeClient(
            results: [
                ScriptedRouterHTTPClient.ok(scanning),
                ScriptedRouterHTTPClient.ok(scanning),
                ScriptedRouterHTTPClient.ok(scanning),
            ],
            timeout: .seconds(2), pollInterval: .seconds(1)
        )
        do { _ = try await client.scan(); XCTFail("expected timeout") }
        catch { XCTAssertEqual(error as? RouterDevicePairingError, .timedOut) }
        XCTAssertEqual(http.calls.count, 3)
    }

    func testUnpairUsesEncodedNormalizedMACAndRefetchesStatus() async throws {
        let (client, http) = try await makeClient(results: [
            ScriptedRouterHTTPClient.response(status: 200, removed),
            ScriptedRouterHTTPClient.ok(idle),
        ])
        let status = try await client.unpair(mac: "dc045aeb722b")
        XCTAssertEqual(status.stage, .idle)
        XCTAssertEqual(http.calls.map(\.path), [
            "/api/v1/pairing/device/DC%3A04%3A5A%3AEB%3A72%3A2B",
            "/api/v1/pairing/status",
        ])
        XCTAssertNil(http.calls[0].body)
    }

    func testInvalidMACOrPINFailsBeforeCredentialOrHTTPAccess() async throws {
        let (client, http) = try await makeClient(results: [])
        do { _ = try await client.pair(mac: "bad", pin: ""); XCTFail() }
        catch { XCTAssertEqual(error as? RouterDevicePairingError, .invalidMAC) }
        do { _ = try await client.pair(mac: "DC:04:5A:EB:72:2B", pin: "123"); XCTFail() }
        catch { XCTAssertEqual(error as? RouterDevicePairingError, .invalidPIN) }
        do { _ = try await client.pair(mac: "DC:04:5A:EB:72:2B", pin: "１２３４５６"); XCTFail() }
        catch { XCTAssertEqual(error as? RouterDevicePairingError, .invalidPIN) }
        XCTAssertTrue(http.calls.isEmpty)
    }

    func testFailedStageSanitizesUnexpectedError() async throws {
        let unsafe = #"{"stage":"failed","devices":[],"error":"secret token=abc!"}"#
        let (client, _) = try await makeClient(results: [ScriptedRouterHTTPClient.ok(unsafe)])
        let status = try await client.status()
        XCTAssertEqual(status.error, "pair_failed")
    }

    func testConcurrentOperationIsRejectedWithoutASecondRequest() async throws {
        let http = ScriptedRouterHTTPClient(results: [
            ScriptedRouterHTTPClient.ok(idle),
            ScriptedRouterHTTPClient.response(status: 202, scanAccepted),
            ScriptedRouterHTTPClient.ok(connected),
        ], gateRequests: true)
        let store = RouterCredentialStore(backend: AdministrationCredentialBackend())
        try await store.saveToken("managed-client", for: endpoint)
        let client = RouterDevicePairingClient(
            endpoint: endpoint, credentials: store, http: http,
            clock: ImmediatePairingClock(), pollInterval: .milliseconds(1)
        )
        let first = Task { try await client.scan() }
        await http.waitForGateRegistration()
        do { _ = try await client.pair(mac: "DC:04:5A:EB:72:2B", pin: ""); XCTFail() }
        catch { XCTAssertNotNil(error as? RouterDevicePairingError) }
        XCTAssertEqual(http.calls.count, 1)
        http.releaseNextGate()
        await http.waitForGateRegistration(); http.releaseNextGate()
        await http.waitForGateRegistration(); http.releaseNextGate()
        _ = try await first.value
    }

    func testCancelQuarantinesLateHTTPCompletion() async throws {
        let http = ScriptedRouterHTTPClient(
            results: [ScriptedRouterHTTPClient.ok(idle)], gateRequests: true
        )
        let store = RouterCredentialStore(backend: AdministrationCredentialBackend())
        try await store.saveToken("managed-client", for: endpoint)
        let client = RouterDevicePairingClient(
            endpoint: endpoint, credentials: store, http: http,
            clock: ImmediatePairingClock()
        )
        let operation = Task { try await client.scan() }
        await http.waitForGateRegistration()
        await client.cancel()
        http.releaseGates()
        do { _ = try await operation.value; XCTFail("expected stale cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testCancelStopsAnInjectedPollingSleep() async throws {
        let clock = SuspendedPairingClock()
        let (client, http) = try await makeClient(
            results: [ScriptedRouterHTTPClient.ok(scanning)], clock: clock
        )
        let operation = Task { try await client.scan() }
        let isSleeping = await clock.waitUntilSleeping()
        XCTAssertTrue(isSleeping)
        await client.cancel()
        do { _ = try await operation.value; XCTFail("expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(http.calls.count, 1)
    }

    private func makeClient(
        results: [Result<(Data, HTTPURLResponse), Error>],
        clock: any RouterConnectionClock = ImmediatePairingClock(),
        timeout: Duration = .seconds(30),
        pollInterval: Duration = .milliseconds(1)
    ) async throws -> (RouterDevicePairingClient, ScriptedRouterHTTPClient) {
        let http = ScriptedRouterHTTPClient(results: results)
        let store = RouterCredentialStore(backend: AdministrationCredentialBackend())
        try await store.saveToken("managed-client", for: endpoint, role: .client)
        return (RouterDevicePairingClient(
            endpoint: endpoint, credentials: store, http: http, clock: clock,
            timeout: timeout, pollInterval: pollInterval
        ), http)
    }

    private var idle: String { #"{"stage":"idle","devices":[{"mac":"DC:04:5A:EB:72:2B","name":"PeakDo","rssi":-57,"paired":false}]}"# }
    private var scanning: String { #"{"stage":"scanning","target":null,"devices":[]}"# }
    private var pairing: String { #"{"stage":"pairing","target":"DC:04:5A:EB:72:2B","devices":[]}"# }
    private var connected: String { #"{"stage":"connected","target":"DC:04:5A:EB:72:2B","devices":[{"mac":"DC:04:5A:EB:72:2B","name":"PeakDo","rssi":-48,"paired":true}]}"# }
    private var scanAccepted: String { #"{"status":"scanning"}"# }
    private var pairAccepted: String { #"{"status":"pairing"}"# }
    private var removed: String { #"{"status":"removed"}"# }
}

private actor ImmediatePairingClock: RouterConnectionClock {
    private var timestamp = DeviceTimestamp.seconds(0)
    var now: DeviceTimestamp { timestamp }
    func sampleTimestampOrigin() -> RouterTimestampOrigin {
        .init(wallClock: Date(timeIntervalSince1970: 0), deviceTimestamp: timestamp)
    }
    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        timestamp += duration
        await Task.yield()
    }
}

private actor SuspendedPairingClock: RouterConnectionClock {
    private var timestamp = DeviceTimestamp.seconds(0)
    private var sleeper: CheckedContinuation<Void, Error>?
    var now: DeviceTimestamp { timestamp }
    func sampleTimestampOrigin() -> RouterTimestampOrigin {
        .init(wallClock: Date(timeIntervalSince1970: 0), deviceTimestamp: timestamp)
    }
    func sleep(for duration: Duration) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleeper = continuation
            }
        } onCancel: {
            Task { await self.cancelSleep() }
        }
    }
    func waitUntilSleeping() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while sleeper == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return sleeper != nil
    }
    private func cancelSleep() {
        let continuation = sleeper
        sleeper = nil
        continuation?.resume(throwing: CancellationError())
    }
}
