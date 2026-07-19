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

    public func verifyAdministrator(token: String) async throws {
        guard let endpoint, let http else { throw RouterAdministrationError.notAttached }
        guard !token.isEmpty else { throw RouterAdministrationError.invalidAdministratorToken }
        let requestGeneration = generation
        do {
            _ = try await http.get("/api/v1/settings", token: token)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch NetworkError.unauthorized {
            throw RouterAdministrationError.invalidAdministratorToken
        } catch NetworkError.api(403, RouterAPIErrorCode.adminRequired, _) {
            throw RouterAdministrationError.clientTokenRejected
        }
        guard generation == requestGeneration else { throw CancellationError() }
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
        guard let token = try await credentials.readToken(
            for: endpoint, role: .administrator
        ) else { throw RouterAdministrationError.invalidAdministratorToken }
        guard generation == requestGeneration else { throw CancellationError() }
        do {
            let result = try await http.request(method, path, body: body, token: token)
            guard generation == requestGeneration else { throw CancellationError() }
            return result
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch NetworkError.unauthorized {
            throw RouterAdministrationError.invalidAdministratorToken
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
}
