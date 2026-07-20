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
}

extension RouterAdministrationClient {
    public func rotateTLS() async throws -> RouterTLSRotationResponse {
        let attachment = try attachmentLease()
        await acquirePrivilegedMutation()
        defer { releasePrivilegedMutation() }
        try validate(attachment: attachment)
        let body = Data(#"{"confirm":true}"#.utf8)
        let (data, _) = try await send("POST", "/api/v1/tls/rotate", body: body)
        try validate(attachment: attachment)
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
        let credential = try await credentials.credential(for: trial)
        let http = try httpFactory(trial)
        let (data, response) = try await http.get(
            "/api/v1/device",
            token: credential.token
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
