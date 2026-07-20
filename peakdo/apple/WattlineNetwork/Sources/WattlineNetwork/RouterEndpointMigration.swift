import Foundation

/// Opaque proof that an exact, already-saved endpoint was authenticated with
/// its own retained client credential and reported the expected device ID.
/// The token and credential lease are intentionally not exposed.
public struct ValidatedRouterReplacement: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public let endpoint: RouterEndpoint
    public let deviceID: String
    fileprivate let candidate: RouterHostMetadata
    fileprivate let credentialLease: RouterCredentialLease

    public var description: String { "ValidatedRouterReplacement([REDACTED])" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["validation": "[REDACTED]"], displayStyle: .struct)
    }
}

public enum RouterEndpointMigrationError: Error, Equatable, Sendable {
    case invalidExpectedDeviceID
    case candidateNotSaved
    case untrustedCandidate
    case candidateChanged
    case invalidResponse
    case deviceIDMismatch
}

public struct RouterEndpointMigrationValidator: Sendable {
    public typealias HTTPFactory = @Sendable (RouterEndpoint) throws -> any RouterHTTPClient

    private let hostStore: RouterHostStore
    private let credentials: RouterCredentialStore
    private let httpFactory: HTTPFactory

    public init(
        hostStore: RouterHostStore,
        credentials: RouterCredentialStore,
        httpFactory: @escaping HTTPFactory
    ) {
        self.hostStore = hostStore
        self.credentials = credentials
        self.httpFactory = httpFactory
    }

    public static func production(
        hostStore: RouterHostStore,
        credentials: RouterCredentialStore,
        configuration: URLSessionConfiguration = .ephemeral
    ) -> RouterEndpointMigrationValidator {
        RouterEndpointMigrationValidator(
            hostStore: hostStore,
            credentials: credentials
        ) { endpoint in
            HTTPClient(
                baseURL: try RouterURLSessionFactory.baseURL(for: endpoint),
                session: try RouterURLSessionFactory.makeMigration(
                    endpoint: endpoint,
                    configuration: configuration
                )
            )
        }
    }

    public func validate(
        candidate: RouterHostMetadata,
        expectedDeviceID: String
    ) async throws -> ValidatedRouterReplacement {
        guard let expected = DeviceIdentityDeduplicator.normalizedMAC(expectedDeviceID) else {
            throw RouterEndpointMigrationError.invalidExpectedDeviceID
        }
        guard let savedDeviceID = DeviceIdentityDeduplicator.normalizedMAC(candidate.deviceID),
              savedDeviceID == expected,
              await hostStore.hosts().contains(candidate)
        else { throw RouterEndpointMigrationError.candidateNotSaved }
        guard Self.hasIndependentTrust(candidate) else {
            throw RouterEndpointMigrationError.untrustedCandidate
        }
        guard let credentialLease = try await credentials.credentialLease(
            for: candidate.endpoint,
            role: .client
        ) else {
            throw RouterAdministrationError.invalidAdministratorToken
        }
        guard try await credentials.isCurrent(
            credentialLease,
            for: candidate.endpoint,
            role: .client
        ), let token = try await credentials.readToken(
            for: candidate.endpoint,
            role: .client
        ), try await credentials.isCurrent(
            credentialLease,
            for: candidate.endpoint,
            role: .client
        ) else {
            throw RouterEndpointMigrationError.candidateChanged
        }

        let (data, response) = try await httpFactory(candidate.endpoint).get(
            "/api/v1/device",
            token: token
        )
        guard response.statusCode == 200,
              let device = try? JSONDecoder().decode(RouterDeviceDTO.self, from: data),
              let observed = DeviceIdentityDeduplicator.normalizedMAC(device.id)
        else {
            throw RouterEndpointMigrationError.invalidResponse
        }
        guard observed == expected else {
            throw RouterEndpointMigrationError.deviceIDMismatch
        }
        let result = ValidatedRouterReplacement(
            endpoint: candidate.endpoint,
            deviceID: device.id,
            candidate: candidate,
            credentialLease: credentialLease
        )
        guard try await revalidate(
            result,
            candidate: candidate,
            expectedDeviceID: expectedDeviceID
        ) else { throw RouterEndpointMigrationError.candidateChanged }
        return result
    }

