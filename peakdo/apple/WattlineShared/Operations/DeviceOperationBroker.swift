import Foundation
import WattlineCore

actor DeviceOperationBroker {
    struct Context: Sendable {
        let generation: UInt
        let peripheralID: UUID
        let transport: any DeviceTransport
        let session: DeviceSession
    }

    enum BrokerError: Error, Equatable {
        case unavailable
        case superseded
        case timedOut
    }

    enum ConnectionEvent: Equatable, Sendable {
        case connected(UUID)
        case terminal
    }

    typealias ReconnectRequest = @Sendable (UUID, UInt) async -> Void

    private struct ConnectionWaiter {
        let token: UUID
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
        requestReconnect: @escaping ReconnectRequest = { _, _ in }
    ) {
        self.clock = clock
        self.requestReconnect = requestReconnect
    }

    var pendingConnectionCount: Int { connectionWaiters.count }

    func attach(_ context: Context) {
        if let current = self.context, context.generation < current.generation {
            return
        }

        let preservesConnectedContext = self.context?.generation == context.generation
            && self.context?.peripheralID == context.peripheralID
        let supersededGenerations = connectionWaiters.keys.filter { $0 != context.generation }
        self.context = context
        if !preservesConnectedContext || connectedGeneration != context.generation {
            connectedGeneration = nil
            connectedPeripheralID = nil
        }
        for generation in supersededGenerations {
            resolveWaiter(generation: generation, result: .failure(BrokerError.superseded))
        }
    }

    func detach(generation: UInt) {
        guard context?.generation == generation else { return }
        context = nil
        connectedGeneration = nil
        connectedPeripheralID = nil
        resolveWaiter(generation: generation, result: .failure(BrokerError.unavailable))
    }

    func handleConnectionEvent(_ event: ConnectionEvent, generation: UInt) {
        guard let context, context.generation == generation else { return }
        switch event {
        case let .connected(peripheralID):
            guard peripheralID == context.peripheralID else { return }
            connectedGeneration = generation
            connectedPeripheralID = peripheralID
            resolveWaiter(generation: generation, result: .success(context))
        case .terminal:
            connectedGeneration = nil
            connectedPeripheralID = nil
            resolveWaiter(generation: generation, result: .failure(BrokerError.unavailable))
        }
    }

    func perform(
        _ command: DeviceCommand,
        generation: UInt
    ) async throws -> CommandOutcome {
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
        guard let context else { throw BrokerError.unavailable }
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
        return try await operation(connectedContext)
    }

    private func context(for generation: UInt) throws -> Context {
        guard let context else { throw BrokerError.unavailable }
        guard context.generation == generation else { throw BrokerError.superseded }
        return context
    }

    private func waitForConnection(
        peripheralID: UUID,
        generation: UInt,
        timeout: Duration
    ) async throws -> Context {
        let token = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if connectionWaiters[generation] != nil {
                    resolveWaiter(
                        generation: generation,
                        result: .failure(BrokerError.superseded)
                    )
                }

                let timeoutTask = Task { [weak self, clock] in
                    do {
                        try await clock.sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.timeOutWaiter(generation: generation, token: token)
                }
                connectionWaiters[generation] = ConnectionWaiter(
                    token: token,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )

                Task { [requestReconnect] in
                    await requestReconnect(peripheralID, generation)
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelWaiter(generation: generation, token: token)
            }
        }
    }

    private func timeOutWaiter(generation: UInt, token: UUID) {
        guard connectionWaiters[generation]?.token == token else { return }
        resolveWaiter(generation: generation, result: .failure(BrokerError.timedOut))
    }

    private func cancelWaiter(generation: UInt, token: UUID) {
        guard connectionWaiters[generation]?.token == token else { return }
        resolveWaiter(generation: generation, result: .failure(CancellationError()))
    }

    private func resolveWaiter(generation: UInt, result: Result<Context, Error>) {
        guard let waiter = connectionWaiters.removeValue(forKey: generation) else { return }
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(with: result)
    }
}
