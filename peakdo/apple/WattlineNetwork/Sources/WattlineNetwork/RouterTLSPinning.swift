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
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              SecTrustEvaluateWithError(trust, nil),
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
