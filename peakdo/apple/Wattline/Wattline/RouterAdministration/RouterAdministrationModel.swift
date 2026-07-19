import Foundation
import Observation
import WattlineNetwork

@MainActor
@Observable
final class RouterAdministrationModel {
    typealias PairingExpirySleep = @MainActor @Sendable (Date) async throws -> Void

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

    enum PairingDisplayState: Equatable {
        case unknown
        case loading
        case open
        case closed
        case expired
        case failed

        var canOpenPairing: Bool { self == .closed || self == .expired }
        var canRefresh: Bool { self == .unknown || self == .expired || self == .failed }
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
    private(set) var pairingDisplayState: PairingDisplayState = .unknown
    private(set) var isPairingQRLoading = false

    private let connections: RouterConnectionModel
    private let adminClient: RouterAdministrationClient
    private let historyClientFactory: (RouterEndpoint) throws -> RouterHistoryClient
    private let now: () -> Date
    private let pairingExpirySleep: PairingExpirySleep
    private var sessionGeneration: UInt64 = 0
    private var adminOperationGeneration: UInt64 = 0
    private var historyRequestGeneration: UInt64 = 0
    private var pairingSecretGeneration: UInt64 = 0
    private var pairingStatusRequestGeneration: UInt64 = 0
    private var pairingQRRequestGeneration: UInt64 = 0
    private var pairingExpiryTask: Task<Void, Never>?

    init(
        connections: RouterConnectionModel,
        adminClient: RouterAdministrationClient,
        historyClientFactory: @escaping (RouterEndpoint) throws -> RouterHistoryClient,
        now: @escaping () -> Date = { Date() },
        pairingExpirySleep: @escaping PairingExpirySleep = { deadline in
            let remaining = max(0, deadline.timeIntervalSinceNow)
            try await Task.sleep(for: .seconds(remaining))
        }
    ) {
        self.connections = connections
        self.adminClient = adminClient
        self.historyClientFactory = historyClientFactory
        self.now = now
        self.pairingExpirySleep = pairingExpirySleep
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
        clearPairingSecrets()
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
        await performPairingStatusAdmin { client in
            try await client.pairingMode()
        } apply: { [weak self] status in
            self?.publishPairingStatus(status)
        }
    }

    func openPairing() async {
        await performPairingStatusAdmin { client in
            try await client.openPairingMode()
        } apply: { [weak self] status in
            self?.publishPairingStatus(status)
        }
    }

    func closePairing() async {
        await performPairingStatusAdmin { client in
            try await client.closePairingMode()
        } apply: { [weak self] in
            self?.publishPairingStatus(RouterPairingMode(
                open: false,
                expiresAt: .distantPast,
                pin: nil
            ))
        }
    }

    func loadPairingQR() async {
        guard pairingStatus?.open == true else { return }
        pairingQRRequestGeneration &+= 1
        let requestGeneration = pairingQRRequestGeneration
        isPairingQRLoading = true
        pairingError = nil
        let result = await performPairingAdmin({ client in
            try await client.pairingQRCodePNG()
        }, isCurrent: { [weak self] in
            self?.pairingQRRequestGeneration == requestGeneration
        })
        guard pairingQRRequestGeneration == requestGeneration else { return }
        isPairingQRLoading = false
        switch result {
        case let .success(png):
            guard pairingStatus?.open == true else { return }
            pairingQRPNG = png
            pairingError = nil
        case let .failure(message):
            pairingError = message
        case .stale:
            break
        }
    }

    func clearPairingSecrets() {
        invalidatePairingSecrets(displayState: .unknown)
    }

    func expirePairingSecretsIfNeeded() {
        guard let status = pairingStatus,
              status.open,
              status.expiresAt <= now()
        else { return }
        expirePairingSecrets()
    }

    func pairingDidEnterBackground() {
        clearPairingSecrets()
        pairingError = nil
    }

    func pairingDidBecomeActive() async {
        await reloadPairingMode()
    }

