import Foundation
import GoodCloudKit

public struct GoodCloudDeviceSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let mac: String
    public let ddns: String?
    public let model: String
    public let isOnline: Bool

    public init(
        id: String,
        name: String,
        mac: String,
        ddns: String?,
        model: String,
        isOnline: Bool
    ) {
        self.id = id
        self.name = name
        self.mac = mac
        self.ddns = ddns
        self.model = model
        self.isOnline = isOnline
    }

    init(device: GoodCloudDevice) {
        self.init(
            id: device.id,
            name: device.name,
            mac: device.mac,
            ddns: device.ddns,
            model: device.model,
            isOnline: device.isOnline
        )
    }
}

public enum GoodCloudSessionState: Equatable, Sendable {
    case loggedOut
    case loading
    case authenticated([GoodCloudDeviceSummary])
    case requiresLogin
    case failed(String)
}

public protocol GoodCloudAccountClient: Sendable {
    func hasStoredToken() async -> Bool
    func login(email: String, password: String) async throws
    func devices() async throws -> [GoodCloudDeviceSummary]
    func logout() async throws
}

public protocol GoodCloudAccountServing: Sendable {
    func validateStoredSession() async -> GoodCloudSessionState
    func login(email: String, password: String) async -> GoodCloudSessionState
    func refreshDevices() async -> GoodCloudSessionState
    func logout() async
}

public protocol GoodCloudRelayProvisioning: Sendable {
    func remoteAccess(deviceID: String, port: Int) async throws -> RemoteAccessSession
}

