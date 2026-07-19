import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol RouterEnrollmentHTTPClient: Sendable {
    func publicRequest(
        _ method: String,
        _ path: String,
        body: Data?
    ) async throws -> (Data, HTTPURLResponse)
}

public enum RouterEnrollmentError: Error, Equatable, Sendable {
    case invalidRequest
    case invalidResponse
    case deviceIdentityMismatch
    case certificateFingerprintMismatch
}

public struct RouterEnrollmentResult: Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    public let token: String
    public let deviceID: String
    public let endpoint: RouterEndpoint
    public let magicDNSName: String?
    public let tokenID: String?

    public var description: String {
        "RouterEnrollmentResult(deviceID: \(deviceID), endpoint: \(endpoint), token: [REDACTED])"
    }

    public var debugDescription: String { description }
}

public struct RouterEnrollmentClient: Sendable {
    private struct Request: Encodable {
        let pin: String
        let label: String
    }

    private struct Response: Decodable {
        struct BaseURLs: Decodable {
            let https: String?
            let http: String?
        }
        struct TokenMetadata: Decodable {
            let id: String
        }
        let token: String
        let tokenMetadata: TokenMetadata?
        let deviceID: String
        let baseURLs: BaseURLs
        let tlsSHA256: String
        let magicDNSName: String

        private enum CodingKeys: String, CodingKey {
            case token
            case tokenMetadata = "token_metadata"
            case deviceID = "device_id"
            case baseURLs = "base_urls"
            case tlsSHA256 = "tls_sha256"
            case magicDNSName = "magic_dns_name"
        }
    }

    private let httpClient: any RouterEnrollmentHTTPClient

    public init(httpClient: any RouterEnrollmentHTTPClient) {
        self.httpClient = httpClient
    }

    public func enroll(
        pin: String,
        label: String,
        expectedDeviceID: String,
        expectedFingerprint: String?
    ) async throws -> RouterEnrollmentResult {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RouterPairingPayload.isSixDigitPIN(pin),
              trimmedLabel == label,
              !label.isEmpty,
              label.lengthOfBytes(using: .utf8) <= 128,
              label.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              let normalizedExpectedID = DeviceIdentityDeduplicator.normalizedMAC(expectedDeviceID)
        else { throw RouterEnrollmentError.invalidRequest }

        let body = try JSONEncoder().encode(Request(pin: pin, label: label))
        let (data, response) = try await httpClient.publicRequest(
            "POST",
            "/api/v1/pair",
            body: body
        )
        guard response.statusCode == 201 else {
            if !(200..<300).contains(response.statusCode) {
                throw RouterHTTPErrorMapper.error(status: response.statusCode, data: data, token: "")
            }
            throw RouterEnrollmentError.invalidResponse
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              !decoded.token.isEmpty,
              let actualID = DeviceIdentityDeduplicator.normalizedMAC(decoded.deviceID),
              actualID == normalizedExpectedID
        else {
            if let decoded = try? JSONDecoder().decode(Response.self, from: data),
               DeviceIdentityDeduplicator.normalizedMAC(decoded.deviceID) != normalizedExpectedID {
                throw RouterEnrollmentError.deviceIdentityMismatch
            }
            throw RouterEnrollmentError.invalidResponse
        }

        let responseFingerprint = decoded.tlsSHA256.isEmpty
            ? nil
            : RouterHostValidator.normalizeFingerprint(decoded.tlsSHA256)
        if !decoded.tlsSHA256.isEmpty, responseFingerprint == nil {
            throw RouterEnrollmentError.invalidResponse
        }
        if let expectedFingerprint {
            guard let expected = RouterHostValidator.normalizeFingerprint(expectedFingerprint),
                  expected == responseFingerprint
            else { throw RouterEnrollmentError.certificateFingerprintMismatch }
        }

        let endpoint: RouterEndpoint
        if let https = decoded.baseURLs.https {
            guard let fingerprint = responseFingerprint else {
                throw RouterEnrollmentError.invalidResponse
            }
            endpoint = try Self.endpoint(from: https, fingerprint: fingerprint)
        } else if let http = decoded.baseURLs.http {
            endpoint = try Self.endpoint(from: http, fingerprint: nil)
        } else {
            throw RouterEnrollmentError.invalidResponse
        }

        return RouterEnrollmentResult(
            token: decoded.token,
            deviceID: actualID,
            endpoint: endpoint,
            magicDNSName: decoded.magicDNSName.isEmpty ? nil : decoded.magicDNSName,
            tokenID: decoded.tokenMetadata?.id
        )
    }

    private static func endpoint(from value: String, fingerprint: String?) throws -> RouterEndpoint {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == (fingerprint == nil ? "http" : "https"),
              let host = components.host,
              components.path == "/api/v1",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else { throw RouterEnrollmentError.invalidResponse }
        let port = components.port ?? (scheme == "https" ? 8378 : 8377)
        guard (1...65_535).contains(port) else { throw RouterEnrollmentError.invalidResponse }
        return RouterEndpoint(
            scheme: scheme,
            host: host,
            port: port,
            certificateFingerprint: fingerprint,
            allowsInsecureWAN: false
        )
    }
}
