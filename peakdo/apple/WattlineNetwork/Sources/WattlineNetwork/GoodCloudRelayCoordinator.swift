import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GoodCloudKit

public protocol RemoteRelayClient: Sendable {
    func request(
        method: String,
        path: String,
        headers: [String: String],
        body: Data?
    ) async throws -> (Data, HTTPURLResponse)

    func stream(
        method: String,
        path: String,
        headers: [String: String],
        body: Data?
    ) -> AsyncThrowingStream<RelayHTTPStreamEvent, Error>
}

extension RelayHTTPClient: RemoteRelayClient {}

/// Marks relay-attempt boundaries explicitly so stream consumers can discard
/// response and parser state when the coordinator reprovisions an expired relay.
public enum RemoteRelayStreamEvent: @unchecked Sendable {
    case attemptStarted
    case response(HTTPURLResponse)
    case data(Data)
}

public protocol RemoteRelayCoordinating: Sendable {
    func request(
        method: String,
        path: String,
        headers: [String: String],
        body: Data?
    ) async throws -> (Data, HTTPURLResponse)

    func stream(
        method: String,
        path: String,
        headers: [String: String],
        body: Data?
    ) async -> AsyncThrowingStream<RemoteRelayStreamEvent, Error>
}

public actor GoodCloudRelayCoordinator: RemoteRelayCoordinating {
    public static let wattlinedPort = 8377

    public typealias RelayClientFactory = @Sendable (RemoteAccessSession) -> any RemoteRelayClient

    private struct SessionLease: Sendable {
        let client: any RemoteRelayClient
        let generation: UInt64
    }

    private struct Provisioning: Sendable {
        let id: UUID
        let task: Task<RemoteAccessSession, Error>
        let waiters: ProvisioningWaiterFanout
    }

    private let deviceID: String
    private let provisioner: any GoodCloudRelayProvisioning
    private let relayClientFactory: RelayClientFactory
    private let onBeforeOrphanRetry: @Sendable (Int) async -> Void
    private let onBeforeProvisioningWait: @Sendable (UUID, Int) async -> Void
    private var currentSession: RemoteAccessSession?
    private var sessionGeneration: UInt64 = 0
    private var provisioning: Provisioning?
    private var hasStartedSSEBatch = false

    public init(
        deviceID: String,
        provisioner: any GoodCloudRelayProvisioning,
        relayClient: @escaping RelayClientFactory = { RelayHTTPClient(session: $0) }
    ) {
        self.deviceID = deviceID
        self.provisioner = provisioner
        self.relayClientFactory = relayClient
        self.onBeforeOrphanRetry = { _ in }
        self.onBeforeProvisioningWait = { _, _ in }
    }

    public static func production(
        deviceID: String,
        provisioner: any GoodCloudRelayProvisioning
    ) -> GoodCloudRelayCoordinator {
        GoodCloudRelayCoordinator(
            deviceID: deviceID,
            provisioner: provisioner,
            relayClient: { RelayHTTPClient(session: $0) }
        )
    }

    init(
        deviceID: String,
        provisioner: any GoodCloudRelayProvisioning,
        relayClient: @escaping RelayClientFactory,
        onBeforeOrphanRetry: @escaping @Sendable (Int) async -> Void,
        onBeforeProvisioningWait: @escaping @Sendable (UUID, Int) async -> Void
    ) {
        self.deviceID = deviceID
        self.provisioner = provisioner
        self.relayClientFactory = relayClient
        self.onBeforeOrphanRetry = onBeforeOrphanRetry
        self.onBeforeProvisioningWait = onBeforeProvisioningWait
    }

    public func session() async throws -> RemoteAccessSession {
        try await session(orphanRetriesRemaining: 1)
    }

    private func session(orphanRetriesRemaining: Int) async throws -> RemoteAccessSession {
        try Task.checkCancellation()
        if let currentSession {
            return currentSession
        }

        let operation: Provisioning
        if let provisioning {
            operation = provisioning
        } else {
            let id = UUID()
            let deviceID = self.deviceID
            let provisioner = self.provisioner
            let waiters = ProvisioningWaiterFanout()
            let task = Task {
                try await provisioner.remoteAccess(
                    deviceID: deviceID,
                    port: Self.wattlinedPort
                )
            }
            operation = Provisioning(id: id, task: task, waiters: waiters)
            provisioning = operation
            observeCompletion(of: operation)
        }

        await onBeforeProvisioningWait(operation.id, orphanRetriesRemaining)
        try Task.checkCancellation()
        switch await operation.waiters.wait() {
        case .waiterCancelled:
            throw CancellationError()
        case .sharedFailure(let error, let joinedOrphanedProvisioning):
            guard joinedOrphanedProvisioning, orphanRetriesRemaining > 0 else {
                throw Self.normalized(error)
            }
            try Task.checkCancellation()
            let retriesRemaining = orphanRetriesRemaining - 1
            await onBeforeOrphanRetry(retriesRemaining)
            try Task.checkCancellation()
            return try await session(orphanRetriesRemaining: retriesRemaining)
        case .success(let provisionedSession, joinedOrphanedProvisioning: _):
            try Task.checkCancellation()
            return currentSession ?? provisionedSession
        }
    }

    public func request(
        method: String,
        path: String,
        headers: [String: String],
        body: Data?
    ) async throws -> (Data, HTTPURLResponse) {
        let shouldRetry = method.uppercased() == "GET"
        var attempt = 0

        while true {
            let lease = try await makeLease()
            try Task.checkCancellation()
            do {
                return try await lease.client.request(
                    method: method,
                    path: path,
                    headers: headers,
                    body: body
                )
            } catch {
                guard Self.isSessionExpired(error) else {
                    throw Self.normalized(error)
                }
                invalidate(generation: lease.generation)
                guard shouldRetry, attempt == 0 else {
                    throw NetworkError.goodCloudSessionExpired
                }
                attempt += 1
            }
        }
    }

    public func stream(
        method: String,
        path: String,
        headers: [String: String],
        body: Data?
    ) async -> AsyncThrowingStream<RemoteRelayStreamEvent, Error> {
        beginSSEBatch()
        return AsyncThrowingStream { continuation in
            let task = Task {
                var attempt = 0
                do {
                    while true {
                        try Task.checkCancellation()
                        let lease = try await self.makeLease()
                        try Task.checkCancellation()
                        do {
                            continuation.yield(.attemptStarted)
                            try Task.checkCancellation()
                            let relayStream = lease.client.stream(
                                method: method,
                                path: path,
                                headers: headers,
                                body: body
                            )
                            for try await event in relayStream {
                                try Task.checkCancellation()
                                switch event {
                                case .response(let response):
                                    continuation.yield(.response(response))
                                case .data(let data):
                                    continuation.yield(.data(data))
                                }
                            }
                            continuation.finish()
                            return
                        } catch {
                            guard Self.isSessionExpired(error) else {
                                throw Self.normalized(error)
                            }
                            self.invalidate(generation: lease.generation)
                            guard attempt == 0 else {
                                throw NetworkError.goodCloudSessionExpired
                            }
                            attempt += 1
                        }
                    }
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func beginSSEBatch() {
        if hasStartedSSEBatch {
            currentSession = nil
        } else {
            hasStartedSSEBatch = true
        }
    }

    private func makeLease() async throws -> SessionLease {
        let provisionedSession = try await session()
        return SessionLease(
            client: relayClientFactory(provisionedSession),
            generation: sessionGeneration
        )
    }

    private func observeCompletion(of operation: Provisioning) {
        Task.detached { [weak self] in
            let outcome: SharedProvisioningOutcome = switch await operation.task.result {
            case .success(let session): .success(session)
            case .failure(let error): .failure(error)
            }
            if let self {
                await self.completeProvisioning(id: operation.id, outcome: outcome)
            }
            operation.waiters.complete(with: outcome)
        }
    }

    private func completeProvisioning(
        id: UUID,
        outcome: SharedProvisioningOutcome
    ) {
        guard provisioning?.id == id else { return }
        provisioning = nil
        if case .success(let session) = outcome {
            sessionGeneration &+= 1
            currentSession = session
        }
    }

    private func invalidate(generation: UInt64) {
        guard generation == sessionGeneration else { return }
        currentSession = nil
    }

    private static func isSessionExpired(_ error: any Error) -> Bool {
        if error as? NetworkError == .goodCloudSessionExpired {
            return true
        }
        guard let goodCloudError = error as? GoodCloudError else {
            return false
        }
        switch goodCloudError {
        case .sessionExpired:
            return true
        case .api(code: -1010, message: _):
            return true
        default:
            return false
        }
    }

    private static func normalized(_ error: any Error) -> any Error {
        if error is CancellationError {
            return CancellationError()
        }
        if let networkError = error as? NetworkError {
            return networkError
        }
        if isSessionExpired(error) {
            return NetworkError.goodCloudSessionExpired
        }
        return NetworkError.transport("GoodCloud relay request failed")
    }
}

private enum SharedProvisioningOutcome: @unchecked Sendable {
    case success(RemoteAccessSession)
    case failure(any Error)
}

private enum ProvisioningWaitOutcome: @unchecked Sendable {
    case success(RemoteAccessSession, joinedOrphanedProvisioning: Bool)
    case sharedFailure(any Error, joinedOrphanedProvisioning: Bool)
    case waiterCancelled
}

/// Fans one provisioning completion out to independently cancellable waiters.
/// The coordinator owns exactly one shared completion observer; this object
/// only registers, cancels, and resumes individual continuations.
private final class ProvisioningWaiterFanout: @unchecked Sendable {
    private struct Waiter {
        let continuation: CheckedContinuation<ProvisioningWaitOutcome, Never>
        let joinedOrphanedProvisioning: Bool
    }

    private enum Registration {
        case registered
        case resume(ProvisioningWaitOutcome)
    }

    private let lock = NSLock()
    private var sharedOutcome: SharedProvisioningOutcome?
    private var waiters: [UUID: Waiter] = [:]
    private var cancelledBeforeRegistration: Set<UUID> = []
    private var wasOrphaned = false

    func wait() async -> ProvisioningWaitOutcome {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let registration = lock.withLock { () -> Registration in
                    if cancelledBeforeRegistration.remove(id) != nil {
                        if waiters.isEmpty {
                            wasOrphaned = true
                        }
                        return .resume(.waiterCancelled)
                    }
                    if let sharedOutcome {
                        return .resume(Self.waitOutcome(
                            for: sharedOutcome,
                            joinedOrphanedProvisioning: wasOrphaned
                        ))
                    }
                    waiters[id] = Waiter(
                        continuation: continuation,
                        joinedOrphanedProvisioning: wasOrphaned
                    )
                    return .registered
                }

                switch registration {
                case .resume(let outcome):
                    continuation.resume(returning: outcome)
                case .registered:
                    break
                }
            }
        } onCancel: {
            self.cancel(id: id)
        }
    }

    func complete(with outcome: SharedProvisioningOutcome) {
        typealias Resumption = (
            CheckedContinuation<ProvisioningWaitOutcome, Never>,
            ProvisioningWaitOutcome
        )
        let resumptions: [Resumption] = lock.withLock {
            guard sharedOutcome == nil else { return [] }
            sharedOutcome = outcome
            let resumptions = waiters.values.map { waiter in
                (
                    waiter.continuation,
                    Self.waitOutcome(
                        for: outcome,
                        joinedOrphanedProvisioning: waiter.joinedOrphanedProvisioning
                    )
                )
            }
            waiters.removeAll()
            return resumptions
        }
        resumptions.forEach { continuation, outcome in
            continuation.resume(returning: outcome)
        }
    }

    private func cancel(id: UUID) {
        let continuation: CheckedContinuation<ProvisioningWaitOutcome, Never>? = lock.withLock {
            guard sharedOutcome == nil else { return nil }
            guard let waiter = waiters.removeValue(forKey: id) else {
                cancelledBeforeRegistration.insert(id)
                return nil
            }
            if waiters.isEmpty {
                wasOrphaned = true
            }
            return waiter.continuation
        }
        continuation?.resume(returning: .waiterCancelled)
    }

    private static func waitOutcome(
        for outcome: SharedProvisioningOutcome,
        joinedOrphanedProvisioning: Bool
    ) -> ProvisioningWaitOutcome {
        switch outcome {
        case .success(let session):
            .success(
                session,
                joinedOrphanedProvisioning: joinedOrphanedProvisioning
            )
        case .failure(let error):
            .sharedFailure(
                error,
                joinedOrphanedProvisioning: joinedOrphanedProvisioning
            )
        }
    }
}
