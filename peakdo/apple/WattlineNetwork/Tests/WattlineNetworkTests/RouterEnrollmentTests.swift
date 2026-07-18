import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import WattlineNetwork

final class RouterPairingPayloadTests: XCTestCase {
    private let fingerprint = String(repeating: "01", count: 32)

    func testParsesDocumentedV1PayloadAndPrefersPinnedHTTPS() throws {
        let url = try XCTUnwrap(URL(string:
            "wattline://pair?v=1&id=DC%3A04%3A5A%3AEB%3A72%3A2B&host=wattline.lan&http=8377&https=8378&pin=123456&tls=\(fingerprint)"
        ))

        let payload = try RouterPairingPayload.parse(url)

        XCTAssertEqual(payload.deviceID, "DC045AEB722B")
        XCTAssertEqual(payload.host, "wattline.lan")
        XCTAssertEqual(payload.httpPort, 8377)
        XCTAssertEqual(payload.httpsPort, 8378)
        XCTAssertEqual(payload.pin, "123456")
        XCTAssertEqual(payload.certificateFingerprint, fingerprint)
        XCTAssertEqual(payload.enrollmentEndpoint.scheme, "https")
        XCTAssertEqual(payload.enrollmentEndpoint.port, 8378)
        XCTAssertFalse(String(describing: payload).contains("123456"))
    }

    func testRejectsMalformedOrAmbiguousPayloads() throws {
        let invalid = [
            "https://pair?v=1&id=DC%3A04%3A5A%3AEB%3A72%3A2B&host=wattline.lan&http=8377&pin=123456",
            "wattline://pair?v=2&id=DC%3A04%3A5A%3AEB%3A72%3B&host=wattline.lan&http=8377&pin=123456",
            "wattline://pair?v=1&id=bad&host=wattline.lan&http=8377&pin=123456",
            "wattline://pair?v=1&id=DC%3A04%3A5A%3AEB%3A72%3A2B&host=&http=8377&pin=123456",
            "wattline://pair?v=1&id=DC%3A04%3A5A%3AEB%3A72%3A2B&host=wattline.lan&http=0&pin=123456",
            "wattline://pair?v=1&id=DC%3A04%3A5A%3AEB%3A72%3A2B&host=wattline.lan&http=8377&pin=12345",
            "wattline://pair?v=1&id=DC%3A04%3A5A%3AEB%3A72%3A2B&host=wattline.lan&https=8378&pin=123456",
            "wattline://pair?v=1&id=DC%3A04%3A5A%3AEB%3A72%3A2B&host=wattline.lan&http=8377&pin=123456&tls=\(fingerprint)",
            "wattline://pair?v=1&v=1&id=DC%3A04%3A5A%3AEB%3A72%3A2B&host=wattline.lan&http=8377&pin=123456",
        ]

        for value in invalid {
            XCTAssertThrowsError(try RouterPairingPayload.parse(XCTUnwrap(URL(string: value))), value)
        }
    }
}

final class RouterEnrollmentClientTests: XCTestCase {
    private let fingerprint = String(repeating: "01", count: 32)
    private let deviceID = "DC:04:5A:EB:72:2B"

    func testEnrollmentUsesPublicPairRouteAndCorrelatesIdentityAndPin() async throws {
        let server = EnrollmentHTTPRecorder(response: .init(
            status: 201,
            body: #"{"token":"wlt_secret-token","token_metadata":{"id":"7dd64d22b0c14e7b","label":"Keith's iPhone","created_at":"2026-07-17T20:00:00Z","last_seen_at":null,"bootstrap":false},"device_id":"DC:04:5A:EB:72:2B","base_urls":{"https":"https://wattline.lan:8378/api/v1","http":"http://wattline.lan:8377/api/v1"},"tls_sha256":"\#(fingerprint)","magic_dns_name":"wattline.example.ts.net"}"#
        ))
        let client = RouterEnrollmentClient(httpClient: server)

        let result = try await client.enroll(
            pin: "123456",
            label: "Keith's iPhone",
            expectedDeviceID: deviceID,
            expectedFingerprint: fingerprint
        )

        let requests = await server.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v1/pair")
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(request.body)) as? [String: String]
        XCTAssertEqual(body, ["pin": "123456", "label": "Keith's iPhone"])
        XCTAssertEqual(result.deviceID, "DC045AEB722B")
        XCTAssertEqual(result.endpoint.scheme, "https")
        XCTAssertEqual(result.endpoint.certificateFingerprint, fingerprint)
        XCTAssertEqual(result.token, "wlt_secret-token")
        XCTAssertFalse(String(describing: result).contains("wlt_secret-token"))
        XCTAssertFalse(String(describing: result).contains("123456"))
    }

    func testEnrollmentRejectsMismatchAndInvalidPINWithoutReturningSecret() async throws {
        let mismatched = EnrollmentHTTPRecorder(response: .init(
            status: 201,
            body: #"{"token":"wlt_secret-token","token_metadata":{"id":"id","label":"Phone","created_at":"2026-07-17T20:00:00Z","last_seen_at":null,"bootstrap":false},"device_id":"AA:BB:CC:DD:EE:FF","base_urls":{"http":"http://wattline.lan:8377/api/v1"},"tls_sha256":"","magic_dns_name":""}"#
        ))
        do {
            _ = try await RouterEnrollmentClient(httpClient: mismatched).enroll(
                pin: "123456", label: "Phone", expectedDeviceID: deviceID, expectedFingerprint: nil
            )
            XCTFail("expected identity mismatch")
        } catch {
            XCTAssertEqual(error as? RouterEnrollmentError, .deviceIdentityMismatch)
            XCTAssertFalse(String(describing: error).contains("wlt_secret-token"))
        }

        let rejected = EnrollmentHTTPRecorder(response: .init(
            status: 401,
            body: #"{"error":{"code":"invalid_or_expired_pin","message":"Pairing PIN is invalid or expired","details":{}}}"#
        ))
        do {
            _ = try await RouterEnrollmentClient(httpClient: rejected).enroll(
                pin: "123456", label: "Phone", expectedDeviceID: deviceID, expectedFingerprint: nil
            )
            XCTFail("expected rejected PIN")
        } catch {
            XCTAssertEqual(
                error as? NetworkError,
                .api(status: 401, code: .invalidOrExpiredPIN, message: "Pairing PIN is invalid or expired")
            )
        }
    }
}

private actor EnrollmentHTTPRecorder: RouterEnrollmentHTTPClient {
    struct Response: Sendable { let status: Int; let body: String }
    struct Request: Sendable { let method: String; let path: String; let body: Data? }
    private let response: Response
    private(set) var requests: [Request] = []

    init(response: Response) { self.response = response }

    func publicRequest(
        _ method: String,
        _ path: String,
        body: Data?
    ) async throws -> (Data, HTTPURLResponse) {
        requests.append(Request(method: method, path: path, body: body))
        return (
            Data(response.body.utf8),
            HTTPURLResponse(
                url: URL(string: "http://router.local\(path)")!,
                statusCode: response.status,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }
}
