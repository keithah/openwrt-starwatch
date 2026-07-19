import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct RouterHistorySample: Equatable, Sendable, Decodable {
    public let at: Date
    public let level: Int
    public let status: Int
    public let dcWatts: Double?
    public let typeCWatts: Double?

    private enum CodingKeys: String, CodingKey {
        case at
        case level
        case status
        case dcWatts = "dc_w"
        case typeCWatts = "typec_w"
    }
}

/// Client-role history fetch. History is the router's bounded cache; Wattline
/// never fabricates samples or persists a second history database.
public struct RouterHistoryClient: Sendable {
    private let httpClient: any RouterHTTPClient
    private let credentials: any RouterCredentialProvider
    private let endpoint: RouterEndpoint

    public init(
        httpClient: any RouterHTTPClient,
        credentials: any RouterCredentialProvider,
        endpoint: RouterEndpoint
    ) {
        self.httpClient = httpClient
        self.credentials = credentials
        self.endpoint = endpoint
    }

    public func fetch() async throws -> [RouterHistorySample] {
        let credential = try await credentials.credential(for: endpoint)
        let (data, _) = try await httpClient.get("/api/v1/history", token: credential.token)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([RouterHistorySample].self, from: data)
        } catch {
            throw NetworkError.decode("History payload was not valid")
        }
    }
}
