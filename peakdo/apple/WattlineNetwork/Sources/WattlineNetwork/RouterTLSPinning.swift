import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

public enum RouterTLSFingerprintPolicy {
    public static func fingerprint(of certificateData: Data) -> String {
        SHA256.hash(data: certificateData)
            .map { String(format: "%02X", $0) }
            .joined()
    }

    public static func matches(expected: String, certificateData: Data) -> Bool {
        guard let normalized = RouterHostValidator.normalizeFingerprint(expected) else {
            return false
        }
        return normalized == fingerprint(of: certificateData)
    }
}

public enum RouterURLSessionFactory {
    public static func baseURL(for endpoint: RouterEndpoint) throws -> URL {
        var components = URLComponents()
        components.scheme = endpoint.scheme.lowercased()
        components.host = endpoint.host
        components.port = endpoint.port
        guard let url = components.url else { throw RouterHostValidationError.invalidAddress }
        return url
    }

    public static func make(
        endpoint: RouterEndpoint,
        configuration: URLSessionConfiguration = .ephemeral
    ) throws -> URLSession {
        if endpoint.scheme.caseInsensitiveCompare("https") == .orderedSame {
            guard let expectedFingerprint = endpoint.certificateFingerprint else {
                throw RouterHostValidationError.missingCertificateFingerprint
            }
#if canImport(Security) && !canImport(FoundationNetworking)
            return URLSession(
                configuration: configuration,
                delegate: RouterTLSPinningDelegate(expectedFingerprint: expectedFingerprint),
                delegateQueue: nil
            )
#else
            throw NetworkError.unsupported("HTTPS certificate pinning is unavailable on this platform")
#endif
        }
        return URLSession(configuration: configuration)
    }
}

#if canImport(Security) && !canImport(FoundationNetworking)
final class RouterTLSPinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let expectedFingerprint: String

    init(expectedFingerprint: String) {
        self.expectedFingerprint = expectedFingerprint
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let trust = challenge.protectionSpace.serverTrust,
              let certificateChain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = certificateChain.first
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let certificateData = SecCertificateCopyData(certificate) as Data
        guard RouterTLSFingerprintPolicy.matches(
            expected: expectedFingerprint,
            certificateData: certificateData
        ) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
#endif
