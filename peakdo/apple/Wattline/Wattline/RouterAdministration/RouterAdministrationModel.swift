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

    private(set) var host: RouterHostMetadata?
    private(set) var access: AdminAccess = .locked
    private(set) var adminError: String?
    private(set) var history: [RouterHistorySample] = []
    private(set) var historyFetchedAt: Date?
    private(set) var historyError: String?

    private let connections: RouterConnectionModel
    private let adminClient: RouterAdministrationClient
    private let historyClientFactory: (RouterEndpoint) throws -> RouterHistoryClient
    private let now: () -> Date
    private var sessionGeneration: UInt64 = 0

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

    func begin(host: RouterHostMetadata) async {
        sessionGeneration &+= 1
        let generation = sessionGeneration
        self.host = host
        access = .locked
        adminError = nil
        history = []
        historyFetchedAt = nil
        historyError = nil
        do {
            try await adminClient.attach(endpoint: host.endpoint)
        } catch {
            guard sessionGeneration == generation else { return }
            adminError = "Could not prepare a connection to this router."
            return
        }
        guard sessionGeneration == generation else { return }
        access = .verifying
        do {
            try await adminClient.verifyStoredAdministrator()
            guard sessionGeneration == generation else { return }
            access = .unlocked
        } catch {
            guard sessionGeneration == generation else { return }
            access = .locked
        }
    }

    func end() async {
        sessionGeneration &+= 1
        host = nil
        access = .locked
        adminError = nil
        history = []
        historyFetchedAt = nil
        historyError = nil
        await adminClient.detach()
    }

    func reloadHistory() async {
        guard let host else { return }
        let generation = sessionGeneration
        do {
            let client = try historyClientFactory(host.endpoint)
            let samples = try await client.fetch()
            guard sessionGeneration == generation else { return }
            history = samples
            historyFetchedAt = now()
            historyError = nil
        } catch {
            guard sessionGeneration == generation else { return }
            historyError = "Could not load router history."
        }
    }

    func unlock(token: String) async {
        guard host != nil, access != .verifying else { return }
        let generation = sessionGeneration
        access = .verifying
        adminError = nil
        do {
            try await adminClient.verifyAdministrator(token: token)
            guard sessionGeneration == generation else { return }
            access = .unlocked
        } catch is CancellationError {
            guard sessionGeneration == generation else { return }
            access = .locked
        } catch {
            guard sessionGeneration == generation else { return }
            access = .locked
            adminError = Self.unlockMessage(for: error)
        }
    }

    func lock() async {
        guard host != nil else { return }
        sessionGeneration &+= 1
        access = .locked
        adminError = nil
        try? await adminClient.clearAdministratorCredential()
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
        case connectionAndHistory
        case clientEnrollment
        case apiClients
    }

    let visibleSections: [Section]
    let showsUnlockField: Bool

    init(access: RouterAdministrationModel.AdminAccess) {
        showsUnlockField = access != .unlocked
        visibleSections = access == .unlocked
            ? [.connectionAndHistory, .clientEnrollment, .apiClients]
            : [.connectionAndHistory]
    }
}
