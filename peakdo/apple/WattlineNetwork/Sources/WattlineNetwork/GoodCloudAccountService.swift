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
    func logout() async
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

    private static let redactedFailure = "GoodCloud request failed."

    private let auth: GoodCloudAuth?
    private let client: (any GoodCloudAccountClient)?
    private let provisionRemoteAccess: @Sendable (String, Int) async throws -> RemoteAccessSession

    public init(auth: GoodCloudAuth = GoodCloudAuth()) {
        self.auth = auth
        self.client = nil
        self.provisionRemoteAccess = { deviceID, port in
            let client = SignedAPIClient(tokens: PasswordTokenProvider(auth: auth))
            return try await client.remoteAccess(deviceID: deviceID, port: port)
        }
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
    }

    public func validateStoredSession() async -> GoodCloudSessionState {
        state = .loading
        guard await hasStoredToken() else {
            state = .loggedOut
            return state
        }
        return await refreshDevices()
    }

    public func login(email: String, password: String) async -> GoodCloudSessionState {
        state = .loading
        do {
            try await performLogin(email: email, password: password)
            return await refreshDevices()
        } catch {
            return await stateForFailure(error)
        }
    }

    public func refreshDevices() async -> GoodCloudSessionState {
        state = .loading
        do {
            let devices = try await loadDevices()
            state = .authenticated(devices)
            return state
        } catch {
            return await stateForFailure(error)
        }
    }

    public func logout() async {
        if let client {
            await client.logout()
        } else if let auth {
            try? await auth.logOut()
        }
        state = .loggedOut
    }

    public func remoteAccess(deviceID: String, port: Int) async throws -> RemoteAccessSession {
        do {
            return try await provisionRemoteAccess(deviceID, port)
        } catch {
            if case GoodCloudError.api(code: -1010, message: _) = error {
                _ = await stateForFailure(error)
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

    private func stateForFailure(_ error: any Error) async -> GoodCloudSessionState {
        if case GoodCloudError.api(code: -1010, message: _) = error {
            await logout()
            state = .requiresLogin
        } else {
            state = .failed(Self.redactedFailure)
        }
        return state
    }
}
