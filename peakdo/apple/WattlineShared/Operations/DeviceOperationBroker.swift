import Foundation
import WattlineCore

actor DeviceOperationBroker {
    final class ContextLifecycle: @unchecked Sendable {
        let id = UUID()
        private let lock = NSLock()
        private var active = true

        var isActive: Bool {
            lock.lock()
            defer { lock.unlock() }
            return active
        }

        func invalidate() {
            lock.lock()
            active = false
            lock.unlock()
        }
    }

    struct Context: Sendable {
        let generation: UInt
        let peripheralID: UUID
        let transport: any DeviceTransport
        let session: DeviceSession
        let lifecycle: ContextLifecycle

        init(
            generation: UInt,
            peripheralID: UUID,
            transport: any DeviceTransport,
            session: DeviceSession,
            lifecycle: ContextLifecycle = ContextLifecycle()
        ) {
            self.generation = generation
            self.peripheralID = peripheralID
            self.transport = transport
            self.session = session
            self.lifecycle = lifecycle
        }
    }

    struct ConnectionAttempt: Equatable, Sendable {
        let generation: UInt
        let peripheralID: UUID
        let lifecycleID: UUID
        let token: UUID
    }

    enum BrokerError: Error, Equatable {
        case unavailable
        case superseded
        case timedOut
    }

    enum ConnectionEvent: Equatable, Sendable {
        case connected
        case terminal
    }

    typealias ReconnectRequest = @Sendable (ConnectionAttempt) async -> Void

    private struct ConnectionWaiter {
        let attempt: ConnectionAttempt
        let continuation: CheckedContinuation<Context, Error>
        let timeoutTask: Task<Void, Never>
    }

    private let clock: any DeviceClock
    private let requestReconnect: ReconnectRequest
    private var context: Context?
    private var connectedGeneration: UInt?
    private var connectedPeripheralID: UUID?
    private var connectionWaiters: [UInt: ConnectionWaiter] = [:]

    init(
        clock: any DeviceClock = ContinuousDeviceClock(),
        requestReconnect: @escaping ReconnectRequest = { _ in }
    ) {
        self.clock = clock
        self.requestReconnect = requestReconnect
    }

    var pendingConnectionCount: Int { connectionWaiters.count }

    func attach(_ context: Context) {
        guard context.lifecycle.isActive else { return }
        if let current = self.context, context.generation < current.generation {
            return
        }

        let preservesConnectedContext = self.context?.generation == context.generation
            && self.context?.peripheralID == context.peripheralID
            && self.context?.lifecycle === context.lifecycle
        let supersededWaiters = connectionWaiters.values.filter {
            $0.attempt.generation != context.generation
                || $0.attempt.peripheralID != context.peripheralID
                || $0.attempt.lifecycleID != context.lifecycle.id
        }
        self.context = context
        if !preservesConnectedContext || connectedGeneration != context.generation {
            connectedGeneration = nil
            connectedPeripheralID = nil
        }
        for waiter in supersededWaiters {
            resolveWaiter(
                attempt: waiter.attempt,
                result: .failure(BrokerError.superseded)
            )
        }
    }

    func detach(generation: UInt) {
        guard context?.generation == generation else { return }
        context?.lifecycle.invalidate()
        context = nil
        connectedGeneration = nil
        connectedPeripheralID = nil
        if let waiter = connectionWaiters[generation] {
            resolveWaiter(attempt: waiter.attempt, result: .failure(BrokerError.unavailable))
        }
    }

    func markConnected(peripheralID: UUID, generation: UInt) {
        guard let context,
              context.generation == generation,
              context.peripheralID == peripheralID,
              context.lifecycle.isActive
        else { return }
        connectedGeneration = generation
        connectedPeripheralID = peripheralID
    }

    func markDisconnected(generation: UInt) {
        guard context?.generation == generation else { return }
        connectedGeneration = nil
        connectedPeripheralID = nil
    }

    func handleConnectionEvent(_ event: ConnectionEvent, attempt: ConnectionAttempt) {
        guard connectionWaiters[attempt.generation]?.attempt == attempt else { return }
        guard let context,
              context.generation == attempt.generation,
              context.peripheralID == attempt.peripheralID,
              context.lifecycle.id == attempt.lifecycleID,
              context.lifecycle.isActive
        else {
            resolveWaiter(attempt: attempt, result: .failure(BrokerError.superseded))
            return
        }
        switch event {
        case .connected:
            connectedGeneration = attempt.generation
            connectedPeripheralID = attempt.peripheralID
            resolveWaiter(attempt: attempt, result: .success(context))
        case .terminal:
            connectedGeneration = nil
            connectedPeripheralID = nil
            resolveWaiter(attempt: attempt, result: .failure(BrokerError.unavailable))
        }
    }

    func perform(_ command: DeviceCommand, generation: UInt) async throws -> CommandOutcome {
        let context = try context(for: generation)
        return try await context.session.perform(command)
    }

    func syncClock(generation: UInt) async throws {
        let context = try context(for: generation)
        try await context.transport.synchronizeDeviceTime()
    }

    func readClock(generation: UInt) async throws -> Date? {
        let context = try context(for: generation)
        return try await context.transport.readDeviceTimeIfSupported()
    }

    func withConnection<T: Sendable>(
        to peripheralID: UUID,
        timeout: Duration = .seconds(10),
        operation: @Sendable (Context) async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        guard let context, context.lifecycle.isActive else { throw BrokerError.unavailable }
        guard context.peripheralID == peripheralID else { throw BrokerError.unavailable }

        let connectedContext: Context
        if connectedGeneration == context.generation,
           connectedPeripheralID == peripheralID {
            connectedContext = context
        } else {
            connectedContext = try await waitForConnection(
                peripheralID: peripheralID,
                generation: context.generation,
                timeout: timeout
            )
        }
        try Task.checkCancellation()
        guard connectedContext.lifecycle.isActive,
              self.context?.generation == connectedContext.generation,
              self.context?.peripheralID == connectedContext.peripheralID,
              self.context?.lifecycle === connectedContext.lifecycle
        else { throw BrokerError.superseded }
        return try await operation(connectedContext)
    }

    private func context(for generation: UInt) throws -> Context {
        guard let context, context.lifecycle.isActive else { throw BrokerError.unavailable }
        guard context.generation == generation else { throw BrokerError.superseded }
        return context
    }

    private func waitForConnection(
        peripheralID: UUID,
        generation: UInt,
        timeout: Duration
    ) async throws -> Context {
        guard let context,
              context.generation == generation,
              context.peripheralID == peripheralID,
              context.lifecycle.isActive
        else { throw BrokerError.superseded }
        let attempt = ConnectionAttempt(
            generation: generation,
            peripheralID: peripheralID,
            lifecycleID: context.lifecycle.id,
            token: UUID()
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let existing = connectionWaiters[generation] {
                    resolveWaiter(
                        attempt: existing.attempt,
                        result: .failure(BrokerError.superseded)
                    )
                }

                let timeoutTask = Task { [weak self, clock] in
                    do {
                        try await clock.sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.timeOutWaiter(attempt: attempt)
                }
                connectionWaiters[generation] = ConnectionWaiter(
                    attempt: attempt,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )

                Task { [requestReconnect] in await requestReconnect(attempt) }
            }
        } onCancel: {
            Task { [weak self] in await self?.cancelWaiter(attempt: attempt) }
        }
    }

    private func timeOutWaiter(attempt: ConnectionAttempt) {
        guard connectionWaiters[attempt.generation]?.attempt == attempt else { return }
        resolveWaiter(attempt: attempt, result: .failure(BrokerError.timedOut))
    }

    private func cancelWaiter(attempt: ConnectionAttempt) {
        guard connectionWaiters[attempt.generation]?.attempt == attempt else { return }
        resolveWaiter(attempt: attempt, result: .failure(CancellationError()))
    }

    private func resolveWaiter(attempt: ConnectionAttempt, result: Result<Context, Error>) {
        guard connectionWaiters[attempt.generation]?.attempt == attempt,
              let waiter = connectionWaiters.removeValue(forKey: attempt.generation)
        else { return }
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(with: result)
    }
}
