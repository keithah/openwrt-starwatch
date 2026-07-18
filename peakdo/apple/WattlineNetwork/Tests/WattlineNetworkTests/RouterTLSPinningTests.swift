import Foundation
import Security
import XCTest
@testable import WattlineNetwork

final class RouterTLSPinningTests: XCTestCase {
    func testSelfSignedServerTrustUsesMatchingPinAsAuthority() throws {
        let certificateData = try XCTUnwrap(Data(base64Encoded: Self.selfSignedCertificateDER))
        let trust = try makeTrust(certificateData: certificateData)
        XCTAssertFalse(SecTrustEvaluateWithError(trust, nil), "fixture must be untrusted by the system")
        let delegate = RouterTLSPinningDelegate(
            expectedFingerprint: RouterTLSFingerprintPolicy.fingerprint(of: certificateData)
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: TrustProtectionSpace(trust: trust),
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: ChallengeSender()
        )

        let result = invoke(delegate: delegate, challenge: challenge)

        XCTAssertEqual(result.disposition, .useCredential)
        XCTAssertNotNil(result.credential)
    }

    func testSelfSignedServerTrustCancelsOnPinMismatch() throws {
        let certificateData = try XCTUnwrap(Data(base64Encoded: Self.selfSignedCertificateDER))
        let trust = try makeTrust(certificateData: certificateData)
        let delegate = RouterTLSPinningDelegate(expectedFingerprint: String(repeating: "00", count: 32))
        let challenge = URLAuthenticationChallenge(
            protectionSpace: TrustProtectionSpace(trust: trust),
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: ChallengeSender()
        )

        let result = invoke(delegate: delegate, challenge: challenge)

        XCTAssertEqual(result.disposition, .cancelAuthenticationChallenge)
        XCTAssertNil(result.credential)
    }

    func testNonServerTrustChallengeUsesDefaultHandling() {
        let delegate = RouterTLSPinningDelegate(expectedFingerprint: String(repeating: "00", count: 32))
        let protectionSpace = URLProtectionSpace(
            host: "wattline-router.local",
            port: 443,
            protocol: "https",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: protectionSpace,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: ChallengeSender()
        )

        let result = invoke(delegate: delegate, challenge: challenge)

        XCTAssertEqual(result.disposition, .performDefaultHandling)
        XCTAssertNil(result.credential)
    }

    func testSharedSessionFactoryProtectsHTTPAndSSEIdentically() throws {
        let plainEndpoint = endpoint(scheme: "http", fingerprint: nil)
        let unpinnedHTTPS = endpoint(scheme: "https", fingerprint: nil)
        let pinnedHTTPS = endpoint(scheme: "https", fingerprint: String(repeating: "AB", count: 32))

        let plain = try RouterURLSessionFactory.make(endpoint: plainEndpoint)
        XCTAssertFalse(plain.delegate is RouterTLSPinningDelegate)
        XCTAssertNoThrow(try HTTPClient(endpoint: plainEndpoint))
        XCTAssertNoThrow(try SSEClient(endpoint: plainEndpoint))

        XCTAssertThrowsError(try SSEClient(endpoint: unpinnedHTTPS)) { error in
            XCTAssertEqual(error as? RouterHostValidationError, .missingCertificateFingerprint)
        }
        let pinned = try RouterURLSessionFactory.make(endpoint: pinnedHTTPS)
        XCTAssertTrue(pinned.delegate is RouterTLSPinningDelegate)
        XCTAssertNoThrow(try HTTPClient(endpoint: pinnedHTTPS))
        XCTAssertNoThrow(try SSEClient(endpoint: pinnedHTTPS))
    }

    private func endpoint(scheme: String, fingerprint: String?) -> RouterEndpoint {
        RouterEndpoint(
            scheme: scheme,
            host: "wattline-router.local",
            port: scheme == "https" ? 443 : 8080,
            certificateFingerprint: fingerprint,
            allowsInsecureWAN: false
        )
    }

