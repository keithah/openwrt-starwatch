import Foundation
#if canImport(Security)
import Security
#endif

public protocol RouterCredentialBackend: Sendable {
    func read(account: String) async throws -> Data?
    func save(_ data: Data, account: String) async throws
    func delete(account: String) async throws
}

public enum RouterCredentialRole: String, Sendable {
    case client
    case administrator
}

public struct RouterCredentialLease: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    fileprivate let account: String
    fileprivate let version: UInt64

    public var description: String { "RouterCredentialLease(version: \(version))" }
    public var debugDescription: String { description }
}

public actor RouterCredentialStore: RouterCredentialProvider,
    CustomStringConvertible, CustomDebugStringConvertible
{
    private let backend: any RouterCredentialBackend
    private var versions: [String: UInt64] = [:]
    private var accountLocks: [String: RouterCredentialAccountLock] = [:]

    public init(backend: any RouterCredentialBackend) {
        self.backend = backend
    }

    public nonisolated var description: String { "RouterCredentialStore([REDACTED])" }
    public nonisolated var debugDescription: String { description }

    public func readToken(
        for endpoint: RouterEndpoint,
        role: RouterCredentialRole = .client
    ) async throws -> String? {
        let account = account(for: endpoint, role: role)
        let accountLock = accountLock(for: account)
        await accountLock.acquire()
        defer { accountLock.release() }
        do {
            try Task.checkCancellation()
            guard let data = try await backend.read(account: account),
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

    public func saveToken(
        _ token: String,
        for endpoint: RouterEndpoint,
        role: RouterCredentialRole = .client
    ) async throws {
        guard !token.isEmpty else { throw NetworkError.unauthorized }
        let account = account(for: endpoint, role: role)
        let accountLock = accountLock(for: account)
        await accountLock.acquire()
        defer { accountLock.release() }
        do {
            try Task.checkCancellation()
            try await backend.save(Data(token.utf8), account: account)
            advanceVersion(for: account)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NetworkError.unauthorized
        }
    }

    public func deleteToken(
        for endpoint: RouterEndpoint,
        role: RouterCredentialRole = .client
    ) async throws {
        let account = account(for: endpoint, role: role)
        let accountLock = accountLock(for: account)
        await accountLock.acquire()
        defer { accountLock.release() }
        do {
            try Task.checkCancellation()
            try await backend.delete(account: account)
            advanceVersion(for: account)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NetworkError.unauthorized
        }
    }

    public func credentialLease(
        for endpoint: RouterEndpoint,
        role: RouterCredentialRole = .client
    ) async throws -> RouterCredentialLease? {
        let account = account(for: endpoint, role: role)
        let accountLock = accountLock(for: account)
        await accountLock.acquire()
        defer { accountLock.release() }
        do {
            try Task.checkCancellation()
            guard let data = try await backend.read(account: account),
                  let token = String(data: data, encoding: .utf8),
                  !token.isEmpty
            else { return nil }
            return RouterCredentialLease(
                account: account,
                version: versions[account, default: 0]
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NetworkError.unauthorized
        }
    }

    /// Returns whether an opaque credential lease still names the exact
    /// role-scoped account version and that account still contains a usable
    /// credential. Account locking makes concurrent save/delete complete
    /// before the comparison.
    public func isCurrent(
        _ lease: RouterCredentialLease,
        for endpoint: RouterEndpoint,
        role: RouterCredentialRole = .client
    ) async throws -> Bool {
        let account = account(for: endpoint, role: role)
        let accountLock = accountLock(for: account)
        await accountLock.acquire()
        defer { accountLock.release() }
        do {
            try Task.checkCancellation()
            guard lease.account == account,
                  lease.version == versions[account, default: 0],
                  let data = try await backend.read(account: account),
                  let token = String(data: data, encoding: .utf8),
                  !token.isEmpty
            else { return false }
            return true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NetworkError.unauthorized
        }
    }

    @discardableResult
    public func deleteToken(
        for endpoint: RouterEndpoint,
        role: RouterCredentialRole = .client,
        ifCurrent lease: RouterCredentialLease
    ) async throws -> Bool {
        let account = account(for: endpoint, role: role)
        let accountLock = accountLock(for: account)
        await accountLock.acquire()
        defer { accountLock.release() }
        try Task.checkCancellation()
        guard lease.account == account,
              lease.version == versions[account, default: 0]
        else { return false }
        do {
            try await backend.delete(account: account)
            advanceVersion(for: account)
            return true
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

    private func account(for endpoint: RouterEndpoint, role: RouterCredentialRole) -> String {
        let base = endpoint.peripheralID.uuidString
        return role == .client ? base : "\(base).administrator"
    }

    private func advanceVersion(for account: String) {
        versions[account, default: 0] &+= 1
    }

    private func accountLock(for account: String) -> RouterCredentialAccountLock {
        if let lock = accountLocks[account] { return lock }
        let lock = RouterCredentialAccountLock()
        accountLocks[account] = lock
        return lock
    }
}

private final class RouterCredentialAccountLock: @unchecked Sendable {
    private let lock = NSLock()
    private var isAcquired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { continuation in
            let acquiredImmediately = lock.withLock {
                guard isAcquired else {
                    isAcquired = true
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if acquiredImmediately { continuation.resume() }
        }
    }

    func release() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            guard !waiters.isEmpty else {
                isAcquired = false
                return nil
            }
            return waiters.removeFirst()
        }
        next?.resume()
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
