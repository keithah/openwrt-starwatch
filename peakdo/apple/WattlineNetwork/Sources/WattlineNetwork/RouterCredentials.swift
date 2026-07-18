import Foundation
#if canImport(Security)
import Security
#endif

public protocol RouterCredentialBackend: Sendable {
    func read(account: String) async throws -> Data?
    func save(_ data: Data, account: String) async throws
    func delete(account: String) async throws
}

public actor RouterCredentialStore: RouterCredentialProvider,
    CustomStringConvertible, CustomDebugStringConvertible
{
    private let backend: any RouterCredentialBackend

    public init(backend: any RouterCredentialBackend) {
        self.backend = backend
    }

    public nonisolated var description: String { "RouterCredentialStore([REDACTED])" }
    public nonisolated var debugDescription: String { description }

    public func readToken(for endpoint: RouterEndpoint) async throws -> String? {
        do {
            guard let data = try await backend.read(account: account(for: endpoint)),
                  let token = String(data: data, encoding: .utf8),
                  !token.isEmpty
            else { return nil }
            return token
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NetworkError.unauthorized
        }
    }

    public func saveToken(_ token: String, for endpoint: RouterEndpoint) async throws {
        guard !token.isEmpty else { throw NetworkError.unauthorized }
        do {
            try await backend.save(Data(token.utf8), account: account(for: endpoint))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NetworkError.unauthorized
        }
    }

    public func deleteToken(for endpoint: RouterEndpoint) async throws {
        do {
            try await backend.delete(account: account(for: endpoint))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NetworkError.unauthorized
        }
    }

    public func credential(for endpoint: RouterEndpoint) async throws -> RouterCredential {
        guard let token = try await readToken(for: endpoint) else {
            throw NetworkError.unauthorized
        }
        return RouterCredential(token: token)
    }

    private func account(for endpoint: RouterEndpoint) -> String {
        endpoint.peripheralID.uuidString
    }
}

#if canImport(Security)
public final class KeychainRouterCredentialBackend: RouterCredentialBackend, @unchecked Sendable {
    private let service: String

    public init(service: String = "com.keithah.wattline.router-token") {
        self.service = service
    }

    public func read(account: String) async throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
        return result as? Data
    }

    public func save(_ data: Data, account: String) async throws {
        let query = baseQuery(account: account)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainFailure(status: updateStatus)
        }
        var addition = query
        addition[kSecValueData as String] = data
        let addStatus = SecItemAdd(addition as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainFailure(status: addStatus) }
    }

    public func delete(account: String) async throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainFailure(status: status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }
}

private struct KeychainFailure: Error {
    let status: OSStatus
}
#endif
