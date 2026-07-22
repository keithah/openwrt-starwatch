import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GoodCloudKit
import XCTest
@testable import WattlineNetwork

final class RemoteRouterTransportTests: XCTestCase {
    func test_remoteHTTPPassesWattlineAuthorizationAndJSONBody() async throws {
        let coordinator = RecordingRemoteCoordinator(response: .ok)
        let client = RemoteRouterHTTPClient(coordinator: coordinator)
        let body = Data(#"{"action":"dc_off"}"#.utf8)

        _ = try await client.request(
            "POST",
            "/api/v1/device/action",
            body: body,
            token: "wattline-token"
        )

        let request = await coordinator.lastRequest
        XCTAssertEqual(request?.headers["Authorization"], "Bearer wattline-token")
        XCTAssertEqual(request?.headers["Content-Type"], "application/json")
        XCTAssertEqual(request?.body, body)
    }

    func test_remoteHTTPMapsNon2xxAndRedactsWattlineToken() async {
        let body = Data(#"{"error":{"code":"internal_error","message":"token wattline-token failed"}}"#.utf8)
        let coordinator = RecordingRemoteCoordinator(
            responseData: body,
            response: .fixture(status: 500)
        )
        let client = RemoteRouterHTTPClient(coordinator: coordinator)

        do {
            _ = try await client.get("/api/v1/status", token: "wattline-token")
            XCTFail("Expected HTTP error")
        } catch {
            XCTAssertEqual(
                error as? NetworkError,
                .api(status: 500, code: .internalError, message: "token [REDACTED] failed")
            )
        }
    }

    func test_remoteHTTPRejectsRelativePathBeforeOpeningRelay() async {
        let coordinator = RecordingRemoteCoordinator(response: .ok)
        let client = RemoteRouterHTTPClient(coordinator: coordinator)

        do {
            _ = try await client.get("api/v1/status", token: "token")
            XCTFail("Expected invalid URL")
        } catch {
            XCTAssertEqual(error as? NetworkError, .invalidURL)
        }

        let request = await coordinator.lastRequest
        XCTAssertNil(request)
    }

    func test_remoteSSEParsesFramesAndForwardsBearer() async throws {
        let coordinator = RecordingRemoteCoordinator(streamEvents: [
            .response(.ok),
            .data(Data("data: {\"type\":\"snapshot\"}\n\n".utf8)),
        ])
        let stream = RemoteRouterEventStream(coordinator: coordinator)
        var iterator = stream.events(
            path: "/api/v1/events",
            token: "wattline-token"
        ).makeAsyncIterator()

        let payload = try await iterator.next()
        XCTAssertEqual(payload, Data(#"{"type":"snapshot"}"#.utf8))
        let request = await coordinator.lastStream
        XCTAssertEqual(request?.headers["Authorization"], "Bearer wattline-token")
        XCTAssertEqual(request?.headers["Accept"], "text/event-stream")
    }

    func test_remoteSSEParsesFramesSplitAcrossRelayChunks() async throws {
        let coordinator = RecordingRemoteCoordinator(streamEvents: [
            .response(.ok),
            .data(Data("da".utf8)),
            .data(Data("ta: first\r\n".utf8)),
            .data(Data("data: second\n\n".utf8)),
        ])
        let stream = RemoteRouterEventStream(coordinator: coordinator)
        var iterator = stream.events(path: "/api/v1/events", token: "token").makeAsyncIterator()

        let payload = try await iterator.next()
        let end = try await iterator.next()
        XCTAssertEqual(payload, Data("first\nsecond".utf8))
        XCTAssertNil(end)
    }

    func test_remoteSSEDiscardsTruncatedFrameAtEOF() async throws {
        let coordinator = RecordingRemoteCoordinator(streamEvents: [
            .response(.ok),
            .data(Data("data: incomplete".utf8)),
        ])
        let stream = RemoteRouterEventStream(coordinator: coordinator)
        var iterator = stream.events(path: "/api/v1/events", token: "token").makeAsyncIterator()

        let payload = try await iterator.next()
        XCTAssertNil(payload)
    }

    func test_remoteSSEMapsUnauthorizedResponse() async {
        let coordinator = RecordingRemoteCoordinator(streamEvents: [
            .response(.fixture(status: 401)),
        ])
        let stream = RemoteRouterEventStream(coordinator: coordinator)

        do {
            for try await _ in stream.events(path: "/api/v1/events", token: "token") {}
            XCTFail("Expected unauthorized")
        } catch {
            XCTAssertEqual(error as? NetworkError, .unauthorized)
        }
    }

    func test_remoteSSECancellationCancelsRelayConsumption() async throws {
        let probe = StreamCancellationProbe()
        let coordinator = RecordingRemoteCoordinator(cancellationProbe: probe)
        let stream = RemoteRouterEventStream(coordinator: coordinator)
        let task = Task {
            for try await _ in stream.events(path: "/api/v1/events", token: "token") {}
        }

        await probe.waitUntilStarted()
        task.cancel()
        _ = try? await task.value

        await probe.waitUntilCancelled()
        let wasCancelled = await probe.wasCancelled
        XCTAssertTrue(wasCancelled)
    }

    func test_remoteSSERetryResetsResponseParserAndPartialLineState() async throws {
        let relay = RetryingStreamRelayClient(attempts: [
            [
                .event(.response(.ok)),
                .event(.data(Data("data: stale-partial".utf8))),
                .expired,
            ],
            [
                .event(.response(.ok)),
                .event(.data(Data("data: fresh\n\n".utf8))),
            ],
        ])
        let provisioner = ImmediateRelayProvisioner()
        let coordinator = GoodCloudRelayCoordinator(
            deviceID: "42",
            provisioner: provisioner,
            relayClient: { _ in relay }
        )
        let stream = RemoteRouterEventStream(coordinator: coordinator)
        var iterator = stream.events(
            path: "/api/v1/events",
            token: "wattline-token"
        ).makeAsyncIterator()

        let payload = try await iterator.next()
        let end = try await iterator.next()

        XCTAssertEqual(payload, Data("fresh".utf8))
        XCTAssertNil(end)
        let attempts = await relay.streamCount
        let provisions = await provisioner.callCount
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(provisions, 2)
    }
}

private actor RecordingRemoteCoordinator: RemoteRelayCoordinating {
    struct Request: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data?
    }

    private let responseData: Data
    private let response: HTTPURLResponse
    private let streamEvents: [RelayHTTPStreamEvent]
    private let cancellationProbe: StreamCancellationProbe?
    private(set) var lastRequest: Request?
    private(set) var lastStream: Request?

    init(
        responseData: Data = Data(),
        response: HTTPURLResponse = .ok,
        streamEvents: [RelayHTTPStreamEvent] = [],
        cancellationProbe: StreamCancellationProbe? = nil
    ) {
        self.responseData = responseData
        self.response = response
        self.streamEvents = streamEvents
        self.cancellationProbe = cancellationProbe
    }

    init(cancellationProbe: StreamCancellationProbe) {
        self.init(
            response: .ok,
            cancellationProbe: cancellationProbe
        )
    }

    func request(
        method: String,
        path: String,
        headers: [String: String],
        body: Data?
    ) async throws -> (Data, HTTPURLResponse) {
        lastRequest = .init(method: method, path: path, headers: headers, body: body)
        return (responseData, response)
    }

    func stream(
        method: String,
        path: String,
        headers: [String: String],
        body: Data?
    ) async -> AsyncThrowingStream<RemoteRelayStreamEvent, Error> {
        lastStream = .init(method: method, path: path, headers: headers, body: body)
        if let cancellationProbe {
            return AsyncThrowingStream { continuation in
                let task = Task {
                    continuation.yield(.attemptStarted)
                    await cancellationProbe.started()
                    do {
                        try await Task.sleep(for: .seconds(60))
                    } catch {
                        await cancellationProbe.cancelled()
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.attemptStarted)
            streamEvents.forEach { event in
                switch event {
                case .response(let response): continuation.yield(.response(response))
                case .data(let data): continuation.yield(.data(data))
                }
            }
            continuation.finish()
        }
    }
}

private actor StreamCancellationProbe {
    private(set) var wasCancelled = false
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []

    func started() {
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func cancelled() {
        wasCancelled = true
        let waiters = cancelWaiters
        cancelWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitUntilCancelled() async {
        guard !wasCancelled else { return }
        await withCheckedContinuation { cancelWaiters.append($0) }
    }
}

private actor ImmediateRelayProvisioner: GoodCloudRelayProvisioning {
    private(set) var callCount = 0

    func remoteAccess(deviceID: String, port: Int) async throws -> RemoteAccessSession {
        callCount += 1
        return RemoteAccessSession(
            baseURL: URL(string: "https://relay.goodcloud.xyz/\(callCount)/")!,
            tokenDomain: ".goodcloud.xyz",
            sessionID: "session-\(callCount)",
            issuedAtMillis: Int64(callCount)
        )
    }
}

private actor RetryingStreamRelayClient: RemoteRelayClient {
    enum Step: @unchecked Sendable {
        case event(RelayHTTPStreamEvent)
        case expired
    }

    private var attempts: [[Step]]
    private(set) var streamCount = 0

    init(attempts: [[Step]]) {
        self.attempts = attempts
    }

    func request(
        method: String,
        path: String,
        headers: [String: String],
        body: Data?
    ) async throws -> (Data, HTTPURLResponse) {
        (Data(), .ok)
    }

    nonisolated func stream(
        method: String,
        path: String,
        headers: [String: String],
        body: Data?
    ) -> AsyncThrowingStream<RelayHTTPStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let steps = await self.nextAttempt()
                for step in steps {
                    switch step {
                    case .event(let event):
                        continuation.yield(event)
                    case .expired:
                        continuation.finish(throwing: GoodCloudError.sessionExpired)
                        return
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func nextAttempt() -> [Step] {
        streamCount += 1
        guard !attempts.isEmpty else { return [] }
        return attempts.removeFirst()
    }
}

private extension HTTPURLResponse {
    static let ok = fixture(status: 200)

    static func fixture(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://relay.goodcloud.xyz/wattlined")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}
