import Foundation

public struct RouterTLSRotationResponse: Equatable, Sendable, Decodable {
    public let sha256: String
    public let restartRequired: Bool

    enum CodingKeys: String, CodingKey {
        case sha256
        case restartRequired = "restart_required"
    }
}

public enum RouterTLSPromotionError: Error, Equatable, Sendable {
    case invalidRotationResponse
    case invalidHost
    case missingStagedPin
    case deviceIDMismatch
    case hostChanged
    case missingCredential
}

extension RouterAdministrationClient {
    public func rotateTLS() async throws -> RouterTLSRotationResponse {
        let attachment = try attachmentLease()
        await acquirePrivilegedMutation()
        defer { releasePrivilegedMutation() }
        try validate(attachment: attachment)
        let body = Data(#"{"confirm":true}"#.utf8)
        let (data, _) = try await sendDurableMutation(
            "POST",
            "/api/v1/tls/rotate",
            body: body,
            attachment: attachment
        )
        guard let value = try? JSONDecoder().decode(RouterTLSRotationResponse.self, from: data),
              value.restartRequired,
              value.sha256.utf8.count == 64,
              value.sha256.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              })
        else { throw RouterAdministrationError.invalidResponse }
        return value
    }
}

public actor RouterTLSPinPromoter {
    public typealias HTTPFactory = @Sendable (RouterEndpoint) throws -> any RouterHTTPClient

    private let hostStore: RouterHostStore
    private let credentials: RouterCredentialStore
    private let httpFactory: HTTPFactory

    private enum CredentialSource {
        case stored
        case transientAdministrator(String)
    }

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
    ) -> RouterTLSPinPromoter {
        RouterTLSPinPromoter(hostStore: hostStore, credentials: credentials) { endpoint in
            HTTPClient(
                baseURL: try RouterURLSessionFactory.baseURL(for: endpoint),
                session: try RouterURLSessionFactory.makeMigration(
                    endpoint: endpoint,
                    configuration: configuration
                )
            )
        }
    }

    public func promote(hostID: UUID) async throws -> RouterHostMetadata {
        try await promote(hostID: hostID, credentialSource: .stored)
    }

    /// Explicit recovery for a staged-pin endpoint when neither retained role
    /// credential can authenticate. The supplied administrator token remains
    /// task-local and is never written to the credential store.
    public func promote(
        hostID: UUID,
        administratorToken: String
    ) async throws -> RouterHostMetadata {
        guard !administratorToken.isEmpty else {
            throw RouterTLSPromotionError.missingCredential
        }
        return try await promote(
            hostID: hostID,
            credentialSource: .transientAdministrator(administratorToken)
        )
    }

    private func promote(
        hostID: UUID,
        credentialSource: CredentialSource
    ) async throws -> RouterHostMetadata {
        guard let host = await hostStore.hosts().first(where: { $0.id == hostID }),
              host.scheme == "https",
              let active = host.certificateFingerprint,
              let expectedID = DeviceIdentityDeduplicator.normalizedMAC(host.deviceID)
        else { throw RouterTLSPromotionError.invalidHost }
        guard let staged = host.stagedCertificateFingerprint else {
            throw RouterTLSPromotionError.missingStagedPin
        }

        let trial = RouterEndpoint(
            scheme: "https",
            host: host.host,
            port: host.port,
            certificateFingerprint: staged,
            allowsInsecureWAN: false
        )
        let token: String
        switch credentialSource {
        case let .transientAdministrator(value):
            token = value
        case .stored:
            if let administrator = try await credentials.readToken(
                for: trial,
                role: .administrator
            ) {
                token = administrator
            } else if let client = try await credentials.readToken(for: trial, role: .client) {
                token = client
            } else {
                throw RouterTLSPromotionError.missingCredential
            }
        }
        let http = try httpFactory(trial)
        let (data, response) = try await http.get(
            "/api/v1/device",
            token: token
        )
        guard response.statusCode == 200,
              let device = try? JSONDecoder().decode(RouterDeviceDTO.self, from: data),
              let observedID = DeviceIdentityDeduplicator.normalizedMAC(device.id),
              observedID == expectedID
        else { throw RouterTLSPromotionError.deviceIDMismatch }

        return try await hostStore.promoteCertificateFingerprint(
            for: hostID,
            expectedEndpoint: host.endpoint,
            expectedActive: active,
            expectedStaged: staged,
            expectedDeviceID: expectedID
        )
    }
}