public actor GoodCloudAccountService: GoodCloudAccountServing, GoodCloudRelayProvisioning {
    public private(set) var state: GoodCloudSessionState = .loggedOut
    private var operationGeneration: UInt64 = 0

    private static let redactedFailure = "GoodCloud request failed."

    private let auth: GoodCloudAuth?
    private let client: (any GoodCloudAccountClient)?
    private let provisionRemoteAccess: @Sendable (String, Int) async throws -> RemoteAccessSession
    private let operations: GoodCloudAccountOperationLock

    public init(auth: GoodCloudAuth = GoodCloudAuth()) {
        self.auth = auth
        self.client = nil
        self.provisionRemoteAccess = { deviceID, port in
            let client = SignedAPIClient(tokens: PasswordTokenProvider(auth: auth))
            return try await client.remoteAccess(deviceID: deviceID, port: port)
        }
        self.operations = GoodCloudAccountOperationLock()
    }

    public init(
        client: any GoodCloudAccountClient,
        remoteAccess: @escaping @Sendable (String, Int) async throws -> RemoteAccessSession = { _, _ in
            throw GoodCloudError.relayUnavailable
        }
    ) {
        self.auth = nil
        self.client = client
        self.provisionRemoteAccess = remoteAccess
        self.operations = GoodCloudAccountOperationLock()
    }

    init(
        client: any GoodCloudAccountClient,
        onOperationQueued: @escaping @Sendable () -> Void
    ) {
        self.auth = nil
        self.client = client
        self.provisionRemoteAccess = { _, _ in
            throw GoodCloudError.relayUnavailable
        }
        self.operations = GoodCloudAccountOperationLock(onQueued: onOperationQueued)
    }

    public func validateStoredSession() async -> GoodCloudSessionState {
        guard await operations.acquire() else { return state }
        guard !Task.isCancelled else {
            operations.release()
            return state
        }
        defer { operations.release() }
        let generation = beginOperation()
        state = .loading
        guard await hasStoredToken() else {
            return publish(.loggedOut, for: generation)
        }
        do {
            let devices = try await loadDevices()
            return publish(.authenticated(devices), for: generation)
        } catch {
            return await stateForFailure(error, generation: generation)
        }
    }

    public func login(email: String, password: String) async -> GoodCloudSessionState {
        guard await operations.acquire() else { return state }
        guard !Task.isCancelled else {
            operations.release()
            return state
        }
        defer { operations.release() }
        let generation = beginOperation()
        state = .loading
        do {
            try await performLogin(email: email, password: password)
            let devices = try await loadDevices()
            return publish(.authenticated(devices), for: generation)
        } catch {
            return await stateForFailure(error, generation: generation)
        }
    }

    public func refreshDevices() async -> GoodCloudSessionState {
        guard await operations.acquire() else { return state }
        guard !Task.isCancelled else {
            operations.release()
            return state
        }
        defer { operations.release() }
        let generation = beginOperation()
        state = .loading
        do {
            let devices = try await loadDevices()
            return publish(.authenticated(devices), for: generation)
        } catch {
            return await stateForFailure(error, generation: generation)
        }
    }

    public func logout() async {
        guard await operations.acquire() else { return }
        guard !Task.isCancelled else {
            operations.release()
            return
        }
        defer { operations.release() }
        let generation = beginOperation()
        do {
            try await clearSession()
            _ = publish(.loggedOut, for: generation)
        } catch {
            _ = publish(.failed(Self.redactedFailure), for: generation)
        }
    }

    public func remoteAccess(deviceID: String, port: Int) async throws -> RemoteAccessSession {
        guard await operations.acquire() else { throw CancellationError() }
        guard !Task.isCancelled else {
            operations.release()
            throw CancellationError()
        }
        defer { operations.release() }
        do {
            return try await provisionRemoteAccess(deviceID, port)
        } catch {
            if case let GoodCloudError.api(code, _) = error {
                guard code == -1010 else {
                    throw GoodCloudError.relayUnavailable
                }
                let generation = beginOperation()
                let failureState = await stateForFailure(error, generation: generation)
                guard failureState == .requiresLogin else {
                    throw GoodCloudError.authFailed
                }
                throw GoodCloudError.sessionExpired
            }
            throw error
        }
    }

    private func hasStoredToken() async -> Bool {
        if let client {
            return await client.hasStoredToken()
        }
        guard let auth,
              let token = try? await auth.currentToken()
        else {
            return false
        }
        return !token.isEmpty
    }

    private func performLogin(email: String, password: String) async throws {
        if let client {
            try await client.login(email: email, password: password)
        } else if let auth {
            try await auth.logIn(email: email, password: password)
        }
    }

    private func loadDevices() async throws -> [GoodCloudDeviceSummary] {
        if let client {
            return try await client.devices()
        }
        guard let auth else { return [] }
        let client = SignedAPIClient(tokens: PasswordTokenProvider(auth: auth))
        return try await client.devices().map(GoodCloudDeviceSummary.init(device:))
    }

    private func clearSession() async throws {
        if let client {
            try await client.logout()
        } else if let auth {
            try await auth.logOut()
        }
    }

    private func beginOperation() -> UInt64 {
        operationGeneration &+= 1
        return operationGeneration
    }

    private func publish(
        _ newState: GoodCloudSessionState,
        for generation: UInt64
    ) -> GoodCloudSessionState {
        guard generation == operationGeneration else { return state }
        state = newState
        return state
    }

    private func stateForFailure(
        _ error: any Error,
        generation: UInt64
    ) async -> GoodCloudSessionState {
        guard generation == operationGeneration else { return state }
        if case GoodCloudError.api(code: -1010, message: _) = error {
            do {
                try await clearSession()
                return publish(.requiresLogin, for: generation)
            } catch {
                return publish(.failed(Self.redactedFailure), for: generation)
            }
        }
        return publish(.failed(Self.redactedFailure), for: generation)
    }
}

private final class GoodCloudAccountOperationLock: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private enum Registration {
        case acquired
        case cancelled
        case queued
    }

    private let lock = NSLock()
    private let onQueued: @Sendable () -> Void
    private var isAcquired = false
    private var waiters: [Waiter] = []

    init(onQueued: @escaping @Sendable () -> Void = {}) {
        self.onQueued = onQueued
    }

    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let registration = lock.withLock {
                    guard !Task.isCancelled else {
                        return Registration.cancelled
                    }
                    guard isAcquired else {
                        isAcquired = true
                        return Registration.acquired
                    }
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                    return Registration.queued
                }
                switch registration {
                case .acquired:
                    continuation.resume(returning: true)
                case .cancelled:
                    continuation.resume(returning: false)
                case .queued:
                    onQueued()
                }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Bool, Never>? = self.lock.withLock {
                guard let index = self.waiters.firstIndex(where: { $0.id == waiterID }) else {
                    return nil
                }
                return self.waiters.remove(at: index).continuation
            }
            continuation?.resume(returning: false)
        }
    }

    func release() {
        let next: CheckedContinuation<Bool, Never>? = lock.withLock {
            guard !waiters.isEmpty else {
                isAcquired = false
                return nil
            }
            return waiters.removeFirst().continuation
        }
        next?.resume(returning: true)
    }
}
