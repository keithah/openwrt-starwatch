import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import WattlineCore

actor RouterConnection {
    private struct StatusContext: Sendable {
        let device: RouterDeviceDTO
        let timestampOrigin: RouterTimestampOrigin
    }

    private enum RecoverableStreamState: Error {
        case routerDisconnected
    }

    private struct PendingReconciliation {
        let generation: UInt64
        let scope: DeviceConnectionScope
        let reconciler: MutationReconciler
        let continuation: AsyncThrowingStream<CommandOutcome, Error>.Continuation
        let timeoutTask: Task<Void, Never>
    }

    private struct PendingDisconnectGrace {
        let generation: UInt64
        let scope: DeviceConnectionScope
        let continuation: AsyncThrowingStream<Bool, Error>.Continuation
        let timeoutTask: Task<Void, Never>
    }

    private struct PowerLimitResponse: Decodable {
        let type: String
        let level: Int
        let watts: Int?
    }

    private let endpoint: RouterEndpoint
    private let credentials: any RouterCredentialProvider
    private let client: any RouterHTTPClient
    private let eventSource: any RouterEventStream
    private let clock: any RouterConnectionClock
    private let backoff: RouterReconnectBackoff
    private let output: AsyncStream<DeviceEvent>.Continuation
    private let afterStatusAwait: @Sendable () async -> Void
    private let beforeSnapshotYield: @Sendable () async -> Void

    private var generation: UInt64 = 0
    private var pendingScope: DeviceConnectionScope?
    private var establishedGeneration: UInt64?
    private var establishedScope: DeviceConnectionScope?
    private var lastTelemetryTimestamp: DeviceTimestamp?
    private var statusTask: Task<StatusContext, Error>?
    private var streamTask: Task<Void, Never>?
    private var pendingReconciliations: [UUID: PendingReconciliation] = [:]
    private var pendingDisconnectGraces: [UUID: PendingDisconnectGrace] = [:]
    private var reconnectDisarmContext: EstablishedContext?
    private var connectionIsReconnecting = false

    init(
        endpoint: RouterEndpoint,
        credentials: any RouterCredentialProvider,
        client: any RouterHTTPClient,
        events: any RouterEventStream,
        clock: any RouterConnectionClock,
        backoff: RouterReconnectBackoff,
        output: AsyncStream<DeviceEvent>.Continuation,
        afterStatusAwait: @escaping @Sendable () async -> Void = {},
        beforeSnapshotYield: @escaping @Sendable () async -> Void = {}
    ) {
        self.endpoint = endpoint
        self.credentials = credentials
        self.client = client
        eventSource = events
        self.clock = clock
        self.backoff = backoff
        self.output = output
        self.afterStatusAwait = afterStatusAwait
        self.beforeSnapshotYield = beforeSnapshotYield
    }

    deinit {
        statusTask?.cancel()
        streamTask?.cancel()
        for pending in pendingReconciliations.values {
            pending.timeoutTask.cancel()
            pending.continuation.finish(throwing: CancellationError())
        }
        for pending in pendingDisconnectGraces.values {
            pending.timeoutTask.cancel()
            pending.continuation.finish(throwing: CancellationError())
        }
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
        reconnectDisarmContext = nil
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
                    "/api/v1/device",
                    token: credential.token
                )
                try Task.checkCancellation()
                let statusData = try Self.validate(
                    data: data,
                    response: response,
                    token: credential.token
                )
                let device = try Self.decode(
                    RouterDeviceDTO.self,
                    from: statusData,
                    token: credential.token
                )
                let timestampOrigin = await clock.sampleTimestampOrigin()
                try Task.checkCancellation()
                return StatusContext(device: device, timestampOrigin: timestampOrigin)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
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
            lastTelemetryTimestamp = nil
            connectionIsReconnecting = !context.device.connection.connected
            output.yield(.handshakeCompleted(try mapping.identity(context.device), scope: scope))
            output.yield(context.device.connection.connected ? .connected(scope) : .reconnecting(scope))
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
            if Task.isCancelled {
                cleanUpFailedConnect(
                    generation: requestedGeneration,
                    scope: scope
                )
                throw CancellationError()
            }
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
        reconnectDisarmContext = nil
        statusTask?.cancel()
        statusTask = nil
        pendingScope = nil
        cancelAllReconciliations()
        cancelAllDisconnectGraces()
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
        lastTelemetryTimestamp = nil
        connectionIsReconnecting = false
        reconnectDisarmContext = nil
        cancelAllReconciliations()
        cancelAllDisconnectGraces()
        output.yield(.disconnected(scope, nil))
    }

    func perform(_ command: DeviceCommand, request: RouterRequest) async throws -> CommandOutcome {
        guard let context = establishedContext() else {
            throw NetworkError.transport("Router device is not connected")
        }

        switch request.confirmation {
        case let .telemetry(reconciler, timeout):
            let waiter = registerReconciliation(
                reconciler: reconciler,
                timeout: timeout,
                generation: context.generation,
                scope: context.scope
            )
            do {
                _ = try await execute(
                    request,
                    generation: context.generation,
                    scope: context.scope
                )
            } catch {
                if request.ignoresResponseResult,
                   !(error is CancellationError),
                   error as? NetworkError != .unauthorized {
                    // The router/device bypass result is not authoritative; telemetry is.
                } else {
                    cancelReconciliation(waiter.id, error: error)
                    throw error
                }
            }
            return try await awaitReconciliation(waiter)

        case let .powerLimit(type):
            let responseData = try await execute(
                request,
                generation: context.generation,
                scope: context.scope
            )
            return try powerLimitOutcome(data: responseData, type: type)

        case let .disconnect(policy):
            if policy == .successThenDisarmReconnect {
                reconnectDisarmContext = context
            }
            do {
                _ = try await execute(
                    request,
                    generation: context.generation,
                    scope: context.scope,
                    allowReconnectingGeneration: true
                )
                return .sent
            } catch {
                if Task.isCancelled {
                    clearReconnectDisarm(ifMatching: context)
                    throw CancellationError()
                }
                if error as? NetworkError == .unauthorized {
                    clearReconnectDisarm(ifMatching: context)
                    throw error
                }
                if isReconnectSuccess(context: context) {
                    retireAfterExpectedDisconnect(ifRequested: context)
                    return .sent
                }
                do {
                    if try await waitForReconnectTransition(context: context, timeout: .seconds(2)) {
                        return .sent
                    }
                } catch {
                    clearReconnectDisarm(ifMatching: context)
                    throw error
                }
                clearReconnectDisarm(ifMatching: context)
                throw error
            }

        case .none:
            _ = try await execute(
                request,
                generation: context.generation,
                scope: context.scope
            )
            return .sent
        }
    }

    func executeBodyless(_ method: String, _ path: String) async throws {
        guard let context = establishedContext() else {
            throw NetworkError.transport("Router device is not connected")
        }
        _ = try await execute(
            RouterRequest(method: method, path: path),
            generation: context.generation,
            scope: context.scope
        )
    }

    func readDeviceTime() async throws -> Date? {
        guard let context = establishedContext() else {
            throw NetworkError.transport("Router device is not connected")
        }
        let data = try await execute(
            RouterRequest(method: "GET", path: "/api/v1/device/clock"),
            generation: context.generation,
            scope: context.scope
        )
        let response = try Self.decode(RouterDeviceClockStatus.self, from: data, token: "")
        guard response.available else { return nil }
        guard let value = response.deviceTime, let date = Self.date(from: value) else {
            throw NetworkError.decode("Router clock response has no valid device_time")
        }
        return date
    }

    func refreshTelemetry() async throws {
        guard let context = establishedContext() else {
            throw NetworkError.transport("Router device is not connected")
        }
        let data = try await execute(
            RouterRequest(method: "GET", path: "/api/v1/telemetry"),
            generation: context.generation,
            scope: context.scope
        )
        let snapshot = try Self.decode(RouterSnapshotDTO.self, from: data, token: "")
        guard snapshot.connected else { throw RouterMappingError.disconnectedSnapshot }
        let observedAt = await clock.now
        let mapping = RouterMapping(
            peripheralID: endpoint.peripheralID,
            timestampOrigin: await clock.sampleTimestampOrigin()
        )
        guard try yieldSnapshotEvents(
            snapshot,
            mapping: mapping,
            observedAt: observedAt,
            ifEstablished: context.generation,
            scope: context.scope
        ) else {
            throw CancellationError()
        }
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
        let beforeSnapshotYield = beforeSnapshotYield
        streamTask = Task { [weak self] in
            await Self.runEventLoop(
                endpoint: endpoint,
                credentials: credentials,
                eventSource: eventSource,
                clock: clock,
                backoff: backoff,
                beforeSnapshotYield: beforeSnapshotYield,
                isCurrent: { [weak self] in
                    await self?.isEstablished(expectedGeneration, scope: scope) == true
                },
                publishSnapshot: { [weak self] snapshot, observedAt in
                    guard let self else { return false }
                    return try await self.yieldSnapshotEvents(
                        snapshot,
                        mapping: mapping,
                        observedAt: observedAt,
                        ifEstablished: expectedGeneration,
                        scope: scope
                    )
                },
                publishReconnecting: { [weak self] authoritativeDeviceDisconnect in
                    await self?.yieldReconnecting(
                        ifEstablished: expectedGeneration,
                        scope: scope,
                        authoritativeDeviceDisconnect: authoritativeDeviceDisconnect
                    ) == true
                },
                publishUnauthorized: { [weak self] in
                    await self?.yieldUnauthorized(
                        ifEstablished: expectedGeneration,
                        scope: scope
                    ) == true
                }
            )
        }
    }

    private static func runEventLoop(
        endpoint: RouterEndpoint,
        credentials: any RouterCredentialProvider,
        eventSource: any RouterEventStream,
        clock: any RouterConnectionClock,
        backoff: RouterReconnectBackoff,
        beforeSnapshotYield: @escaping @Sendable () async -> Void,
        isCurrent: @escaping @Sendable () async -> Bool,
        publishSnapshot: @escaping @Sendable (RouterSnapshotDTO, DeviceTimestamp) async throws -> Bool,
        publishReconnecting: @escaping @Sendable (Bool) async -> Bool,
        publishUnauthorized: @escaping @Sendable () async -> Bool
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
                    await beforeSnapshotYield()
                    guard try await publishSnapshot(snapshot, observedAt) else { return }
                    consecutiveFailures = 0
                }
                throw NetworkError.streamEnded
            } catch is CancellationError {
                return
            } catch NetworkError.unauthorized {
                _ = await publishUnauthorized()
                return
            } catch RecoverableStreamState.routerDisconnected {
                guard await publishReconnecting(true) else { return }
                let delay = backoff.delay(forFailure: consecutiveFailures)
                consecutiveFailures += 1
                do {
                    try await clock.sleep(for: delay)
                } catch {
                    return
                }
            } catch {
                guard await publishReconnecting(false) else { return }
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

    private func yieldSnapshotEvents(
        _ snapshot: RouterSnapshotDTO,
        mapping: RouterMapping,
        observedAt: DeviceTimestamp,
        ifEstablished expectedGeneration: UInt64,
        scope: DeviceConnectionScope
    ) throws -> Bool {
        guard isEstablished(expectedGeneration, scope: scope) else { return false }
        let events = try mapping.events(
            snapshot: snapshot,
            observedAt: observedAt,
            notBefore: lastTelemetryTimestamp
        )
        for event in events {
            output.yield(event)
        }
        if let timestamp = Self.telemetryTimestamp(in: events) {
            lastTelemetryTimestamp = timestamp
        }
        connectionIsReconnecting = false
        reconcilePendingOperations(with: events, generation: expectedGeneration, scope: scope)
        return true
    }

    private func yieldReconnecting(
        ifEstablished expectedGeneration: UInt64,
        scope: DeviceConnectionScope,
        authoritativeDeviceDisconnect: Bool
    ) -> Bool {
        guard isEstablished(expectedGeneration, scope: scope) else { return false }
        connectionIsReconnecting = true
        completeDisconnectGraces(generation: expectedGeneration, scope: scope, succeeded: true)
        if authoritativeDeviceDisconnect,
           reconnectDisarmContext?.generation == expectedGeneration,
           reconnectDisarmContext?.scope == scope {
            retireEstablishedScope(scope)
            return false
        }
        output.yield(.reconnecting(scope))
        return true
    }

    private func yieldUnauthorized(
        ifEstablished expectedGeneration: UInt64,
        scope: DeviceConnectionScope
    ) -> Bool {
        guard isEstablished(expectedGeneration, scope: scope) else { return false }
        establishedGeneration = nil
        establishedScope = nil
        lastTelemetryTimestamp = nil
        connectionIsReconnecting = false
        streamTask = nil
        cancelAllReconciliations()
        output.yield(.disconnected(
            scope,
            TransportFailure(message: "Router authorization expired")
        ))
        return true
    }

    private static func telemetryTimestamp(in events: [DeviceEvent]) -> DeviceTimestamp? {
        for event in events {
            switch event {
            case let .battery(_, timestamp), let .dc(_, timestamp), let .typeC(_, timestamp):
                return timestamp
            default:
                continue
            }
        }
        return nil
    }

    private typealias EstablishedContext = (generation: UInt64, scope: DeviceConnectionScope)
    private typealias ReconciliationWaiter = (
        id: UUID,
        stream: AsyncThrowingStream<CommandOutcome, Error>
    )

    private func establishedContext() -> EstablishedContext? {
        guard let generation = establishedGeneration, let scope = establishedScope else { return nil }
        return (generation, scope)
    }

    private func clearReconnectDisarm(ifMatching context: EstablishedContext) {
        guard reconnectDisarmContext?.generation == context.generation,
              reconnectDisarmContext?.scope == context.scope else { return }
        reconnectDisarmContext = nil
    }

    private func retireAfterExpectedDisconnect(ifRequested context: EstablishedContext) {
        guard reconnectDisarmContext?.generation == context.generation,
              reconnectDisarmContext?.scope == context.scope else { return }
        retireEstablishedScope(context.scope)
    }

    private func registerReconciliation(
        reconciler: MutationReconciler,
        timeout: Duration,
        generation: UInt64,
        scope: DeviceConnectionScope
    ) -> ReconciliationWaiter {
        let id = UUID()
        let pair = AsyncThrowingStream<CommandOutcome, Error>.makeStream()
        let clock = clock
        let timeoutTask = Task { [weak self] in
            do {
                try await clock.sleep(for: timeout)
                await self?.timeoutReconciliation(id)
            } catch {}
        }
        pendingReconciliations[id] = PendingReconciliation(
            generation: generation,
            scope: scope,
            reconciler: reconciler,
            continuation: pair.continuation,
            timeoutTask: timeoutTask
        )
        return (id, pair.stream)
    }

    private func awaitReconciliation(_ waiter: ReconciliationWaiter) async throws -> CommandOutcome {
        try await withTaskCancellationHandler {
            var iterator = waiter.stream.makeAsyncIterator()
            guard let outcome = try await iterator.next() else { throw CancellationError() }
            return outcome
        } onCancel: {
            Task { [weak self] in
                await self?.cancelReconciliation(waiter.id, error: CancellationError())
            }
        }
    }

    private func reconcilePendingOperations(
        with events: [DeviceEvent],
        generation: UInt64,
        scope: DeviceConnectionScope
    ) {
        let updates: [TelemetryUpdate] = events.compactMap { event in
            switch event {
            case let .dc(status, _): .dc(status)
            case let .typeC(status, _): .typeC(status)
            default: nil
            }
        }
        guard !updates.isEmpty else { return }
        let matched = pendingReconciliations.compactMap { id, pending -> UUID? in
            guard pending.generation == generation, pending.scope == scope,
                  updates.contains(where: pending.reconciler.matches) else { return nil }
            return id
        }
        for id in matched {
            guard let pending = pendingReconciliations.removeValue(forKey: id) else { continue }
            pending.timeoutTask.cancel()
            pending.continuation.yield(.sent)
            pending.continuation.finish()
        }
    }

    private func timeoutReconciliation(_ id: UUID) {
        cancelReconciliation(id, error: NetworkError.timeout)
    }

    private func cancelReconciliation(_ id: UUID, error: Error) {
        guard let pending = pendingReconciliations.removeValue(forKey: id) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.finish(throwing: error)
    }

    private func cancelAllReconciliations() {
        let values = pendingReconciliations.values
        pendingReconciliations.removeAll()
        for pending in values {
            pending.timeoutTask.cancel()
            pending.continuation.finish(throwing: CancellationError())
        }
    }

    private func waitForReconnectTransition(
        context: EstablishedContext,
        timeout: Duration
    ) async throws -> Bool {
        if isReconnectSuccess(context: context) { return true }
        guard isEstablished(context.generation, scope: context.scope) else { return false }
        let id = UUID()
        let pair = AsyncThrowingStream<Bool, Error>.makeStream()
        let clock = clock
        let timeoutTask = Task { [weak self] in
            do {
                try await clock.sleep(for: timeout)
                await self?.completeDisconnectGrace(id: id, succeeded: false)
            } catch {}
        }
        pendingDisconnectGraces[id] = PendingDisconnectGrace(
            generation: context.generation,
            scope: context.scope,
            continuation: pair.continuation,
            timeoutTask: timeoutTask
        )
        if isReconnectSuccess(context: context) {
            completeDisconnectGrace(id: id, succeeded: true)
        }
        return try await withTaskCancellationHandler {
            var iterator = pair.stream.makeAsyncIterator()
            return try await iterator.next() ?? false
        } onCancel: {
            Task { [weak self] in
                await self?.cancelDisconnectGrace(id: id)
            }
        }
    }

    private func completeDisconnectGraces(
        generation: UInt64,
        scope: DeviceConnectionScope,
        succeeded: Bool
    ) {
        let matches = pendingDisconnectGraces.compactMap { id, pending in
            pending.generation == generation && pending.scope == scope ? id : nil
        }
        for id in matches { completeDisconnectGrace(id: id, succeeded: succeeded) }
    }

    private func completeDisconnectGrace(id: UUID, succeeded: Bool) {
        guard let pending = pendingDisconnectGraces.removeValue(forKey: id) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.yield(succeeded)
        pending.continuation.finish()
    }

    private func cancelDisconnectGrace(id: UUID) {
        guard let pending = pendingDisconnectGraces.removeValue(forKey: id) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.finish(throwing: CancellationError())
    }

    private func cancelAllDisconnectGraces() {
        let values = pendingDisconnectGraces.values
        pendingDisconnectGraces.removeAll()
        for pending in values {
            pending.timeoutTask.cancel()
            pending.continuation.yield(false)
            pending.continuation.finish()
        }
    }

    private func execute(
        _ request: RouterRequest,
        generation: UInt64,
        scope: DeviceConnectionScope,
        allowReconnectingGeneration: Bool = false
    ) async throws -> Data {
        let credential: RouterCredential
        do {
            credential = try await credentials.credential(for: endpoint)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NetworkError.unauthorized
        }
        try Task.checkCancellation()

        do {
            let (data, response) = try await client.request(
                request.method,
                request.path,
                body: request.body,
                token: credential.token
            )
            try Task.checkCancellation()
            let validated = try Self.validate(data: data, response: response, token: credential.token)
            guard isEstablished(generation, scope: scope)
                    || (allowReconnectingGeneration && isReconnectSuccess(context: (generation, scope)))
            else { throw CancellationError() }
            return validated
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw Self.normalized(error, token: credential.token)
        }
    }

    private func isReconnectSuccess(context: EstablishedContext) -> Bool {
        establishedGeneration == context.generation
            && establishedScope == context.scope
            && connectionIsReconnecting
    }

    private func powerLimitOutcome(data: Data, type: PowerLimitType) throws -> CommandOutcome {
        let response = try Self.decode(PowerLimitResponse.self, from: data, token: "")
        guard response.type == Self.powerLimitName(type) else {
            throw NetworkError.decode("Power-limit response type does not match request")
        }
        let level = response.level
        let command = DeviceCommand.getPowerLimit(type)
        let frame: Data
        if level < 0 {
            frame = Data([0x02, 0x80, 0xFF])
        } else {
            guard level <= Int(UInt8.max) else {
                throw NetworkError.decode("Power-limit level is out of range")
            }
            frame = Data([0x02, 0x80, 0x00, UInt8(level)])
        }
        return .reply(try command.validate(frame))
    }

    private static func powerLimitName(_ type: PowerLimitType) -> String {
        switch type {
        case .global: "global"
        case .input: "input"
        case .output: "output"
        case .runtime: "runtime"
        }
    }

    private static func date(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func validate(
        data: Data,
        response: HTTPURLResponse,
        token: String
    ) throws -> Data {
        guard (200..<300).contains(response.statusCode) else {
            throw RouterHTTPErrorMapper.error(
                status: response.statusCode,
                data: data,
                token: token
            )
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

    private static func normalized(_ error: Error, token: String) -> Error {
        if error is CancellationError {
            return CancellationError()
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return CancellationError()
            case .timedOut:
                return NetworkError.timeout
            default:
                return NetworkError.transport("URL error \(urlError.errorCode)")
            }
        }
        if let networkError = error as? NetworkError {
            switch networkError {
            case let .httpStatus(status, body):
                return NetworkError.httpStatus(status, redact(body, token: token))
            case let .decode(message):
                return NetworkError.decode(redact(message, token: token))
            case let .unsupported(message):
                return NetworkError.unsupported(redact(message, token: token))
            case let .transport(message):
                return NetworkError.transport(redact(message, token: token))
            case let .api(status, code, message):
                return NetworkError.api(
                    status: status,
                    code: code,
                    message: redact(message, token: token)
                )
            case .invalidURL, .unauthorized, .goodCloudSessionExpired, .streamEnded, .timeout:
                return networkError
            }
        }
        return NetworkError.transport(redact(String(describing: error), token: token))
    }

    private static func redact(_ value: String, token: String) -> String {
        guard !token.isEmpty else { return value }
        return value.replacingOccurrences(of: token, with: "[REDACTED]")
    }
}
