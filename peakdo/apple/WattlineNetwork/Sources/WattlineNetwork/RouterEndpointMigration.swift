import Foundation

public struct ValidatedRouterReplacement: Equatable, Sendable {
    public let endpoint: RouterEndpoint
    public let deviceID: String
}

public enum RouterEndpointMigrationError: Error, Equatable, Sendable {
    case invalidExpectedDeviceID
    case invalidResponse
    case deviceIDMismatch
}

public struct RouterEndpointMigrationValidator: Sendable {
    public typealias HTTPFactory = @Sendable (RouterEndpoint) throws -> any RouterHTTPClient

    private let credentials: RouterCredentialStore
    private let httpFactory: HTTPFactory

    public init(credentials: RouterCredentialStore, httpFactory: @escaping HTTPFactory) {
        self.credentials = credentials
        self.httpFactory = httpFactory
    }

    public func validate(
        sourceEndpoint: RouterEndpoint,
        candidate: RouterEndpoint,
        expectedDeviceID: String
    ) async throws -> ValidatedRouterReplacement {
        guard let expected = DeviceIdentityDeduplicator.normalizedMAC(expectedDeviceID) else {
            throw RouterEndpointMigrationError.invalidExpectedDeviceID
        }
        guard let token = try await credentials.readToken(
            for: sourceEndpoint,
            role: .administrator
        ) else {
            throw RouterAdministrationError.invalidAdministratorToken
        }
        let (data, response) = try await httpFactory(candidate).get(
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
        return ValidatedRouterReplacement(endpoint: candidate, deviceID: device.id)
    }
}
