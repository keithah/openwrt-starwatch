import Foundation
import Observation
import WattlineNetwork
import WattlineUI

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
    private(set) var tokens: [RouterTokenMetadata] = []
    private(set) var tokensError: String?
    private(set) var settings: RouterSettings?
    private(set) var settingsError: String?
    private(set) var settingsRestartRequired = false
    private(set) var isSettingsLoading = false
    private(set) var isSettingsSaving = false
    private(set) var validatedReplacement: RouterReplacementCandidate?
    private(set) var replacementValidationError: String?
    private(set) var isReplacementValidationRunning = false
    private(set) var tlsError: String?
    private(set) var tlsRestartRequired = false
    private(set) var isTLSRotationRunning = false
    private(set) var isTLSPromotionRunning = false

    private let connections: RouterConnectionModel
    private let adminClient: RouterAdministrationClient
    private let historyClientFactory: (RouterEndpoint) throws -> RouterHistoryClient
    private let endpointMigrationValidator: RouterEndpointMigrationValidator
    private let now: () -> Date
    private let pairingExpirySleep: PairingExpirySleep
    private var sessionGeneration: UInt64 = 0
    private var adminOperationGeneration: UInt64 = 0
    private var historyRequestGeneration: UInt64 = 0
    private var pairingSecretGeneration: UInt64 = 0
    private var pairingStatusRequestGeneration: UInt64 = 0
    private var pairingQRRequestGeneration: UInt64 = 0
    private var tokenRequestGeneration: UInt64 = 0
    private var settingsRequestGeneration: UInt64 = 0
    private var replacementRequestGeneration: UInt64 = 0
    private var tlsRequestGeneration: UInt64 = 0
    private var pairingExpiryTask: Task<Void, Never>?

    var replacementCandidates: [RouterHostMetadata] {
        var candidates = connections.savedHosts
        for router in connections.discoveredRouters {
            guard !candidates.contains(where: { $0.endpoint == router.endpoint }),
                  let host = Self.hostMetadata(for: router)
            else { continue }
            candidates.append(host)
        }
        return candidates
            .filter { $0.endpoint != host?.endpoint }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    init(
        connections: RouterConnectionModel,
        adminClient: RouterAdministrationClient,
        historyClientFactory: @escaping (RouterEndpoint) throws -> RouterHistoryClient,
        endpointMigrationValidator: RouterEndpointMigrationValidator,
        now: @escaping () -> Date = { Date() },
        pairingExpirySleep: @escaping PairingExpirySleep = { deadline in
            let remaining = max(0, deadline.timeIntervalSinceNow)
            try await Task.sleep(for: .seconds(remaining))
        }
    ) {
        self.connections = connections
        self.adminClient = adminClient
        self.historyClientFactory = historyClientFactory
        self.endpointMigrationValidator = endpointMigrationValidator
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
            },
            endpointMigrationValidator: .production(credentials: credentials)
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
        tokenRequestGeneration &+= 1
        tokens = []
        tokensError = nil
        clearSettingsState()
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
        tokenRequestGeneration &+= 1
        tokens = []
        tokensError = nil
        clearSettingsState()
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
            clearSettingsState()
        } catch {
            guard sessionGeneration == session,
                  adminOperationGeneration == adminOperation
            else { return }
            access = .locked
            clearPairingSecrets()
            clearSettingsState()
            adminError = Self.unlockMessage(for: error)
        }
    }

    func lock() async {
        guard host != nil else { return }
        adminOperationGeneration &+= 1
        access = .locked
        adminError = nil
        clearPairingSecrets()
        clearSettingsState()
        try? await adminClient.clearAdministratorCredential()
    }

    func reloadSettings() async {
        settingsRequestGeneration &+= 1
        let request = settingsRequestGeneration
        isSettingsLoading = true
        settingsError = nil
        let result = await performAdmin({ client in
            try await client.settings()
        }, isCurrent: { [weak self] in
            self?.settingsRequestGeneration == request
        })
        guard settingsRequestGeneration == request else { return }
        isSettingsLoading = false
        switch result {
        case let .success(value):
            settings = value
            settingsError = nil
        case let .failure(message):
            settingsError = message
        case .stale:
            break
        }
    }

    func saveSettings(_ patch: RouterSettingsPatch) async {
        settingsRequestGeneration &+= 1
        let request = settingsRequestGeneration
        isSettingsSaving = true
        settingsError = nil
        let result = await performAdmin({ client in
            try await client.updateSettings(patch)
        }, isCurrent: { [weak self] in
            self?.settingsRequestGeneration == request
        })
        guard settingsRequestGeneration == request else { return }
        isSettingsSaving = false
        switch result {
        case let .success(value):
            settings = value.settings
            settingsRestartRequired = value.restartRequired
        case let .failure(message):
            settingsError = message
        case .stale:
            break
        }
    }

    func rotateTLS() async {
        guard let source = host,
              source.scheme == "https",
              source.certificateFingerprint != nil,
              access == .unlocked
        else { return }
        tlsRequestGeneration &+= 1
        let request = tlsRequestGeneration
        let session = sessionGeneration
        let adminOperation = adminOperationGeneration
        isTLSRotationRunning = true
        tlsError = nil
        do {
            let response = try await adminClient.rotateTLS()
            guard isCurrentTLSOperation(
                source: source,
                session: session,
                adminOperation: adminOperation,
                request: request
            ) else { return }
            let staged = try await connections.stageTLSCertificateFingerprint(
                response.sha256,
                for: source
            )
            guard isCurrentTLSOperation(
                source: source,
                session: session,
                adminOperation: adminOperation,
                request: request
            ) else { return }
            host = staged
            tlsRestartRequired = response.restartRequired
            isTLSRotationRunning = false
        } catch is CancellationError {
            guard isCurrentTLSOperation(
                source: source,
                session: session,
                adminOperation: adminOperation,
                request: request
            ) else { return }
            isTLSRotationRunning = false
        } catch {
            guard isCurrentTLSOperation(
                source: source,
                session: session,
                adminOperation: adminOperation,
                request: request
            ) else { return }
            isTLSRotationRunning = false
            if handleAdminFailure(error) {
                try? await adminClient.clearAdministratorCredential()
            } else {
                tlsError = "The certificate rotation failed. Try again."
            }
        }
    }

    func promoteStagedTLSPin() async {
        guard let source = host,
              source.scheme == "https",
              source.stagedCertificateFingerprint != nil,
              access != .verifying
        else { return }
        let operationAccess = access
        tlsRequestGeneration &+= 1
        let request = tlsRequestGeneration
        let session = sessionGeneration
        let adminOperation = adminOperationGeneration
        isTLSPromotionRunning = true
        tlsError = nil
        do {
            let promoted = try await connections.promoteStagedTLSPin(for: source.id)
            guard isCurrentTLSOperation(
                source: source,
                session: session,
                adminOperation: adminOperation,
                request: request,
                expectedAccess: operationAccess
            ) else { return }
            do {
                try await adminClient.attach(endpoint: promoted.endpoint)
            } catch {
                guard isCurrentTLSOperation(
                    source: source,
                    session: session,
                    adminOperation: adminOperation,
                    request: request,
                    expectedAccess: operationAccess
                ) else { return }
                host = promoted
                access = .locked
                tlsRestartRequired = false
                isTLSPromotionRunning = false
                tlsError = "The pin was promoted, but administration must be reopened."
                return
            }
            guard isCurrentTLSOperation(
                source: source,
                session: session,
                adminOperation: adminOperation,
                request: request,
                expectedAccess: operationAccess
            ) else { return }
            host = promoted
            tlsRestartRequired = false
            isTLSPromotionRunning = false
        } catch {
            guard isCurrentTLSOperation(
                source: source,
                session: session,
                adminOperation: adminOperation,
                request: request,
                expectedAccess: operationAccess
            ) else { return }
            isTLSPromotionRunning = false
            tlsError = "The new certificate could not be verified."
        }
    }

    func validateReplacement(_ candidate: RouterHostMetadata) async {
        guard let source = host,
              access == .unlocked,
              let expectedDeviceID = source.deviceID,
              replacementCandidates.contains(where: { $0.endpoint == candidate.endpoint })
        else {
            validatedReplacement = nil
            replacementValidationError = "Select a known router endpoint."
            return
        }
        replacementRequestGeneration &+= 1
        let request = replacementRequestGeneration
        let session = sessionGeneration
        validatedReplacement = nil
        replacementValidationError = nil
        isReplacementValidationRunning = true
        do {
            let validated = try await endpointMigrationValidator.validate(
                sourceEndpoint: source.endpoint,
                candidate: candidate.endpoint,
                expectedDeviceID: expectedDeviceID
            )
            guard sessionGeneration == session,
                  replacementRequestGeneration == request,
                  host?.endpoint == source.endpoint,
                  access == .unlocked
            else { return }
            validatedReplacement = RouterReplacementCandidate(
                scheme: validated.endpoint.scheme,
                host: validated.endpoint.host,
                port: validated.endpoint.port,
                validation: .verified(deviceID: validated.deviceID)
            )
            replacementValidationError = nil
            isReplacementValidationRunning = false
        } catch {
            guard sessionGeneration == session,
                  replacementRequestGeneration == request,
                  host?.endpoint == source.endpoint,
                  access == .unlocked
            else { return }
            validatedReplacement = nil
            replacementValidationError = "Could not verify this replacement endpoint."
            isReplacementValidationRunning = false
        }
    }

    func reloadTokens() async {
        guard host != nil, access == .unlocked else { return }
        tokenRequestGeneration &+= 1
        let requestGeneration = tokenRequestGeneration
        tokensError = nil
        let result = await performAdmin({ client in
            try await client.tokens()
        }, isCurrent: { [weak self] in
            self?.tokenRequestGeneration == requestGeneration
        })
        guard tokenRequestGeneration == requestGeneration else { return }
        publishTokenResult(result)
    }

    func isCurrentClient(_ token: RouterTokenMetadata) -> Bool {
        guard let currentID = host?.tokenID else { return false }
        return currentID == token.id
    }

    func revoke(_ token: RouterTokenMetadata) async {
        guard !token.bootstrap, host != nil, access == .unlocked else { return }
        let wasCurrentClient = isCurrentClient(token)
        let revokedHost = host
        let session = sessionGeneration
        let adminOperation = adminOperationGeneration
        tokenRequestGeneration &+= 1
        let requestGeneration = tokenRequestGeneration
        tokensError = nil
        let adminAttachment: RouterAdministrationAttachmentLease
        do {
            adminAttachment = try await adminClient.attachmentLease()
        } catch {
            guard isCurrentTokenOperation(
                session: session,
                adminOperation: adminOperation,
                request: requestGeneration
            ) else { return }
            tokensError = "The request failed. Try again."
            return
        }
        let revokedClientLease: RouterCredentialLease?
        if wasCurrentClient, let revokedHost {
            do {
                revokedClientLease = try await connections.clientCredentialLease(
                    for: revokedHost
                )
            } catch {
                guard isCurrentTokenOperation(
                    session: session,
                    adminOperation: adminOperation,
                    request: requestGeneration
                ) else { return }
                tokensError = "The request failed. Try again."
                return
            }
        } else {
            revokedClientLease = nil
        }
        guard isCurrentAdminEndpoint(
            session: session,
            adminOperation: adminOperation,
            endpoint: revokedHost?.endpoint
        ) else { return }
        let authoritativeList: [RouterTokenMetadata]?
        let readbackFailure: RouterTokenRevocationReadbackError.Cause?
        do {
            authoritativeList = try await adminClient.revokeTokenAndReload(
                id: token.id,
                attachment: adminAttachment
            )
            readbackFailure = nil
        } catch let error as RouterTokenRevocationReadbackError {
            // The actor validated the DELETE before attempting the failed
            // authoritative readback, so conditional local cleanup must still
            // run even when this presentation operation is now stale.
            authoritativeList = nil
            readbackFailure = error.cause
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentTokenOperation(
                session: session,
                adminOperation: adminOperation,
                request: requestGeneration
            ) else { return }
            if handleAdminFailure(error) {
                try? await adminClient.clearAdministratorCredential()
            } else {
                tokensError = "The request failed. Try again."
            }
            return
        }

        var clientCleanupFailed = false
        if let revokedHost, let revokedClientLease {
            do {
                try await connections.returnToEnrollment(
                    revokedHost,
                    ifCurrent: revokedClientLease
                )
            } catch {
                clientCleanupFailed = true
            }
        }

        guard isCurrentAdminEndpoint(
            session: session,
            adminOperation: adminOperation,
            endpoint: revokedHost?.endpoint
        ) else { return }

        guard isCurrentTokenOperation(
            session: session,
            adminOperation: adminOperation,
            request: requestGeneration
        ) else { return }
        if let authoritativeList {
            tokens = authoritativeList
            tokensError = clientCleanupFailed ? Self.clientCleanupFailureMessage : nil
        } else if readbackFailure == .invalidAdministratorToken {
            if handleAdminFailure(RouterAdministrationError.invalidAdministratorToken) {
                try? await adminClient.clearAdministratorCredential()
            }
        } else if readbackFailure == .cancelled {
            if clientCleanupFailed {
                tokensError = Self.clientCleanupFailureMessage
            }
        } else if clientCleanupFailed {
            tokensError = Self.clientCleanupFailureMessage
        } else {
            tokensError = "The token was revoked, but the updated client list could not be loaded."
        }
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

    private func publishTokenResult(_ result: AdminResult<[RouterTokenMetadata]>) {
        switch result {
        case let .success(list):
            tokens = list
            tokensError = nil
        case let .failure(message):
            tokensError = message
        case .stale:
            break
        }
    }

    private func isCurrentTokenOperation(
        session: UInt64,
        adminOperation: UInt64,
        request: UInt64
    ) -> Bool {
        sessionGeneration == session
            && adminOperationGeneration == adminOperation
            && tokenRequestGeneration == request
            && access == .unlocked
    }

    private func isCurrentAdminEndpoint(
        session: UInt64,
        adminOperation: UInt64,
        endpoint: RouterEndpoint?
    ) -> Bool {
        sessionGeneration == session
            && adminOperationGeneration == adminOperation
            && host?.endpoint == endpoint
            && access == .unlocked
    }

    private func isCurrentTLSOperation(
        source: RouterHostMetadata,
        session: UInt64,
        adminOperation: UInt64,
        request: UInt64,
        expectedAccess: AdminAccess = .unlocked
    ) -> Bool {
        sessionGeneration == session
            && adminOperationGeneration == adminOperation
            && tlsRequestGeneration == request
            && host == source
            && access == expectedAccess
    }

    private static let clientCleanupFailureMessage =
        "Token was revoked, but this device's local client credential could not be removed."

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
        clearSettingsState()
        adminError = "The administrator session is no longer valid."
        return true
    }

    private func clearSettingsState() {
        settingsRequestGeneration &+= 1
        replacementRequestGeneration &+= 1
        settings = nil
        settingsError = nil
        settingsRestartRequired = false
        isSettingsLoading = false
        isSettingsSaving = false
        validatedReplacement = nil
        replacementValidationError = nil
        isReplacementValidationRunning = false
        tlsRequestGeneration &+= 1
        tlsError = nil
        tlsRestartRequired = false
        isTLSRotationRunning = false
        isTLSPromotionRunning = false
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

    private static func hostMetadata(for router: DiscoveredRouter) -> RouterHostMetadata? {
        var components = URLComponents()
        components.scheme = router.endpoint.scheme
        components.host = router.endpoint.host
        components.port = router.endpoint.port
        guard let address = components.string else { return nil }
        return try? RouterHostValidator.validate(
            address,
            displayName: router.serviceName,
            reachability: .lan,
            allowsInsecureWAN: false,
            deviceID: router.deviceID,
            certificateFingerprint: router.endpoint.certificateFingerprint
        )
    }
}

struct RouterAdministrationPresentation: Equatable {
    enum Section: Equatable {
        case clientEnrollment
        case apiClients
        case routerConfiguration
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
        visibleSections = access == .unlocked
            ? [.clientEnrollment, .apiClients, .routerConfiguration]
            : []
    }
}
