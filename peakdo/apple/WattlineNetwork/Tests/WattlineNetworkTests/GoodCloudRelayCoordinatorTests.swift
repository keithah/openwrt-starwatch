import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GoodCloudKit
import XCTest
@testable import WattlineNetwork

final class GoodCloudRelayCoordinatorTests: XCTestCase {
    func test_concurrentRESTAndSSELeaseShareOneProvisioning() async throws {
        let provisioner = SuspendedRelayProvisioner()
        let coordinator = GoodCloudRelayCoordinator(
            deviceID: "42",
            provisioner: provisioner,
            relayClient: { _ in EmptyRemoteRelayClient() }
        )

        async let first = coordinator.session()
        async let second = coordinator.session()
        await provisioner.waitUntilCalled()
        await provisioner.resume(with: .fixture)
        _ = try await (first, second)

        let calls = await provisioner.calls
        XCTAssertEqual(calls, [.init(deviceID: "42", port: 8377)])
    }

    func test_expiredGETReprovisionsOnce() async throws {
        let relay = ScriptedRemoteRelayClient(requestResults: [
            .failure(.sessionExpired),
            .success((Data(), .ok)),
        ])
        let provisioner = CountingRelayProvisioner()
        let coordinator = GoodCloudRelayCoordinator(
            deviceID: "42",
            provisioner: provisioner,
            relayClient: { _ in relay }
        )

        _ = try await coordinator.request(
            method: "GET",
            path: "/api/v1/status",
            headers: [:],
            body: nil
        )

        let requestCount = await relay.requestCount
        let provisionCount = await provisioner.callCount
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(provisionCount, 2)
    }

    func test_expiredGETOnlyRetriesOnce() async {
        let relay = ScriptedRemoteRelayClient(requestResults: [
            .failure(.sessionExpired),
            .failure(.sessionExpired),
        ])
        let provisioner = CountingRelayProvisioner()
        let coordinator = GoodCloudRelayCoordinator(
            deviceID: "42",
            provisioner: provisioner,
            relayClient: { _ in relay }
        )

        do {
            _ = try await coordinator.request(
                method: "GET",
                path: "/api/v1/status",
                headers: [:],
                body: nil
            )
            XCTFail("Expected session expiry")
        } catch {
            XCTAssertEqual(error as? NetworkError, .goodCloudSessionExpired)
        }

        let requestCount = await relay.requestCount
        let provisionCount = await provisioner.callCount
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(provisionCount, 2)
    }

    func test_expiredMutationInvalidatesButDoesNotReplay() async {
        let relay = ScriptedRemoteRelayClient(requestResults: [
            .failure(.sessionExpired),
        ])
        let provisioner = CountingRelayProvisioner()
        let coordinator = GoodCloudRelayCoordinator(
            deviceID: "42",
            provisioner: provisioner,
            relayClient: { _ in relay }
        )

        do {
            _ = try await coordinator.request(
                method: "POST",
                path: "/api/v1/device/action",
                headers: [:],
                body: Data("{}".utf8)
            )
            XCTFail("Expected session expiry")
        } catch {
            XCTAssertEqual(error as? NetworkError, .goodCloudSessionExpired)
        }

        let requestCount = await relay.requestCount
        let initialProvisionCount = await provisioner.callCount
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(initialProvisionCount, 1)
        _ = try? await coordinator.session()
        let finalProvisionCount = await provisioner.callCount
        XCTAssertEqual(finalProvisionCount, 2)
    }

    func test_minus1010ProvisioningErrorMapsWithoutServerMessage() async {
        let provisioner = FailingRelayProvisioner(
            error: GoodCloudError.api(code: -1010, message: "FE_TOKEN=secret")
        )
        let coordinator = GoodCloudRelayCoordinator(
            deviceID: "42",
            provisioner: provisioner,
            relayClient: { _ in EmptyRemoteRelayClient() }
        )

        do {
            _ = try await coordinator.session()
            XCTFail("Expected session expiry")
        } catch {
            XCTAssertEqual(error as? NetworkError, .goodCloudSessionExpired)
            XCTAssertFalse(String(describing: error).contains("secret"))
        }
    }

    func test_goodCloudDiagnosticFailureMapsToFixedSecretFreeError() async {
        let provisioner = FailingRelayProvisioner(
            error: GoodCloudError.decoding("FE_TOKEN=secret")
        )
        let coordinator = GoodCloudRelayCoordinator(
            deviceID: "42",
            provisioner: provisioner,
            relayClient: { _ in EmptyRemoteRelayClient() }
        )

        do {
            _ = try await coordinator.session()
            XCTFail("Expected relay failure")
        } catch {
            XCTAssertEqual(
                error as? NetworkError,
                .transport("GoodCloud relay request failed")
            )
            XCTAssertFalse(String(describing: error).contains("secret"))
        }
    }

