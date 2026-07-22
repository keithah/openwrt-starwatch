import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class RemoteRouterHTTPClient: RouterHTTPClient, @unchecked Sendable {
    private let coordinator: any RemoteRelayCoordinating

    public init(coordinator: any RemoteRelayCoordinating) {
        self.coordinator = coordinator
    }

    public func get(_ path: String, token: String) async throws -> (Data, HTTPURLResponse) {
        try await request("GET", path, body: nil, token: token)
    }

    public func request(
        _ method: String,
        _ path: String,
        body: Data?,
        token: String
    ) async throws -> (Data, HTTPURLResponse) {
        guard path.hasPrefix("/") else {
            throw NetworkError.invalidURL
        }
        var headers = ["Authorization": "Bearer \(token)"]
        if body != nil {
            headers["Content-Type"] = "application/json"
        }
        let (data, response) = try await coordinator.request(
            method: method,
            path: path,
            headers: headers,
            body: body
        )
        guard (200..<300).contains(response.statusCode) else {
            throw RouterHTTPErrorMapper.error(
                status: response.statusCode,
                data: data,
                token: token
            )
        }
        return (data, response)
    }
}
