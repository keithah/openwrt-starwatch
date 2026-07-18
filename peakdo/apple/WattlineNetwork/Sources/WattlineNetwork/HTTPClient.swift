import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol RouterHTTPClient: Sendable {
    func get(_ path: String, token: String) async throws -> (Data, HTTPURLResponse)
    func request(_ method: String, _ path: String, body: Data?, token: String) async throws -> (Data, HTTPURLResponse)
}

/// URLSession-backed router client. Keeping this implementation behind the protocol
/// makes transport tests deterministic and entirely local.
public final class HTTPClient: RouterHTTPClient, RouterEnrollmentHTTPClient, @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Production construction from validated host metadata. HTTPS endpoints
    /// always use certificate fingerprint pinning; HTTP relies on the host
    /// validator's LAN/VPN or explicit insecure-WAN policy.
    public convenience init(
        endpoint: RouterEndpoint,
        configuration: URLSessionConfiguration = .ephemeral
    ) throws {
        self.init(
            baseURL: try RouterURLSessionFactory.baseURL(for: endpoint),
            session: try RouterURLSessionFactory.make(
                endpoint: endpoint,
                configuration: configuration
            )
        )
    }

    public func get(_ path: String, token: String) async throws -> (Data, HTTPURLResponse) {
        try await request("GET", path, body: nil, token: token)
    }

    public func request(_ method: String, _ path: String, body: Data?, token: String) async throws -> (Data, HTTPURLResponse) {
        try await send(method, path, body: body, authorization: "Bearer \(token)", token: token)
    }

    public func publicRequest(
        _ method: String,
        _ path: String,
        body: Data?
    ) async throws -> (Data, HTTPURLResponse) {
        try await send(method, path, body: body, authorization: nil, token: nil)
    }

    private func send(
        _ method: String,
        _ path: String,
        body: Data?,
        authorization: String?,
        token: String?
    ) async throws -> (Data, HTTPURLResponse) {
        guard path.hasPrefix("/"), let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw NetworkError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NetworkError.decode("Non-HTTP response") }
        if let token, !(200..<300).contains(http.statusCode) {
            throw RouterHTTPErrorMapper.error(status: http.statusCode, data: data, token: token)
        }
        return (data, http)
    }
}

public typealias URLSessionHTTPClient = HTTPClient