    private func makeTrust(certificateData: Data) throws -> SecTrust {
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, certificateData as CFData))
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(
            certificate,
            SecPolicyCreateSSL(true, "wattline-router.local" as CFString),
            &trust
        )
        XCTAssertEqual(status, errSecSuccess)
        return try XCTUnwrap(trust)
    }

    private func invoke(
        delegate: RouterTLSPinningDelegate,
        challenge: URLAuthenticationChallenge
    ) -> (disposition: URLSession.AuthChallengeDisposition, credential: URLCredential?) {
        let capture = ChallengeResultCapture()
        delegate.urlSession(URLSession.shared, didReceive: challenge) { disposition, credential in
            capture.set(disposition: disposition, credential: credential)
        }
        return capture.value!
    }

    private static let selfSignedCertificateDER = "MIIDITCCAgmgAwIBAgIUVAljdEVSjtweLe5sVCRp9Tu6Fu4wDQYJKoZIhvcNAQELBQAwIDEeMBwGA1UEAwwVd2F0dGxpbmUtcm91dGVyLmxvY2FsMB4XDTI2MDcxODAxNDg1NVoXDTM2MDcxNTAxNDg1NVowIDEeMBwGA1UEAwwVd2F0dGxpbmUtcm91dGVyLmxvY2FsMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAu326mPbjJFPql++wJ20j0UmAMP0I1tXCcpYR9jPbAUXQbpHXOu8A9wndErbDgK/aDVlwGtJqiCNCj280CvOLx3umYyfqRysfk1LD25xBCOS8hhdNRHpQmCqlRTQ0qXUchtt2WCq57qexKuvtLSPXNEFNWkRS8Vs7g0mWF9sfzobYiD7faO2YK9bQEmvQoXU60IMHREAr36MeGN2SqYgOS760XBYLUwnbduHd8Z3q2Dqy29BGYwSL3VIIizzT3BG8Y/PyKro8NSyDl3LM/2im9vTjW/Ex3O2oJPV//nT2YABpT97DFA+SPPT9Qjz7LfxqVEAl+EakB6wO8K7Qbrd1fQIDAQABo1MwUTAdBgNVHQ4EFgQUfNz23CkeXyYkndap/60K6bOtQtowHwYDVR0jBBgwFoAUfNz23CkeXyYkndap/60K6bOtQtowDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEAXdKWJKwKsnRnPjqPQR7VEkGwgigZblAq0xIYb9c7VwBeM6ds4Sd9BM3h44oRUdp4/6UHFQQS+EPV977OK8CcKUTaqxJzB7P4WdWTasow5lbAo/zvM/O3LyczGV7dFCU+wpmex1PGUCzsfemoWkHDGBFTs6jmT9MG/gah9qK2B3P9HoxC4o6pxwi0JqqGY5Z6D8QLfe10ELq9sfwdovV3GZNtauPJoksr7p1RFTHzHcOkkDBOYq0TFtglGmVFA0PMMpbzMcMcChl6i9VKYYHpctlHXGTzHiuSV4Ymf/v7gy/aaQoXxrJLvDzwOf2fjPAYl0XRRiAtEqGFQUKsRdIGyg=="
}

private final class TrustProtectionSpace: URLProtectionSpace, @unchecked Sendable {
    private let storedTrust: SecTrust
    override var serverTrust: SecTrust? { storedTrust }
    override var authenticationMethod: String { NSURLAuthenticationMethodServerTrust }

    init(trust: SecTrust) {
        storedTrust = trust
        super.init(
            host: "wattline-router.local",
            port: 443,
            protocol: "https",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable in tests")
    }
}

private final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}

private final class ChallengeResultCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: (URLSession.AuthChallengeDisposition, URLCredential?)?
    var value: (URLSession.AuthChallengeDisposition, URLCredential?)? {
        lock.withLock { storedValue }
    }
    func set(disposition: URLSession.AuthChallengeDisposition, credential: URLCredential?) {
        lock.withLock { storedValue = (disposition, credential) }
    }
}
