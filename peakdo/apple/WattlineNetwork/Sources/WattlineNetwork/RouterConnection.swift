import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import WattlineCore

actor RouterConnection {
    private struct StatusContext: Sendable {
        let status: RouterStatusDTO
        let timestampOrigin: RouterTimestampOrigin
    }

    private enum RecoverableStreamState: Error {
        case routerDisconnected
    }

    private let endpoint: RouterEndpoint
    private let credentials: any RouterCredentialProvider
    private let client: any RouterHTTPClient
    private let eventSource: any RouterEventStream
    private let clock: any RouterConnectionClock
    private let backoff: RouterReconnectBackoff
    private let output: AsyncStream<DeviceEvent>.Continuation
    private let afterStatusAwait: @Sendable () async -> Void

    private var generation: UInt64 = 0
    private var pendingScope: DeviceConnectionScope?
    private var establishedGeneration: UInt64?
    private var establishedScope: DeviceConnectionScope?
    private var statusTask: Task<StatusContext, Error>?
    private var streamTask: Task<Void, Never>?

    init(
        endpoint: RouterEndpoint,
        credentials: any RouterCredentialProvider,
        client: any RouterHTTPClient,
        events: any RouterEventStream,
        clock: any RouterConnectionClock,
        backoff: RouterReconnectBackoff,
        output: AsyncStream<DeviceEvent>.Continuation,
        afterStatusAwait: @escaping @Sendable () async -> Void = {}
    ) {
        self.endpoint = endpoint
        self.credentials = credentials
        self.client = client
        eventSource = events
        self.clock = clock
        self.backoff = backoff
        self.output = output
        self.afterStatusAwait = afterStatusAwait
    }

    deinit {
        statusTask?.cancel()
        streamTask?.cancel()
        output.finish()
    }

    func makeConnectionScope() -> DeviceConnectionScope {
        DeviceConnectionScope(peripheralID: endpoint.peripheralID, sessionID: UUID())
    }

    func connect(to id: UUID, scope: DeviceConnectionScope) async throws {
        precondition(id == endpoint.peripheralID, "Router connection ID must match its endpoint")
        precondition(scope.peripheralID == id, "Router connection scope must match its endpoint")

        generation &+= 1
        let requestedGeneration = generation
        statusTask?.cancel()
        pendingScope = scope
        if let establishedScope, establishedScope != scope {
            retireEstablishedScope(establishedScope)
        }

        let endpoint = endpoint
        let credentials = credentials
        let client = client
        let clock = clock
        let task = Task<StatusContext, Error> {
            try Task.checkCancellation()
            let credential: RouterCredential
            do {
                credential = try await credentials.credential(for: endpoint)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Provider failures may contain secret material. Treat them as an
                // authentication failure without reflecting their description.
                throw NetworkError.unauthorized
            }
            try Task.checkCancellation()

            do {
                let (data, response) = try await client.get(
                    "/api/v1/status",
                    token: credential.token
                )
                try Task.checkCancellation()
                let statusData = try Self.validate(
                    data: data,
                    response: response,
                    token: credential.token
                )
                let status = try Self.decode(
                    RouterStatusDTO.self,
                    from: statusData,
                    token: credential.token
                )
                let timestampOrigin = await clock.sampleTimestampOrigin()
                try Task.checkCancellation()
                return StatusContext(status: status, timestampOrigin: timestampOrigin)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw Self.normalized(error, token: credential.token)
            }
        }
        statusTask = task

        do {
            let context = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            await afterStatusAwait()
            try Task.checkCancellation()

            guard isCurrentConnect(requestedGeneration, scope: scope) else {
                throw CancellationError()
            }
            statusTask = nil
            pendingScope = nil
            streamTask?.cancel()
            streamTask = nil

            let mapping = RouterMapping(
                peripheralID: endpoint.peripheralID,
                timestampOrigin: context.timestampOrigin
            )
            establishedGeneration = requestedGeneration
            establishedScope = scope
            output.yield(.handshakeCompleted(mapping.identity(context.status.device), scope: scope))
            output.yield(context.status.connected ? .connected(scope) : .reconnecting(scope))
            startEventLoop(
                generation: requestedGeneration,
                scope: scope,
                mapping: mapping
            )
        } catch is CancellationError {
            cleanUpFailedConnect(
                generation: requestedGeneration,
                scope: scope
            )
            throw CancellationError()
        } catch {
            let wasSuperseded = !isCurrentConnect(requestedGeneration, scope: scope)
            cleanUpFailedConnect(
                generation: requestedGeneration,
                scope: scope
            )
            if wasSuperseded {
                throw CancellationError()
            }
            throw error
        }
    }

    func disconnect() {
        generation &+= 1
        statusTask?.cancel()
        statusTask = nil
        pendingScope = nil
        guard let establishedScope else { return }
        retireEstablishedScope(establishedScope)
    }

    private func cleanUpFailedConnect(
        generation expectedGeneration: UInt64,
        scope: DeviceConnectionScope
    ) {
        guard isCurrentConnect(expectedGeneration, scope: scope) else { return }
        statusTask = nil
        pendingScope = nil
    }

    private func retireEstablishedScope(_ scope: DeviceConnectionScope) {
        streamTask?.cancel()
        streamTask = nil
        establishedGeneration = nil
        establishedScope = nil
        output.yield(.disconnected(scope, nil))
    }

    private func startEventLoop(
        generation expectedGeneration: UInt64,
        scope: DeviceConnectionScope,
        mapping: RouterMapping
    ) {
        let endpoint = endpoint
        let credentials = credentials
        let eventSource = eventSource
        let clock = clock
        let backoff = backoff
        let output = output
        streamTask = Task { [weak self] in
            await Self.runEventLoop(
                generation: expectedGeneration,
                scope: scope,
                mapping: mapping,
                endpoint: endpoint,
                credentials: credentials,
                eventSource: eventSource,
                clock: clock,
                backoff: backoff,
                output: output,
                isCurrent: { [weak self] in
                    await self?.isEstablished(expectedGeneration, scope: scope) == true
                }
            )
        }
    }

    private static func runEventLoop(
        generation: UInt64,
        scope: DeviceConnectionScope,
        mapping: RouterMapping,
        endpoint: RouterEndpoint,
        credentials: any RouterCredentialProvider,
        eventSource: any RouterEventStream,
        clock: any RouterConnectionClock,
        backoff: RouterReconnectBackoff,
        output: AsyncStream<DeviceEvent>.Continuation,
        isCurrent: @escaping @Sendable () async -> Bool
    ) async {
        var consecutiveFailures = 0

        while await isCurrent(), !Task.isCancelled {
            do {
                let credential: RouterCredential
                do {
                    credential = try await credentials.credential(for: endpoint)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw NetworkError.unauthorized
                }
                try Task.checkCancellation()
                let stream = eventSource.events(
                    path: "/api/v1/events",
                    token: credential.token
                )
                for try await payload in stream {
                    try Task.checkCancellation()
                    guard await isCurrent() else { return }
                    let snapshot = try decode(
                        RouterSnapshotDTO.self,
                        from: payload,
                        token: credential.token
                    )
                    guard snapshot.connected else {
                        throw RecoverableStreamState.routerDisconnected
                    }
                    let observedAt = await clock.now
                    guard await isCurrent() else { return }
                    for event in try mapping.events(
                        snapshot: snapshot,
                        scope: scope,
                        observedAt: observedAt
                    ) {
                        output.yield(event)
                    }
                    consecutiveFailures = 0
                }
                throw NetworkError.streamEnded
            } catch is CancellationError {
                return
            } catch {
                guard await isCurrent() else { return }
                output.yield(.reconnecting(scope))
                let delay = backoff.delay(forFailure: consecutiveFailures)
                consecutiveFailures += 1
                do {
                    try await clock.sleep(for: delay)
                } catch {
                    return
                }
            }
        }
    }

    private func isCurrentConnect(
        _ expectedGeneration: UInt64,
        scope: DeviceConnectionScope
    ) -> Bool {
        generation == expectedGeneration && pendingScope == scope
    }

    private func isEstablished(
        _ expectedGeneration: UInt64,
        scope: DeviceConnectionScope
    ) -> Bool {
        establishedGeneration == expectedGeneration && establishedScope == scope
    }

    private static func validate(
        data: Data,
        response: HTTPURLResponse,
        token: String
    ) throws -> Data {
        if response.statusCode == 401 {
            throw NetworkError.unauthorized
        }
        guard (200..<300).contains(response.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NetworkError.httpStatus(response.statusCode, redact(body, token: token))
        }
        return data
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data,
        token: String
    ) throws -> Value {
        guard String(data: data, encoding: .utf8) != nil else {
            throw NetworkError.decode("Invalid UTF-8 JSON")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw NetworkError.decode(redact(String(describing: error), token: token))
        }
    }

    private static func normalized(_ error: Error, token: String) -> NetworkError {
        if let networkError = error as? NetworkError {
            switch networkError {
            case let .httpStatus(status, body):
                return .httpStatus(status, redact(body, token: token))
            case let .decode(message):
                return .decode(redact(message, token: token))
            case let .unsupported(message):
                return .unsupported(redact(message, token: token))
            case .invalidURL, .unauthorized, .streamEnded, .timeout:
                return networkError
            }
        }
        return NetworkError.decode(redact(String(describing: error), token: token))
    }

    private static func redact(_ value: String, token: String) -> String {
        guard !token.isEmpty else { return value }
        return value.replacingOccurrences(of: token, with: "[REDACTED]")
    }
}