    /// Rechecks all durable identity and credential inputs immediately before
    /// a settings save consumes the validation proof.
    public func revalidate(
        _ validation: ValidatedRouterReplacement,
        candidate: RouterHostMetadata,
        expectedDeviceID: String
    ) async throws -> Bool {
        guard let expected = DeviceIdentityDeduplicator.normalizedMAC(expectedDeviceID),
              let observed = DeviceIdentityDeduplicator.normalizedMAC(validation.deviceID),
              let saved = DeviceIdentityDeduplicator.normalizedMAC(candidate.deviceID),
              expected == observed,
              expected == saved,
              validation.candidate == candidate,
              validation.endpoint == candidate.endpoint,
              Self.hasIndependentTrust(candidate),
              await hostStore.hosts().contains(candidate)
        else { return false }
        return try await credentials.isCurrent(
            validation.credentialLease,
            for: candidate.endpoint,
            role: .client
        )
    }

    /// Consumes a replacement proof inside the administration client's
    /// privileged FIFO. Exact source/candidate metadata and the candidate's
    /// client-credential lease remain locked until the PUT response completes.
    public func updateSettings(
        _ patch: RouterSettingsPatch,
        using client: RouterAdministrationClient,
        validation: ValidatedRouterReplacement,
        source: RouterHostMetadata,
        candidate: RouterHostMetadata,
        expectedDeviceID: String,
        isCurrent: @escaping @MainActor @Sendable () -> Bool
    ) async throws -> RouterSettingsUpdateResult {
        try await client.updateSettings(
            patch,
            sourceEndpoint: source.endpoint,
            isCurrent: { await isCurrent() },
            authorizingDispatch: { dispatch in
                try await performWhileCurrent(
                    validation,
                    source: source,
                    candidate: candidate,
                    expectedDeviceID: expectedDeviceID,
                    operation: dispatch
                )
            }
        )
    }

    private func performWhileCurrent<Result: Sendable>(
        _ validation: ValidatedRouterReplacement,
        source: RouterHostMetadata,
        candidate: RouterHostMetadata,
        expectedDeviceID: String,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        guard source.id != candidate.id,
              let expected = DeviceIdentityDeduplicator.normalizedMAC(expectedDeviceID),
              let sourceDeviceID = DeviceIdentityDeduplicator.normalizedMAC(source.deviceID),
              let observed = DeviceIdentityDeduplicator.normalizedMAC(validation.deviceID),
              let saved = DeviceIdentityDeduplicator.normalizedMAC(candidate.deviceID),
              expected == sourceDeviceID,
              expected == observed,
              expected == saved,
              validation.candidate == candidate,
              validation.endpoint == candidate.endpoint,
              Self.hasIndependentTrust(candidate)
        else { throw RouterEndpointMigrationError.candidateChanged }

        guard let credentialGuard = try await hostStore.withExactHosts(
            [source, candidate],
            operation: {
                try await credentials.withCurrent(
                    validation.credentialLease,
                    for: candidate.endpoint,
                    role: .client,
                    operation: operation
                )
            }
        ), let result = credentialGuard else {
            throw RouterEndpointMigrationError.candidateChanged
        }
        return result
    }

    private static func hasIndependentTrust(_ candidate: RouterHostMetadata) -> Bool {
        guard candidate.scheme.lowercased() == "https" else { return true }
        guard let fingerprint = candidate.certificateFingerprint else { return false }
        return RouterHostValidator.normalizeFingerprint(fingerprint) != nil
    }
}
