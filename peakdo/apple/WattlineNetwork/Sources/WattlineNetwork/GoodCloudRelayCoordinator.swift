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
    }

    private let deviceID: String
    private let provisioner: any GoodCloudRelayProvisioning
    private let relayClientFactory: RelayClientFactory
    private var currentSession: RemoteAccessSession?
    private var sessionGeneration: UInt64 = 0
    private var provisioning: Provisioning?

    public init(
        deviceID: String,
        provisioner: any GoodCloudRelayProvisioning,
        relayClient: @escaping RelayClientFactory = { RelayHTTPClient(session: $0) }
    ) {
        self.deviceID = deviceID
        self.provisioner = provisioner
        self.relayClientFactory = relayClient
    }

    public func session() async throws -> RemoteAccessSession {
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
            let task = Task {
                try await provisioner.remoteAccess(
                    deviceID: deviceID,
                    port: Self.wattlinedPort
                )
            }
            operation = Provisioning(id: id, task: task)
            provisioning = operation
        }

        do {
            let provisionedSession = try await operation.task.value
            if let currentSession {
                return currentSession
            }
            if provisioning?.id == operation.id {
                provisioning = nil
                sessionGeneration &+= 1
                currentSession = provisionedSession
            }
            try Task.checkCancellation()
            return currentSession ?? provisionedSession
        } catch {
            if provisioning?.id == operation.id {
                provisioning = nil
            }
            throw Self.normalized(error)
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
        AsyncThrowingStream { continuation in
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

    private func makeLease() async throws -> SessionLease {
        let provisionedSession = try await session()
        return SessionLease(
            client: relayClientFactory(provisionedSession),
            generation: sessionGeneration
        )
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
