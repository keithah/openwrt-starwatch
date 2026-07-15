import Foundation

public enum DeviceConnectionState: Equatable, Sendable {
    case loading
    case live
    case disconnected
    case reconnecting
}

public enum TelemetryFreshness: Equatable, Sendable {
    case loading
    case live
    case stale
}

public struct PendingMutation: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let reconciler: MutationReconciler
    public let startedAt: DeviceTimestamp
    public let timeout: Duration
}

public struct DeviceState: Equatable, Sendable {
    public var identity: DeviceIdentitySnapshot?
    public var connection: DeviceConnectionState
    public var freshness: TelemetryFreshness
    public var battery: BatteryStatus?
    public var dc: DCPortStatus?
    public var typeC: TypeCPortStatus?
    public var lastTelemetryAt: DeviceTimestamp?
    public var pendingMutations: [PendingMutation]
    public var transactionDepth: Int
    public var lastError: String?

    public init(
        identity: DeviceIdentitySnapshot? = nil,
        connection: DeviceConnectionState = .loading,
        freshness: TelemetryFreshness = .loading,
        battery: BatteryStatus? = nil,
        dc: DCPortStatus? = nil,
        typeC: TypeCPortStatus? = nil,
        lastTelemetryAt: DeviceTimestamp? = nil,
        pendingMutations: [PendingMutation] = [],
        transactionDepth: Int = 0,
        lastError: String? = nil
    ) {
        self.identity = identity
        self.connection = connection
        self.freshness = freshness
        self.battery = battery
        self.dc = dc
        self.typeC = typeC
        self.lastTelemetryAt = lastTelemetryAt
        self.pendingMutations = pendingMutations
        self.transactionDepth = transactionDepth
        self.lastError = lastError
    }
}

public actor DeviceSession {
    public private(set) var state = DeviceState()

    private let transport: any DeviceTransport
    private let clock: any DeviceClock
    private let logicalOperations = SerializedTransactions()
    private var eventTask: Task<Void, Never>?
    private var freshnessGeneration: UInt64 = 0
    private var telemetryTimestamps: [TelemetryChannel: DeviceTimestamp] = [:]
    private(set) var logicalOperationDepth = 0

    var isEventConsumerRunning: Bool { eventTask != nil }

    public init(
        transport: any DeviceTransport,
        clock: any DeviceClock = ContinuousDeviceClock()
    ) {
        self.transport = transport
        self.clock = clock
    }

    deinit {
        eventTask?.cancel()
    }

    public func start() {
        guard eventTask == nil else { return }
        let events = transport.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.receive(event)
            }
            await self?.eventStreamDidFinish()
        }
    }

    private func eventStreamDidFinish() {
        eventTask = nil
    }

    public func receive(_ event: DeviceEvent) async {
        switch event {
        case .discovered:
            break
        case let .handshakeCompleted(snapshot):
            state.identity = snapshot
        case .connected:
            state.connection = .loading
            state.lastError = nil
        case .reconnecting:
            state.connection = .reconnecting
        case let .disconnected(failure):
            state.connection = .disconnected
            state.freshness = .stale
            state.lastError = failure?.message
        case let .battery(status, timestamp):
            guard let timing = await prepareTelemetry(channel: .battery, timestamp: timestamp) else {
                return
            }
            state.battery = status
            finishTelemetry(.none, timing: timing)
        case let .dc(status, timestamp):
            guard let timing = await prepareTelemetry(channel: .dc, timestamp: timestamp) else {
                return
            }
            state.dc = status
            finishTelemetry(.dc(status), timing: timing)
        case let .typeC(status, timestamp):
            guard let timing = await prepareTelemetry(channel: .typeC, timestamp: timestamp) else {
                return
            }
            state.typeC = status
            finishTelemetry(.typeC(status), timing: timing)
        case let .transactionDepth(depth):
            state.transactionDepth = depth
        }
    }

    @discardableResult
    public func perform(_ command: DeviceCommand) async throws -> CommandOutcome {
        logicalOperationDepth += 1
        let mutation = await makePendingMutation(for: command)
        if let mutation {
            state.pendingMutations.append(mutation)
            scheduleTimeout(for: mutation)
        }

        do {
            let outcome = try await logicalOperations.enqueue { [self] in
                try await performLogicalOperation(command)
            }
            logicalOperationDepth -= 1
            return outcome
        } catch {
            if let mutation { removePendingMutation(id: mutation.id) }
            state.lastError = String(describing: error)
            logicalOperationDepth -= 1
            throw error
        }
    }

    private func performLogicalOperation(_ command: DeviceCommand) async throws -> CommandOutcome {
        var outcome = try await transport.perform(command)
        if let followUp = command.followUp {
            outcome = try await transport.perform(followUp.command)
        }
        return outcome
    }

    private func makePendingMutation(for command: DeviceCommand) async -> PendingMutation? {
        guard command.reconciler != .none, let timeout = command.timeout else { return nil }
        return PendingMutation(
            id: UUID(),
            reconciler: command.reconciler,
            startedAt: await clock.now,
            timeout: timeout
        )
    }

    private enum TelemetryChannel: Hashable {
        case battery
        case dc
        case typeC
    }

    private struct TelemetryTiming {
        let remainingFreshness: Duration?
        let generation: UInt64
    }

    private func prepareTelemetry(
        channel: TelemetryChannel,
        timestamp: DeviceTimestamp
    ) async -> TelemetryTiming? {
        if let latest = telemetryTimestamps[channel], timestamp < latest { return nil }
        let now = await clock.now
        // The clock access above is an actor suspension point, so validate ordering again.
        if let latest = telemetryTimestamps[channel], timestamp < latest { return nil }
        telemetryTimestamps[channel] = timestamp

        guard state.lastTelemetryAt.map({ timestamp >= $0 }) ?? true else {
            return TelemetryTiming(remainingFreshness: nil, generation: freshnessGeneration)
        }

        let age = max(now - timestamp, .zero)
        let remaining = .seconds(10) - age
        state.connection = .live
        state.freshness = remaining > .zero ? .live : .stale
        state.lastTelemetryAt = timestamp
        freshnessGeneration &+= 1
        return TelemetryTiming(remainingFreshness: remaining, generation: freshnessGeneration)
    }

    private func finishTelemetry(_ update: TelemetryUpdate?, timing: TelemetryTiming) {
        if let update {
            state.pendingMutations.removeAll { $0.reconciler.matches(update) }
        }

        guard let remaining = timing.remainingFreshness, remaining > .zero else { return }
        Task { [weak self, clock] in
            do {
                try await clock.sleep(for: remaining)
                await self?.markStale(ifGenerationIs: timing.generation)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func markStale(ifGenerationIs generation: UInt64) {
        guard freshnessGeneration == generation, state.freshness == .live else { return }
        state.freshness = .stale
    }

    private func scheduleTimeout(for mutation: PendingMutation) {
        Task { [weak self, clock] in
            do {
                let elapsed = max(await clock.now - mutation.startedAt, .zero)
                let remaining = mutation.timeout - elapsed
                guard remaining > .zero else {
                    await self?.timeOutMutation(id: mutation.id)
                    return
                }
                try await clock.sleep(for: remaining)
                await self?.timeOutMutation(id: mutation.id)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func timeOutMutation(id: UUID) {
        guard state.pendingMutations.contains(where: { $0.id == id }) else { return }
        removePendingMutation(id: id)
        state.lastError = "Device did not confirm the requested change."
    }

    private func removePendingMutation(id: UUID) {
        state.pendingMutations.removeAll { $0.id == id }
    }
}
