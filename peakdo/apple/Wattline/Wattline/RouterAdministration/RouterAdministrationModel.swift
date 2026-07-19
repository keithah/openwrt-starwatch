import Foundation
import Observation
import WattlineNetwork

@MainActor
@Observable
final class RouterAdministrationModel {
    enum AdminAccess: Equatable {
        case locked
        case verifying
        case unlocked
    }

    enum HistoryLoadState: Equatable {
        case neverLoaded
        case initialLoading
        case loaded
        case failed
        case refreshing
    }

    private(set) var host: RouterHostMetadata?
    private(set) var access: AdminAccess = .locked
    private(set) var adminError: String?
    private(set) var history: [RouterHistorySample] = []
    private(set) var historyFetchedAt: Date?
    private(set) var historyError: String?
    private(set) var historyLoadState: HistoryLoadState = .neverLoaded
    private(set) var pairingStatus: RouterPairingMode?
    private(set) var pairingQRPNG: Data?
    private(set) var pairingError: String?

    private let connections: RouterConnectionModel
    private let adminClient: RouterAdministrationClient
    private let historyClientFactory: (RouterEndpoint) throws -> RouterHistoryClient
    private let now: () -> Date
    private var sessionGeneration: UInt64 = 0
    private var adminOperationGeneration: UInt64 = 0
    private var historyRequestGeneration: UInt64 = 0
    private var pairingSecretGeneration: UInt64 = 0

    init(
        connections: RouterConnectionModel,
        adminClient: RouterAdministrationClient,
        historyClientFactory: @escaping (RouterEndpoint) throws -> RouterHistoryClient,
        now: @escaping () -> Date = { Date() }
    ) {
        self.connections = connections
        self.adminClient = adminClient
        self.historyClientFactory = historyClientFactory
        self.now = now
    }

    static func production(
        connections: RouterConnectionModel,
        httpFactory: @escaping RouterAdministrationClient.HTTPFactory = {
            try HTTPClient(endpoint: $0)
        }
    ) -> RouterAdministrationModel {
        let credentials = connections.credentialStore
        return RouterAdministrationModel(
            connections: connections,
            adminClient: RouterAdministrationClient(
                credentials: credentials,
                httpFactory: httpFactory
            ),
            historyClientFactory: { endpoint in
                RouterHistoryClient(
                    httpClient: try httpFactory(endpoint),
                    credentials: credentials,
                    endpoint: endpoint
                )
            }
        )
    }

    func begin(host: RouterHostMetadata) async {
        _ = await beginSession(host: host)
    }

    func open(host: RouterHostMetadata) async {
        let generation = await beginSession(host: host)
        guard !Task.isCancelled, sessionGeneration == generation else { return }
        await reloadHistory()
    }

    private func beginSession(host: RouterHostMetadata) async -> UInt64 {
        sessionGeneration &+= 1
        adminOperationGeneration &+= 1
        let session = sessionGeneration
        let adminOperation = adminOperationGeneration
        clearPairingSecrets()
        pairingError = nil
        self.host = host
        access = .locked
        adminError = nil
        history = []
        historyFetchedAt = nil
        historyError = nil
        historyLoadState = .neverLoaded
        do {
            try await adminClient.attach(endpoint: host.endpoint)
        } catch {
            guard sessionGeneration == session,
                  adminOperationGeneration == adminOperation
            else { return session }
            adminError = "Could not prepare a connection to this router."
            return session
        }
        guard sessionGeneration == session,
              adminOperationGeneration == adminOperation
        else { return session }
        access = .verifying
        do {
            try await adminClient.verifyStoredAdministrator()
            guard sessionGeneration == session,
                  adminOperationGeneration == adminOperation
            else { return session }
            access = .unlocked
        } catch {
            guard sessionGeneration == session,
                  adminOperationGeneration == adminOperation
            else { return session }
            access = .locked
        }
        return session
    }

    func end() async {
        sessionGeneration &+= 1
        adminOperationGeneration &+= 1
        host = nil
        access = .locked
        adminError = nil
        history = []
        historyFetchedAt = nil
        historyError = nil
        historyLoadState = .neverLoaded
        clearPairingSecrets()
        pairingError = nil
        await adminClient.detach()
    }

    func reloadHistory() async {
        guard let host else { return }
        let generation = sessionGeneration
        historyRequestGeneration &+= 1
        let requestGeneration = historyRequestGeneration
        historyError = nil
        historyLoadState = historyFetchedAt == nil ? .initialLoading : .refreshing
        do {
            let client = try historyClientFactory(host.endpoint)
            let samples = try await client.fetch()
            guard sessionGeneration == generation,
                  historyRequestGeneration == requestGeneration
            else { return }
            history = samples
            historyFetchedAt = now()
            historyError = nil
            historyLoadState = .loaded
        } catch {
            guard sessionGeneration == generation,
                  historyRequestGeneration == requestGeneration
            else { return }
            historyError = "Could not load router history."
            historyLoadState = .failed
        }
    }

