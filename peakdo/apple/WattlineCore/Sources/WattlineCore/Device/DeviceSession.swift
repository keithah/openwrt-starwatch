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
    private var eventTask: Task<Void, Never>?
    private var freshnessGeneration: UInt64 = 0

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
        }
    }

    public func receive(_ event: DeviceEvent) async {
        switch event {
        case .discovered:
            break
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
            state.battery = status
            receiveTelemetry(.none, timestamp: timestamp)
        case let .dc(status, timestamp):
            state.dc = status
            receiveTelemetry(.dc(status), timestamp: timestamp)
        case let .typeC(status, timestamp):
            state.typeC = status
            receiveTelemetry(.typeC(status), timestamp: timestamp)
        case let .transactionDepth(depth):
            state.transactionDepth = depth
        }
    }

    @discardableResult
    public func perform(_ command: DeviceCommand) async throws -> CommandOutcome {
        let mutation = await makePendingMutation(for: command)
        if let mutation { state.pendingMutations.append(mutation) }

        do {
            var outcome = try await transport.perform(command)
            if let followUp = command.followUp {
                outcome = try await transport.perform(followUp.command)
            }
            if let mutation,
               state.pendingMutations.contains(where: { $0.id == mutation.id }) {
                scheduleTimeout(for: mutation)
            }
            return outcome
        } catch {
            if let mutation { removePendingMutation(id: mutation.id) }
            state.lastError = String(describing: error)
            throw error
        }
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

    private func receiveTelemetry(_ update: TelemetryUpdate?, timestamp: DeviceTimestamp) {
        state.connection = .live
        state.freshness = .live
        state.lastTelemetryAt = timestamp
        if let update {
            state.pendingMutations.removeAll { $0.reconciler.matches(update) }
        }

        freshnessGeneration &+= 1
        let generation = freshnessGeneration
        Task { [weak self, clock] in
            do {
                try await clock.sleep(for: .seconds(10))
                await self?.markStale(ifGenerationIs: generation)
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
                try await clock.sleep(for: mutation.timeout)
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