    private func publishPairingStatus(_ status: RouterPairingMode) {
        pairingExpiryTask?.cancel()
        pairingExpiryTask = nil
        pairingSecretGeneration &+= 1
        pairingQRRequestGeneration &+= 1
        isPairingQRLoading = false
        pairingQRPNG = nil
        guard status.open else {
            pairingStatus = status
            pairingDisplayState = .closed
            return
        }
        guard status.expiresAt > now() else {
            pairingStatus = nil
            pairingDisplayState = .expired
            return
        }
        pairingStatus = status
        pairingDisplayState = .open
        schedulePairingExpiry(at: status.expiresAt)
    }

    private func schedulePairingExpiry(at deadline: Date) {
        let secretGeneration = pairingSecretGeneration
        let sleep = pairingExpirySleep
        pairingExpiryTask = Task { [weak self] in
            do {
                try await sleep(deadline)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  pairingSecretGeneration == secretGeneration,
                  pairingStatus?.open == true,
                  pairingStatus?.expiresAt == deadline,
                  deadline <= now()
            else { return }
            expirePairingSecrets()
        }
    }

    private func expirePairingSecrets() {
        invalidatePairingSecrets(displayState: .expired)
        pairingError = nil
    }

    private func invalidatePairingSecrets(displayState: PairingDisplayState) {
        pairingExpiryTask?.cancel()
        pairingExpiryTask = nil
        pairingSecretGeneration &+= 1
        pairingQRRequestGeneration &+= 1
        pairingStatus = nil
        pairingQRPNG = nil
        isPairingQRLoading = false
        pairingDisplayState = displayState
    }

    private enum AdminResult<Value> {
        case success(Value)
        case failure(String)
        case stale
    }

    private func performAdmin<Value>(
        _ operation: (RouterAdministrationClient) async throws -> Value,
        isCurrent: () -> Bool = { true }
    ) async -> AdminResult<Value> {
        guard host != nil, access == .unlocked else { return .stale }
        let session = sessionGeneration
        let adminOperation = adminOperationGeneration
        do {
            let value = try await operation(adminClient)
            guard sessionGeneration == session,
                  adminOperationGeneration == adminOperation,
                  access == .unlocked,
                  isCurrent()
            else { return .stale }
            return .success(value)
        } catch is CancellationError {
            return .stale
        } catch {
            guard sessionGeneration == session,
                  adminOperationGeneration == adminOperation,
                  access == .unlocked,
                  isCurrent()
            else { return .stale }
            if handleAdminFailure(error) {
                try? await adminClient.clearAdministratorCredential()
                return .stale
            }
            return .failure("The request failed. Try again.")
        }
    }

    private func performPairingAdmin<Value>(
        _ operation: (RouterAdministrationClient) async throws -> Value,
        isCurrent: () -> Bool = { true }
    ) async -> AdminResult<Value> {
        let secretGeneration = pairingSecretGeneration
        let result = await performAdmin(operation) {
            pairingSecretGeneration == secretGeneration && isCurrent()
        }
        guard pairingSecretGeneration == secretGeneration else {
            return .stale
        }
        return result
    }

    private func performPairingStatusAdmin<Value>(
        _ operation: (RouterAdministrationClient) async throws -> Value,
        apply: (Value) -> Void
    ) async {
        guard host != nil, access == .unlocked else { return }
        pairingStatusRequestGeneration &+= 1
        let requestGeneration = pairingStatusRequestGeneration
        invalidatePairingSecrets(displayState: .loading)
        pairingError = nil
        let result = await performPairingAdmin(operation) {
            pairingStatusRequestGeneration == requestGeneration
        }
        guard pairingStatusRequestGeneration == requestGeneration else { return }
        switch result {
        case let .success(value):
            apply(value)
            pairingError = nil
        case let .failure(message):
            invalidatePairingSecrets(displayState: .failed)
            pairingError = message
        case .stale:
            break
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
