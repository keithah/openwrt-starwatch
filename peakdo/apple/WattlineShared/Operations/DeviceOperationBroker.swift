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

        var key: ContextKey {
            ContextKey(
                generation: generation,
                peripheralID: peripheralID,
                lifecycleID: lifecycle.id
            )
        }
    }

    struct ContextKey: Equatable, Sendable {
        let generation: UInt
        let peripheralID: UUID
        let lifecycleID: UUID
    }

    struct ConnectionAttempt: Equatable, Sendable {
        let generation: UInt
        let peripheralID: UUID
        let lifecycleID: UUID
        let token: UUID
        let sequence: UInt64
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
    typealias ReconnectInvalidation = @Sendable (ConnectionAttempt) async -> Void

    private enum WaiterPhase: Equatable, Sendable {
        case waiting
        case prepared
    }

    private enum WaiterFailure: Sendable {
        case unavailable
        case superseded
        case timedOut
        case canceled
    }

    private struct ConnectionWaiter {
        let attempt: ConnectionAttempt
        let continuation: CheckedContinuation<Context, Error>
        let timeoutTask: Task<Void, Never>
        var phase: WaiterPhase
    }

    private let clock: any DeviceClock
    private let invalidateReconnect: ReconnectInvalidation
    private let requestReconnect: ReconnectRequest
    private var context: Context?
    private var connectedGeneration: UInt?
    private var connectedPeripheralID: UUID?
    private var connectionWaiters: [UInt: ConnectionWaiter] = [:]
    private var invalidatingWaiters: [UInt64: ConnectionWaiter] = [:]
    private var nextAttemptSequence: UInt64 = 0

    init(
        clock: any DeviceClock = ContinuousDeviceClock(),
        invalidateReconnect: @escaping ReconnectInvalidation = { _ in },
        requestReconnect: @escaping ReconnectRequest = { _ in }
    ) {
        self.clock = clock
        self.invalidateReconnect = invalidateReconnect
        self.requestReconnect = requestReconnect
    }

    var pendingConnectionCount: Int { connectionWaiters.count }

    var hasConnectedContext: Bool {
        guard let context, context.lifecycle.isActive else { return false }
        return connectedGeneration == context.generation
            && connectedPeripheralID == context.peripheralID
    }

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
            beginInvalidation(
                attempt: waiter.attempt,
                failure: .superseded,
                includingPrepared: true
            )
        }
    }

    func detach(_ key: ContextKey) {
        guard context?.key == key else { return }
        context?.lifecycle.invalidate()
        context = nil
        connectedGeneration = nil
        connectedPeripheralID = nil
        if let waiter = connectionWaiters[key.generation],
           waiter.attempt.peripheralID == key.peripheralID,
           waiter.attempt.lifecycleID == key.lifecycleID {
            beginInvalidation(
                attempt: waiter.attempt,
                failure: .unavailable,
                includingPrepared: true
            )
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

    func prepareConnected(attempt: ConnectionAttempt) -> Bool {
        guard var waiter = connectionWaiters[attempt.generation],
              waiter.attempt == attempt,
              waiter.phase == .waiting,
              let context,
              context.generation == attempt.generation,
              context.peripheralID == attempt.peripheralID,
              context.lifecycle.id == attempt.lifecycleID,
              context.lifecycle.isActive
        else { return false }
        waiter.phase = .prepared
        waiter.timeoutTask.cancel()
        connectionWaiters[attempt.generation] = waiter
        connectedGeneration = attempt.generation
        connectedPeripheralID = attempt.peripheralID
        return true
    }

    func handleConnectionEvent(_ event: ConnectionEvent, attempt: ConnectionAttempt) {
        guard let waiter = connectionWaiters[attempt.generation],
              waiter.attempt == attempt
        else { return }
        guard let context,
              context.generation == attempt.generation,
              context.peripheralID == attempt.peripheralID,
              context.lifecycle.id == attempt.lifecycleID,
              context.lifecycle.isActive
        else {
            beginInvalidation(
                attempt: attempt,
                failure: .superseded,
                includingPrepared: true
            )
            return
        }
        switch event {
        case .connected:
            guard waiter.phase == .prepared else { return }
            connectedGeneration = attempt.generation
            connectedPeripheralID = attempt.peripheralID
            resolvePreparedWaiter(attempt: attempt, context: context)
        case .terminal:
            connectedGeneration = nil
            connectedPeripheralID = nil
            resolveTerminalWaiter(attempt: attempt)
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
        nextAttemptSequence &+= 1
        let attempt = ConnectionAttempt(
            generation: generation,
            peripheralID: peripheralID,
            lifecycleID: context.lifecycle.id,
            token: UUID(),
            sequence: nextAttemptSequence
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let existing = connectionWaiters[generation] {
                    beginInvalidation(
                        attempt: existing.attempt,
                        failure: .superseded,
                        includingPrepared: true
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
                    timeoutTask: timeoutTask,
                    phase: .waiting
                )

                Task { [requestReconnect] in await requestReconnect(attempt) }
            }
        } onCancel: {
            Task { [weak self] in await self?.cancelWaiter(attempt: attempt) }
        }
    }

    private func timeOutWaiter(attempt: ConnectionAttempt) {
        beginInvalidation(
            attempt: attempt,
            failure: .timedOut,
            includingPrepared: false
        )
    }

    private func cancelWaiter(attempt: ConnectionAttempt) {
        beginInvalidation(
            attempt: attempt,
            failure: .canceled,
            includingPrepared: false
        )
    }

    private func beginInvalidation(
        attempt: ConnectionAttempt,
        failure: WaiterFailure,
        includingPrepared: Bool
    ) {
        guard let current = connectionWaiters[attempt.generation],
              current.attempt == attempt,
              includingPrepared || current.phase == .waiting,
              let waiter = connectionWaiters.removeValue(forKey: attempt.generation)
        else { return }
        waiter.timeoutTask.cancel()
        connectedGeneration = nil
        connectedPeripheralID = nil
        invalidatingWaiters[attempt.sequence] = waiter
        Task { [weak self, invalidateReconnect] in
            await invalidateReconnect(attempt)
            await self?.finishInvalidation(attempt: attempt, failure: failure)
        }
    }

    private func finishInvalidation(
        attempt: ConnectionAttempt,
        failure: WaiterFailure
    ) {
        guard let waiter = invalidatingWaiters.removeValue(forKey: attempt.sequence),
              waiter.attempt == attempt
        else { return }
        switch failure {
        case .unavailable:
            waiter.continuation.resume(throwing: BrokerError.unavailable)
        case .superseded:
            waiter.continuation.resume(throwing: BrokerError.superseded)
        case .timedOut:
            waiter.continuation.resume(throwing: BrokerError.timedOut)
        case .canceled:
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    private func resolvePreparedWaiter(
        attempt: ConnectionAttempt,
        context: Context
    ) {
        guard let current = connectionWaiters[attempt.generation],
              current.attempt == attempt,
              current.phase == .prepared,
              let waiter = connectionWaiters.removeValue(forKey: attempt.generation)
        else { return }
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(returning: context)
    }

    private func resolveTerminalWaiter(attempt: ConnectionAttempt) {
        guard connectionWaiters[attempt.generation]?.attempt == attempt,
              let waiter = connectionWaiters.removeValue(forKey: attempt.generation)
        else { return }
        waiter.timeoutTask.cancel()
        connectedGeneration = nil
        connectedPeripheralID = nil
        waiter.continuation.resume(throwing: BrokerError.unavailable)
    }
}