    func test_expiredStreamReprovisionsOnce() async throws {
        let relay = ScriptedRemoteRelayClient(streamResults: [
            [.failure(.sessionExpired)],
            [.success(.response(.ok)), .success(.data(Data("data: ok\n\n".utf8)))],
        ])
        let provisioner = CountingRelayProvisioner()
        let coordinator = GoodCloudRelayCoordinator(
            deviceID: "42",
            provisioner: provisioner,
            relayClient: { _ in relay }
        )

        let stream = await coordinator.stream(
            method: "GET",
            path: "/api/v1/events",
            headers: [:],
            body: nil
        )
        var events: [RemoteRelayStreamEvent] = []
        for try await event in stream {
            events.append(event)
        }

        XCTAssertEqual(events.count, 4)
        let streamCount = await relay.streamCount
        let provisionCount = await provisioner.callCount
        XCTAssertEqual(streamCount, 2)
        XCTAssertEqual(provisionCount, 2)
    }

    func test_cancelledMutationWaitingForSharedProvisioningNeverDispatchesRelay() async throws {
        let provisioner = SuspendedRelayProvisioner()
        let relay = DispatchRecordingRemoteRelayClient()
        let coordinator = GoodCloudRelayCoordinator(
            deviceID: "42",
            provisioner: provisioner,
            relayClient: { _ in relay }
        )
        let cancellationFinished = expectation(
            description: "cancelled mutation finishes before shared provisioning"
        )
        let cancelledMutation = Task {
            defer { cancellationFinished.fulfill() }
            return try await coordinator.request(
                method: "POST",
                path: "/api/v1/device/action",
                headers: [:],
                body: Data("{}".utf8)
            )
        }

        await provisioner.waitUntilCalled()
        let liveRequest = Task {
            try await coordinator.request(
                method: "GET",
                path: "/api/v1/status",
                headers: [:],
                body: nil
            )
        }
        await Task.yield()
        cancelledMutation.cancel()
        await fulfillment(of: [cancellationFinished], timeout: 0.5)
        await provisioner.resume(with: .fixture)

        do {
            _ = try await cancelledMutation.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        _ = try await liveRequest.value

        let methods = relay.requestMethods
        let provisionCalls = await provisioner.calls
        XCTAssertEqual(methods, ["GET"])
        XCTAssertEqual(provisionCalls.count, 1)
    }

    func test_provisionerCancellationClearsFailedSharedTaskForNextWaiter() async throws {
        let provisioner = CancellationThenSuccessRelayProvisioner()
        let coordinator = GoodCloudRelayCoordinator(
            deviceID: "42",
            provisioner: provisioner,
            relayClient: { _ in EmptyRemoteRelayClient() }
        )

        do {
            _ = try await coordinator.session()
            XCTFail("Expected provisioner cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        _ = try await coordinator.session()
        let callCount = await provisioner.callCount
        XCTAssertEqual(callCount, 2)
    }

    func test_cancelledSSEWaitingForProvisioningNeverOpensRelayStream() async {
        let provisioner = SuspendedRelayProvisioner()
        let relay = DispatchRecordingRemoteRelayClient()
        let coordinator = GoodCloudRelayCoordinator(
            deviceID: "42",
            provisioner: provisioner,
            relayClient: { _ in relay }
        )
        let stream = await coordinator.stream(
            method: "GET",
            path: "/api/v1/events",
            headers: [:],
            body: nil
        )
        let consumer = Task {
            for try await _ in stream {}
        }

        await provisioner.waitUntilCalled()
        consumer.cancel()
        await provisioner.resume(with: .fixture)
        _ = try? await consumer.value

        let streamCount = relay.streamCount
        XCTAssertEqual(streamCount, 0)
    }
}

private struct RelayProvisionCall: Equatable, Sendable {
    let deviceID: String
    let port: Int
}

private actor SuspendedRelayProvisioner: GoodCloudRelayProvisioning {
    private(set) var calls: [RelayProvisionCall] = []
    private var resultContinuation: CheckedContinuation<RemoteAccessSession, Error>?
    private var callWaiters: [CheckedContinuation<Void, Never>] = []

    func remoteAccess(deviceID: String, port: Int) async throws -> RemoteAccessSession {
        calls.append(.init(deviceID: deviceID, port: port))
        let waiters = callWaiters
        callWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { continuation in
            resultContinuation = continuation
        }
    }

    func waitUntilCalled() async {
        guard calls.isEmpty else { return }
        await withCheckedContinuation { continuation in
            callWaiters.append(continuation)
        }
    }

    func resume(with session: RemoteAccessSession) {
        resultContinuation?.resume(returning: session)
        resultContinuation = nil
    }
}

private actor CountingRelayProvisioner: GoodCloudRelayProvisioning {
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

private actor CancellationThenSuccessRelayProvisioner: GoodCloudRelayProvisioning {
    private(set) var callCount = 0

    func remoteAccess(deviceID: String, port: Int) async throws -> RemoteAccessSession {
        callCount += 1
        if callCount == 1 {
            throw CancellationError()
        }
        return .fixture
    }
}

private struct FailingRelayProvisioner: GoodCloudRelayProvisioning {
    let error: GoodCloudError

    func remoteAccess(deviceID: String, port: Int) async throws -> RemoteAccessSession {
        throw error
    }
}

private struct EmptyRemoteRelayClient: RemoteRelayClient {
    func request(
        method: String,
        path: String,
        headers: [String: String],
        body: Data?
    ) async throws -> (Data, HTTPURLResponse) {
        (Data(), .ok)
    }

    func stream(
        method: String,
        path: String,
        headers: [String: String],
        body: Data?
    ) -> AsyncThrowingStream<RelayHTTPStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class DispatchRecordingRemoteRelayClient: RemoteRelayClient, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequestMethods: [String] = []
    private var recordedStreamCount = 0

    var requestMethods: [String] {
        lock.withLock { recordedRequestMethods }
    }

    var streamCount: Int {
        lock.withLock { recordedStreamCount }
    }

    func request(
        method: String,
        path: String,
        headers: [String: String],
        body: Data?
    ) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recordedRequestMethods.append(method) }
        return (Data(), .ok)
    }

    func stream(
        method: String,
        path: String,
        headers: [String: String],
        body: Data?
    ) -> AsyncThrowingStream<RelayHTTPStreamEvent, Error> {
        lock.withLock { recordedStreamCount += 1 }
        return AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

private actor ScriptedRemoteRelayClient: RemoteRelayClient {
    enum ScriptedError: Error, Sendable {
        case sessionExpired

        var error: any Error {
            switch self {
            case .sessionExpired: GoodCloudError.sessionExpired
            }
        }
    }

    enum RequestResult: @unchecked Sendable {
        case success((Data, HTTPURLResponse))
        case failure(ScriptedError)
    }

    enum StreamResult: @unchecked Sendable {
        case success(RelayHTTPStreamEvent)
        case failure(ScriptedError)
    }

    private var requestResults: [RequestResult]
    private var streamResults: [[StreamResult]]
    private(set) var requestCount = 0
    private(set) var streamCount = 0

    init(
        requestResults: [RequestResult] = [],
        streamResults: [[StreamResult]] = []
    ) {
        self.requestResults = requestResults
        self.streamResults = streamResults
    }

    func request(
        method: String,
        path: String,
        headers: [String: String],
        body: Data?
    ) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        guard !requestResults.isEmpty else {
            throw GoodCloudError.relayUnavailable
        }
        switch requestResults.removeFirst() {
        case .success(let response): return response
        case .failure(let error): throw error.error
        }
    }

    nonisolated func stream(
        method: String,
        path: String,
        headers: [String: String],
        body: Data?
    ) -> AsyncThrowingStream<RelayHTTPStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let results = await self.takeStreamResults()
                for result in results {
                    switch result {
                    case .success(let event): continuation.yield(event)
                    case .failure(let error):
                        continuation.finish(throwing: error.error)
                        return
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func takeStreamResults() -> [StreamResult] {
        streamCount += 1
        guard !streamResults.isEmpty else { return [] }
        return streamResults.removeFirst()
    }
}

private extension RemoteAccessSession {
    static let fixture = RemoteAccessSession(
        baseURL: URL(string: "https://relay.goodcloud.xyz/web/device/http/target")!,
        tokenDomain: ".goodcloud.xyz",
        sessionID: "session",
        issuedAtMillis: 42
    )
}

private extension HTTPURLResponse {
    static let ok = HTTPURLResponse(
        url: URL(string: "https://relay.goodcloud.xyz/wattlined")!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
    )!
}
