import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum RouterAdministrationError: Error, Equatable, Sendable {
    case notAttached
    case invalidAdministratorToken
    case clientTokenRejected
    case protectedToken
    case invalidResponse
}

/// The DELETE was accepted and validated, but its required authoritative token
/// readback did not complete. Callers can still perform local cleanup that is
/// conditional on durable revocation without publishing a guessed token list.
public struct RouterTokenRevocationReadbackError: Error, Equatable, Sendable {
    public enum Cause: Equatable, Sendable {
        case cancelled
        case invalidAdministratorToken
        case clientTokenRejected
        case invalidResponse
        case other
    }

    public let cause: Cause

    init(_ error: any Error) {
        cause = switch error {
        case is CancellationError:
            .cancelled
        case RouterAdministrationError.invalidAdministratorToken:
            .invalidAdministratorToken
        case RouterAdministrationError.clientTokenRejected:
            .clientTokenRejected
        case RouterAdministrationError.invalidResponse:
            .invalidResponse
        default:
            .other
        }
    }
}

public struct RouterAdministrationAttachmentLease: Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    fileprivate let generation: UInt64
    let endpoint: RouterEndpoint

    public var description: String { "RouterAdministrationAttachmentLease([REDACTED])" }
    public var debugDescription: String { description }
}

/// Serializes privileged router requests for one endpoint at a time.
/// Attaching a different endpoint increments a generation; completions from a
/// previous generation are discarded as CancellationError and can never save
/// credentials or publish results into the replacement session.
public actor RouterAdministrationClient {
    public typealias HTTPFactory = @Sendable (RouterEndpoint) throws -> any RouterHTTPClient

    private let credentials: RouterCredentialStore
    private let httpFactory: HTTPFactory
    private var generation: UInt64 = 0
    private var endpoint: RouterEndpoint?
    private var http: (any RouterHTTPClient)?
    // Saving and stale rollback form one critical section. A successor using the
    // same credential account waits until rollback finishes, then revalidates
    // its generation and persists last.
    private var credentialPersistenceActive = false
    private var credentialPersistenceWaiters: [CheckedContinuation<Void, Never>] = []
    private var privilegedMutationActive = false
    private var privilegedMutationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(credentials: RouterCredentialStore, httpFactory: @escaping HTTPFactory) {
        self.credentials = credentials
        self.httpFactory = httpFactory
    }

    public func attach(endpoint: RouterEndpoint) throws {
        generation &+= 1
        self.endpoint = nil
        http = nil
        let replacementHTTP = try httpFactory(endpoint)
        self.endpoint = endpoint
        http = replacementHTTP
    }

    public func detach() {
        generation &+= 1
        endpoint = nil
        http = nil
    }

    public func attachmentLease() throws -> RouterAdministrationAttachmentLease {
        guard let endpoint, http != nil else {
            throw RouterAdministrationError.notAttached
        }
        return RouterAdministrationAttachmentLease(
            generation: generation,
            endpoint: endpoint
        )
    }

    func validate(attachment: RouterAdministrationAttachmentLease) throws {
        guard generation == attachment.generation,
              endpoint == attachment.endpoint,
              http != nil
        else { throw CancellationError() }
    }

    public func verifyAdministrator(token: String) async throws {
        guard let endpoint, let http else { throw RouterAdministrationError.notAttached }
        guard !token.isEmpty else { throw RouterAdministrationError.invalidAdministratorToken }
        let requestGeneration = generation
        let response: HTTPURLResponse
        do {
            (_, response) = try await http.get("/api/v1/settings", token: token)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch NetworkError.unauthorized {
            throw RouterAdministrationError.invalidAdministratorToken
        } catch NetworkError.api(403, RouterAPIErrorCode.adminRequired, _) {
            throw RouterAdministrationError.clientTokenRejected
        }
        guard generation == requestGeneration else { throw CancellationError() }
        guard response.statusCode == 200 else {
            throw RouterAdministrationError.invalidResponse
        }
        await acquireCredentialPersistence()
        defer { releaseCredentialPersistence() }
        guard generation == requestGeneration else { throw CancellationError() }
        try Task.checkCancellation()
        try await credentials.saveToken(token, for: endpoint, role: .administrator)
        guard generation == requestGeneration else {
            try? await credentials.deleteToken(for: endpoint, role: .administrator)
            throw CancellationError()
        }
    }

    public func verifyStoredAdministrator() async throws {
        guard let endpoint, let http else { throw RouterAdministrationError.notAttached }
        let requestGeneration = generation
        await acquireCredentialPersistence()
        defer { releaseCredentialPersistence() }
        guard generation == requestGeneration else { throw CancellationError() }
        try Task.checkCancellation()
        guard let token = try await credentials.readToken(
            for: endpoint,
            role: .administrator
        ) else { throw RouterAdministrationError.invalidAdministratorToken }
        guard generation == requestGeneration else { throw CancellationError() }
        let response: HTTPURLResponse
        do {
            (_, response) = try await http.get("/api/v1/settings", token: token)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch NetworkError.unauthorized {
            guard generation == requestGeneration else { throw CancellationError() }
            try Task.checkCancellation()
            try? await credentials.deleteToken(for: endpoint, role: .administrator)
            guard generation == requestGeneration else { throw CancellationError() }
            throw RouterAdministrationError.invalidAdministratorToken
        } catch NetworkError.api(403, RouterAPIErrorCode.adminRequired, _) {
            guard generation == requestGeneration else { throw CancellationError() }
            throw RouterAdministrationError.clientTokenRejected
        }
        guard generation == requestGeneration else { throw CancellationError() }
        guard response.statusCode == 200 else {
            throw RouterAdministrationError.invalidResponse
        }
    }

    public func clearAdministratorCredential() async throws {
        guard let endpoint else { throw RouterAdministrationError.notAttached }
        generation &+= 1
        let clearGeneration = generation
        await acquireCredentialPersistence()
        defer { releaseCredentialPersistence() }
        guard generation == clearGeneration else { throw CancellationError() }
        try Task.checkCancellation()
        try await credentials.deleteToken(for: endpoint, role: .administrator)
        guard generation == clearGeneration else { throw CancellationError() }
    }

    /// Shared admin-authenticated request path for pairing-mode and token routes.
    /// A missing stored administrator credential surfaces as
    /// invalidAdministratorToken so the model re-locks instead of retrying.
    func send(
        _ method: String,
        _ path: String,
        body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        guard let endpoint, let http else { throw RouterAdministrationError.notAttached }
        let requestGeneration = generation
        let storedToken: String?
        do {
            storedToken = try await credentials.readToken(
                for: endpoint, role: .administrator
            )
        } catch {
            guard generation == requestGeneration else { throw CancellationError() }
            if error is CancellationError { throw CancellationError() }
            if case NetworkError.unauthorized = error {
                throw RouterAdministrationError.invalidAdministratorToken
            }
            throw error
        }
        guard generation == requestGeneration else { throw CancellationError() }
        guard let token = storedToken else {
            throw RouterAdministrationError.invalidAdministratorToken
        }
        do {
            let result = try await http.request(method, path, body: body, token: token)
            guard generation == requestGeneration else { throw CancellationError() }
            guard result.1.statusCode == 200 else {
                throw RouterAdministrationError.invalidResponse
            }
            return result
        } catch {
            guard generation == requestGeneration else { throw CancellationError() }
            if let urlError = error as? URLError, urlError.code == .cancelled {
                throw CancellationError()
            }
            if case NetworkError.unauthorized = error {
                throw RouterAdministrationError.invalidAdministratorToken
            }
            throw error
        }
    }

    /// Client-authenticated request path for administration surfaces whose
    /// canonical API role is the unchanged managed-client account.
    func sendClient(
        _ method: String,
        _ path: String,
        body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        guard let endpoint, let http else { throw RouterAdministrationError.notAttached }
        let requestGeneration = generation
        let storedToken: String?
        do {
            storedToken = try await credentials.readToken(for: endpoint, role: .client)
        } catch {
            guard generation == requestGeneration else { throw CancellationError() }
            if error is CancellationError { throw CancellationError() }
            throw error
        }
        guard generation == requestGeneration else { throw CancellationError() }
        guard let token = storedToken else { throw NetworkError.unauthorized }
        do {
            let result = try await http.request(method, path, body: body, token: token)
            guard generation == requestGeneration else { throw CancellationError() }
            guard result.1.statusCode == 200 else {
                throw RouterAdministrationError.invalidResponse
            }
            return result
        } catch {
            guard generation == requestGeneration else { throw CancellationError() }
            if let urlError = error as? URLError, urlError.code == .cancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    /// Request path for mutations whose 2xx response is durable on the router.
    /// Stale work is quarantined before sending and before translating failures,
    /// but a successful response remains observable after a generation change so
    /// callers can complete required local cleanup.
    func sendDurableMutation(
        _ method: String,
        _ path: String,
        body: Data? = nil,
        attachment: RouterAdministrationAttachmentLease
    ) async throws -> (Data, HTTPURLResponse) {
        guard generation == attachment.generation,
              endpoint == attachment.endpoint,
              let endpoint,
              let http
        else { throw CancellationError() }
        let requestGeneration = attachment.generation
        let storedToken: String?
        do {
            storedToken = try await credentials.readToken(
                for: endpoint, role: .administrator
            )
        } catch {
            guard generation == requestGeneration else { throw CancellationError() }
            if error is CancellationError { throw CancellationError() }
            if case NetworkError.unauthorized = error {
                throw RouterAdministrationError.invalidAdministratorToken
            }
            throw error
        }
        guard generation == requestGeneration else { throw CancellationError() }
        guard let token = storedToken else {
            throw RouterAdministrationError.invalidAdministratorToken
        }
        do {
            let result = try await http.request(method, path, body: body, token: token)
            guard result.1.statusCode == 200 else {
                throw RouterAdministrationError.invalidResponse
            }
            return result
        } catch {
            guard generation == requestGeneration else { throw CancellationError() }
            if let urlError = error as? URLError, urlError.code == .cancelled {
                throw CancellationError()
            }
            if case NetworkError.unauthorized = error {
                throw RouterAdministrationError.invalidAdministratorToken
            }
            throw error
        }
    }

    private func acquireCredentialPersistence() async {
        guard credentialPersistenceActive else {
            credentialPersistenceActive = true
            return
        }
        await withCheckedContinuation { credentialPersistenceWaiters.append($0) }
    }

    private func releaseCredentialPersistence() {
        guard !credentialPersistenceWaiters.isEmpty else {
            credentialPersistenceActive = false
            return
        }
        credentialPersistenceWaiters.removeFirst().resume()
    }

    func acquirePrivilegedMutation() async {
        guard privilegedMutationActive else {
            privilegedMutationActive = true
            return
        }
        await withCheckedContinuation { privilegedMutationWaiters.append($0) }
    }

    func releasePrivilegedMutation() {
        guard !privilegedMutationWaiters.isEmpty else {
            privilegedMutationActive = false
            return
        }
        privilegedMutationWaiters.removeFirst().resume()
    }
}
