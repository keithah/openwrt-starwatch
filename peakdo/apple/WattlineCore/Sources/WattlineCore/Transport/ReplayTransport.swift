import Foundation

public enum ReplayStep: Sendable {
    case reply(after: Duration = .zero, bytes: Data)
    case telemetry(DeviceEvent)
    case delay(Duration)
    case writeFailure(any Error & Sendable)
    case disconnect(error: any Error & Sendable)
}
public enum ReplayTransportError: Error, Equatable, Sendable {
    case exhausted
    case disconnected(String)
    case writeFailed(String)
}

public enum ReconnectPolicy: Equatable, Sendable {
    case armed
    case awaitingOTAMode
    case disarmed
}

public actor ReplayTransport: DeviceTransport {
    public nonisolated let events: AsyncStream<DeviceEvent>

    private let continuation: AsyncStream<DeviceEvent>.Continuation
    private let transactions = SerializedTransactions()
    private let clock: any DeviceClock
    private var steps: [ReplayStep]
    private var currentInFlightCount = 0

    public private(set) var maximumInFlightCount = 0
    public private(set) var pendingTransactionCount = 0
    public private(set) var maximumPendingTransactionCount = 0
    public private(set) var reconnectPolicy: ReconnectPolicy = .armed

    public var inFlightCount: Int { currentInFlightCount }

    public init(
        steps: [ReplayStep] = [],
        clock: any DeviceClock = ContinuousDeviceClock()
    ) {
        let pair = AsyncStream<DeviceEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
        self.steps = steps
        self.clock = clock
    }

    deinit {
        continuation.finish()
    }

    public func startScan() async throws {}

    public func stopScan() async {}

    public func connect(to id: UUID) async throws {
        continuation.yield(.connected(id))
    }

    public func disconnect() async {
        continuation.yield(.disconnected(nil))
    }

    public func perform(_ command: DeviceCommand) async throws -> CommandOutcome {
        beginTransaction()
        do {
            let outcome = try await transactions.enqueue { [self] in
                try await execute(command)
            }
            endTransaction()
            return outcome
        } catch {
            endTransaction()
            throw error
        }
    }

    public func refreshTelemetry() async throws {
        beginTransaction()
        do {
            try await transactions.enqueue { [self] in
                try await executeTelemetryRefresh()
            }
            endTransaction()
        } catch {
            endTransaction()
            throw error
        }
    }

    private func beginTransaction() {
        pendingTransactionCount += 1
        maximumPendingTransactionCount = max(
            maximumPendingTransactionCount,
            pendingTransactionCount
        )
        continuation.yield(.transactionDepth(pendingTransactionCount))
    }

    private func endTransaction() {
        pendingTransactionCount -= 1
        continuation.yield(.transactionDepth(pendingTransactionCount))
    }

    private func execute(_ command: DeviceCommand) async throws -> CommandOutcome {
        beginExecution()
        defer { endExecution() }

        while true {
            let step = try nextStep()
            switch step {
            case let .reply(delay, bytes):
                if delay > .zero { try await clock.sleep(for: delay) }
                return .reply(try command.validate(bytes))
            case let .telemetry(event):
                continuation.yield(event)
            case let .delay(duration):
                try await clock.sleep(for: duration)
            case let .writeFailure(error):
                throw ReplayTransportError.writeFailed(String(describing: error))
            case let .disconnect(error):
                continuation.yield(
                    .disconnected(TransportFailure(message: String(describing: error)))
                )
                switch command.disconnectPolicy {
                case .none:
                    throw ReplayTransportError.disconnected(String(describing: error))
                case .successThenReconnect:
                    reconnectPolicy = .armed
                case .successThenAwaitOTAMode:
                    reconnectPolicy = .awaitingOTAMode
                case .successThenDisarmReconnect:
                    reconnectPolicy = .disarmed
                }
                return .sent
            }
        }
    }

    private func executeTelemetryRefresh() async throws {
        beginExecution()
        defer { endExecution() }

        while !steps.isEmpty {
            let step = try nextStep()
            switch step {
            case let .telemetry(event):
                continuation.yield(event)
            case let .delay(duration):
                try await clock.sleep(for: duration)
            case .reply, .writeFailure, .disconnect:
                steps.insert(step, at: 0)
                return
            }
        }
    }

    private func nextStep() throws -> ReplayStep {
        guard !steps.isEmpty else { throw ReplayTransportError.exhausted }
        return steps.removeFirst()
    }

    private func beginExecution() {
        currentInFlightCount += 1
        maximumInFlightCount = max(maximumInFlightCount, currentInFlightCount)
    }

    private func endExecution() {
        currentInFlightCount -= 1
    }
}