    func unlock(token: String) async {
        guard host != nil, access != .verifying else { return }
        adminOperationGeneration &+= 1
        let session = sessionGeneration
        let adminOperation = adminOperationGeneration
        access = .verifying
        adminError = nil
        do {
            try await adminClient.verifyAdministrator(token: token)
            guard sessionGeneration == session,
                  adminOperationGeneration == adminOperation
            else { return }
            access = .unlocked
        } catch is CancellationError {
            guard sessionGeneration == session,
                  adminOperationGeneration == adminOperation
            else { return }
            access = .locked
            clearPairingSecrets()
        } catch {
            guard sessionGeneration == session,
                  adminOperationGeneration == adminOperation
            else { return }
            access = .locked
            clearPairingSecrets()
            adminError = Self.unlockMessage(for: error)
        }
    }

    func lock() async {
        guard host != nil else { return }
        adminOperationGeneration &+= 1
        access = .locked
        adminError = nil
        clearPairingSecrets()
        try? await adminClient.clearAdministratorCredential()
    }

    func reloadPairingMode() async {
        pairingError = await performPairingAdmin { client in
            try await client.pairingMode()
        } apply: { [weak self] status in
            self?.publishPairingStatus(status)
        }
    }

    func openPairing() async {
        pairingError = await performPairingAdmin { client in
            try await client.openPairingMode()
        } apply: { [weak self] status in
            self?.publishPairingStatus(status)
        }
    }

    func closePairing() async {
        pairingError = await performPairingAdmin { client in
            try await client.closePairingMode()
        } apply: { [weak self] in
            self?.clearPairingSecrets()
        }
    }

    func loadPairingQR() async {
        guard pairingStatus?.open == true else { return }
        pairingError = await performPairingAdmin { client in
            try await client.pairingQRCodePNG()
        } apply: { [weak self] png in
            self?.pairingQRPNG = png
        }
    }

    func clearPairingSecrets() {
        pairingSecretGeneration &+= 1
        pairingStatus = nil
        pairingQRPNG = nil
    }

    func expirePairingSecretsIfNeeded() {
        guard let status = pairingStatus,
              status.open,
              status.expiresAt <= now()
        else { return }
        clearPairingSecrets()
    }

    private func publishPairingStatus(_ status: RouterPairingMode) {
        pairingStatus = status
        if status.open == false {
            pairingQRPNG = nil
        }
    }

    private func performAdmin<Value>(
        _ operation: (RouterAdministrationClient) async throws -> Value,
        apply: (Value) -> Void
    ) async -> String? {
        guard host != nil, access == .unlocked else { return nil }
        let generation = sessionGeneration
        do {
            let value = try await operation(adminClient)
            guard sessionGeneration == generation else { return nil }
            apply(value)
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            guard sessionGeneration == generation else { return nil }
            if handleAdminFailure(error) {
                try? await adminClient.clearAdministratorCredential()
                return nil
            }
            return "The request failed. Try again."
        }
    }

    private func performPairingAdmin<Value>(
        _ operation: (RouterAdministrationClient) async throws -> Value,
        apply: (Value) -> Void
    ) async -> String? {
        let secretGeneration = pairingSecretGeneration
        return await performAdmin(operation) { [weak self] value in
            guard let self,
                  pairingSecretGeneration == secretGeneration
            else { return }
            apply(value)
        }
    }

    private func handleAdminFailure(_ error: Error) -> Bool {
        guard (error as? RouterAdministrationError) == .invalidAdministratorToken else {
            return false
        }
        adminOperationGeneration &+= 1
        access = .locked
        clearPairingSecrets()
        adminError = "The administrator session is no longer valid."
        return true
    }

    private static func unlockMessage(for error: Error) -> String {
        switch error {
        case RouterAdministrationError.invalidAdministratorToken:
            "That administrator token was rejected."
        case RouterAdministrationError.clientTokenRejected:
            "That is a managed client token. Administration needs the bootstrap administrator token."
        default:
            "Could not verify the administrator token. Try again."
        }
    }
}

struct RouterAdministrationPresentation: Equatable {
    enum Section: Equatable {
        case clientEnrollment
    }

    let showsHistory: Bool
    let showsClientSections: Bool
    let showsAdministratorSections: Bool
    let showsUnlockField: Bool
    let visibleSections: [Section]

    init(access: RouterAdministrationModel.AdminAccess) {
        showsHistory = true
        showsClientSections = true
        showsAdministratorSections = access == .unlocked
        showsUnlockField = access != .unlocked
        visibleSections = access == .unlocked ? [.clientEnrollment] : []
    }
}
