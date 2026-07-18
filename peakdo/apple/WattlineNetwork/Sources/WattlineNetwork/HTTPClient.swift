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
public final class HTTPClient: RouterHTTPClient, @unchecked Sendable {
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
        var components = URLComponents()
        components.scheme = endpoint.scheme.lowercased()
        components.host = endpoint.host
        components.port = endpoint.port
        guard let baseURL = components.url else { throw RouterHostValidationError.invalidAddress }

        if endpoint.scheme.caseInsensitiveCompare("https") == .orderedSame {
            guard let expectedFingerprint = endpoint.certificateFingerprint else {
                throw RouterHostValidationError.missingCertificateFingerprint
            }
#if canImport(Security) && !canImport(FoundationNetworking)
            let session = URLSession(
                configuration: configuration,
                delegate: RouterTLSPinningDelegate(expectedFingerprint: expectedFingerprint),
                delegateQueue: nil
            )
            self.init(baseURL: baseURL, session: session)
#else
            throw NetworkError.unsupported("HTTPS certificate pinning is unavailable on this platform")
#endif
        } else {
            self.init(baseURL: baseURL, session: URLSession(configuration: configuration))
        }
    }

    public func get(_ path: String, token: String) async throws -> (Data, HTTPURLResponse) {
        try await request("GET", path, body: nil, token: token)
    }

    public func request(_ method: String, _ path: String, body: Data?, token: String) async throws -> (Data, HTTPURLResponse) {
        guard path.hasPrefix("/"), let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw NetworkError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NetworkError.decode("Non-HTTP response") }
        if http.statusCode == 401 {
            throw NetworkError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NetworkError.httpStatus(http.statusCode, body.replacingOccurrences(
                of: token,
                with: "[REDACTED]"
            ))
        }
        return (data, http)
    }
}

public typealias URLSessionHTTPClient = HTTPClient
