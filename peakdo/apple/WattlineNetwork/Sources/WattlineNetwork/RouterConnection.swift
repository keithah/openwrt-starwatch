import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import WattlineCore

actor RouterConnection {
    private let endpoint: RouterEndpoint
    private let client: any RouterHTTPClient
    private let eventSource: any RouterEventStream
    private let clock: any RouterConnectionClock
    private let backoff: RouterReconnectBackoff
    private let output: AsyncStream<DeviceEvent>.Continuation

    private var generation: UInt64 = 0
    private var activeScope: DeviceConnectionScope?
    private var streamTask: Task<Void, Never>?

    init(
        endpoint: RouterEndpoint,
        client: any RouterHTTPClient,
        events: any RouterEventStream,
        clock: any RouterConnectionClock,
        backoff: RouterReconnectBackoff,
        output: AsyncStream<DeviceEvent>.Continuation
    ) {
        self.endpoint = endpoint
        self.client = client
        eventSource = events
        self.clock = clock
        self.backoff = backoff
        self.output = output
    }

    deinit {
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
        let previousStreamTask = streamTask
        activeScope = scope

        do {
            let (data, response) = try await client.get("/api/v1/status", token: endpoint.token)
            let statusData = try validate(data: data, response: response)
            let status = try decode(RouterStatusDTO.self, from: statusData)
            let timestampOrigin = await clock.sampleTimestampOrigin()

            guard isCurrent(requestedGeneration, scope: scope) else {
                previousStreamTask?.cancel()
                return
            }
            previousStreamTask?.cancel()

            let mapping = RouterMapping(
                peripheralID: endpoint.peripheralID,
                timestampOrigin: timestampOrigin
            )
            output.yield(.handshakeCompleted(mapping.identity(status.device), scope: scope))
            if status.connected {
                output.yield(.connected(scope))
            } else {
                output.yield(.disconnected(scope, nil))
            }

            let task = Task { [weak self] in
                guard let self else { return }
                await self.runEventLoop(
                    generation: requestedGeneration,
                    scope: scope,
                    mapping: mapping
                )
            }
            streamTask = task
        } catch {
            previousStreamTask?.cancel()
            if isCurrent(requestedGeneration, scope: scope) {
                streamTask = nil
                activeScope = nil
            }
            throw normalized(error)
        }
    }

    func disconnect() {
        generation &+= 1
        streamTask?.cancel()
        streamTask = nil
        guard let scope = activeScope else { return }
        activeScope = nil
        output.yield(.disconnected(scope, nil))
    }

    private func runEventLoop(
        generation expectedGeneration: UInt64,
        scope: DeviceConnectionScope,
        mapping: RouterMapping
    ) async {
        var consecutiveFailures = 0

        while isCurrent(expectedGeneration, scope: scope), !Task.isCancelled {
            do {
                let stream = eventSource.events(
                    path: "/api/v1/events",
                    token: endpoint.token
                )
                for try await payload in stream {
                    try Task.checkCancellation()
                    guard isCurrent(expectedGeneration, scope: scope) else { return }
                    let snapshot = try decode(RouterSnapshotDTO.self, from: payload)
                    let observedAt = await clock.now
                    guard isCurrent(expectedGeneration, scope: scope) else { return }
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
                guard isCurrent(expectedGeneration, scope: scope) else { return }
                output.yield(.reconnecting(scope))
                output.yield(.disconnected(
                    scope,
                    TransportFailure(message: redactedDescription(of: error))
                ))
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

    private func isCurrent(
        _ expectedGeneration: UInt64,
        scope: DeviceConnectionScope
    ) -> Bool {
        generation == expectedGeneration && activeScope == scope
    }

    private func validate(data: Data, response: HTTPURLResponse) throws -> Data {
        if response.statusCode == 401 {
            throw NetworkError.unauthorized
        }
        guard (200..<300).contains(response.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NetworkError.httpStatus(
                response.statusCode,
                body.replacingOccurrences(of: endpoint.token, with: "[REDACTED]")
            )
        }
        return data
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        guard String(data: data, encoding: .utf8) != nil else {
            throw NetworkError.decode("Invalid UTF-8 JSON")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw NetworkError.decode(redactedDescription(of: error))
        }
    }

    private func normalized(_ error: Error) -> NetworkError {
        if let networkError = error as? NetworkError {
            switch networkError {
            case let .httpStatus(status, body):
                return .httpStatus(status, redact(body))
            case let .decode(message):
                return .decode(redact(message))
            case let .unsupported(message):
                return .unsupported(redact(message))
            case .invalidURL, .unauthorized, .streamEnded, .timeout:
                return networkError
            }
        }
        return NetworkError.decode(redactedDescription(of: error))
    }

    private func redactedDescription(of error: Error) -> String {
        redact(String(describing: error))
    }

    private func redact(_ value: String) -> String {
        guard !endpoint.token.isEmpty else { return value }
        return value.replacingOccurrences(of: endpoint.token, with: "[REDACTED]")
    }
}
