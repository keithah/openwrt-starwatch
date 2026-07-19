import Foundation
import Network
import XCTest
@testable import WattlineNetwork

final class RouterEndpointMigrationTests: XCTestCase {
    func testCandidateProbeUsesSelectedEndpointAndSourceAdministratorCredential() async throws {
        let source = endpoint(scheme: "https", host: "router.local", port: 8378, pin: activePin)
        let candidate = endpoint(scheme: "http", host: "router.local", port: 8377, pin: nil)
        let credentials = RouterCredentialStore(backend: AdministrationCredentialBackend())
        try await credentials.saveToken("admin-token", for: source, role: .administrator)
        let http = ScriptedRouterHTTPClient(results: [
            ScriptedRouterHTTPClient.ok(deviceJSON(id: "DC:04:5A:EB:72:2B")),
        ])
        let factory = RecordingHTTPFactory(client: http)
        let validator = RouterEndpointMigrationValidator(
            credentials: credentials,
            httpFactory: factory.make
        )

        let value = try await validator.validate(
            sourceEndpoint: source,
            candidate: candidate,
            expectedDeviceID: "dc045aeb722b"
        )

        XCTAssertEqual(value.endpoint, candidate)
        XCTAssertEqual(value.deviceID, "DC:04:5A:EB:72:2B")
        XCTAssertEqual(factory.endpoints, [candidate])
        XCTAssertEqual(http.calls.map(\.path), ["/api/v1/device"])
        XCTAssertEqual(http.calls.map(\.token), ["admin-token"])
    }

    func testCandidateProbeRejectsDeviceMismatchAndMissingAdminCredential() async throws {
        let mismatch = try await migrationHarness(
            deviceID: "AA:BB:CC:DD:EE:FF",
            storesToken: true
        )
        await XCTAssertThrowsMigrationError(try await mismatch.validator.validate(
            sourceEndpoint: mismatch.source,
            candidate: mismatch.candidate,
            expectedDeviceID: "DC:04:5A:EB:72:2B"
        )) {
            XCTAssertEqual($0 as? RouterEndpointMigrationError, .deviceIDMismatch)
        }

        let missing = try await migrationHarness(
            deviceID: "DC:04:5A:EB:72:2B",
            storesToken: false
        )
        await XCTAssertThrowsMigrationError(try await missing.validator.validate(
            sourceEndpoint: missing.source,
            candidate: missing.candidate,
            expectedDeviceID: "DC:04:5A:EB:72:2B"
        )) {
            XCTAssertEqual($0 as? RouterAdministrationError, .invalidAdministratorToken)
        }
    }

    func testCandidateProbeDoesNotChangeSchemeOrFallbackAfterFailure() async throws {
        let harness = try await migrationHarness(
            candidateScheme: "https",
            result: .failure(RouterHostValidationError.certificateFingerprintMismatch)
        )
        await XCTAssertThrowsMigrationError(try await harness.validator.validate(
            sourceEndpoint: harness.source,
            candidate: harness.candidate,
            expectedDeviceID: "DC:04:5A:EB:72:2B"
        )) {
            XCTAssertEqual(
                $0 as? RouterHostValidationError,
                .certificateFingerprintMismatch
            )
        }
        XCTAssertEqual(harness.factory.endpoints, [harness.candidate])
    }

    func testProductionProbeRejectsRedirectBeforeCredentialCanReachAnotherEndpoint() async throws {
        let target = try await LoopbackHTTPServer.start(response: .ok(
            deviceJSON(id: "DC:04:5A:EB:72:2B")
        ))
        defer { target.stop() }
        let redirect = try await LoopbackHTTPServer.start(response: .redirect(
            "http://127.0.0.1:\(target.port)/api/v1/device"
        ))
        defer { redirect.stop() }
        let endpoint = RouterEndpoint(
            scheme: "http",
            host: "127.0.0.1",
            port: redirect.port,
            certificateFingerprint: nil,
            allowsInsecureWAN: false
        )
        let credentials = RouterCredentialStore(backend: AdministrationCredentialBackend())
        try await credentials.saveToken("admin-token", for: endpoint, role: .administrator)
        let configuration = URLSessionConfiguration.ephemeral
        let validator = RouterEndpointMigrationValidator.production(
            credentials: credentials,
            configuration: configuration
        )

        await XCTAssertThrowsMigrationError(try await validator.validate(
            sourceEndpoint: endpoint,
            candidate: endpoint,
            expectedDeviceID: "DC:04:5A:EB:72:2B"
        )) { _ in }

        XCTAssertEqual(redirect.requests.count, 1)
        XCTAssertTrue(redirect.requests[0].contains("Authorization: Bearer admin-token"))
        XCTAssertTrue(target.requests.isEmpty)
        XCTAssertFalse(target.requests.contains { $0.contains("Bearer admin-token") })
    }
}

private final class LoopbackHTTPServer: @unchecked Sendable {
    enum Response {
        case ok(String)
        case redirect(String)

        var wire: Data {
            switch self {
            case let .ok(body):
                let data = Data(body.utf8)
                return Data(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8
                ) + data
            case let .redirect(location):
                return Data(
                    "HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8
                )
            }
        }
    }

    private let listener: NWListener
    private let queue: DispatchQueue
    private let response: Response
    private let lock = NSLock()
    private var recordedRequests: [String] = []

    private init(listener: NWListener, response: Response) {
        self.listener = listener
        self.response = response
        queue = DispatchQueue(label: "WattlineNetworkTests.LoopbackHTTPServer")
    }

    static func start(response: Response) async throws -> LoopbackHTTPServer {
        let listener = try NWListener(using: .tcp, on: .any)
        let server = LoopbackHTTPServer(listener: listener, response: response)
        try await server.start()
        return server
    }

    var port: Int { Int(listener.port!.rawValue) }
    var requests: [String] { lock.withLock { recordedRequests } }

    func stop() { listener.cancel() }

    private func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        try await withCheckedThrowingContinuation { continuation in
            let resumeFlag = ResumeFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready where resumeFlag.claim():
                    continuation.resume()
                case let .failed(error) where resumeFlag.claim():
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(from: connection, accumulated: Data())
    }

    private func receive(from connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var request = accumulated
            if let data { request.append(data) }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil || isComplete || error != nil {
                lock.withLock {
                    recordedRequests.append(String(decoding: request, as: UTF8.self))
                }
                connection.send(content: response.wire, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            } else {
                receive(from: connection, accumulated: request)
            }
        }
    }
}

private final class ResumeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}

private struct MigrationHarness {
    let source: RouterEndpoint
    let candidate: RouterEndpoint
    let validator: RouterEndpointMigrationValidator
    let factory: RecordingHTTPFactory
}

private func migrationHarness(
    deviceID: String = "DC:04:5A:EB:72:2B",
    storesToken: Bool = true,
    candidateScheme: String = "http",
    result: Result<(Data, HTTPURLResponse), Error>? = nil
) async throws -> MigrationHarness {
    let source = endpoint(scheme: "https", host: "router.local", port: 8378, pin: activePin)
    let candidate = endpoint(
        scheme: candidateScheme,
        host: "router.local",
        port: candidateScheme == "https" ? 8378 : 8377,
        pin: candidateScheme == "https" ? activePin : nil
    )
    let credentials = RouterCredentialStore(backend: AdministrationCredentialBackend())
    if storesToken {
        try await credentials.saveToken("admin-token", for: source, role: .administrator)
    }
    let http = ScriptedRouterHTTPClient(results: [
        result ?? ScriptedRouterHTTPClient.ok(deviceJSON(id: deviceID)),
    ])
    let factory = RecordingHTTPFactory(client: http)
    return MigrationHarness(
        source: source,
        candidate: candidate,
        validator: RouterEndpointMigrationValidator(
            credentials: credentials,
            httpFactory: factory.make
        ),
        factory: factory
    )
}

private func XCTAssertThrowsMigrationError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw an error")
    } catch {
        errorHandler(error)
    }
}

private let activePin = String(repeating: "01", count: 32)

private func endpoint(
    scheme: String,
    host: String,
    port: Int,
    pin: String?
) -> RouterEndpoint {
    RouterEndpoint(
        scheme: scheme,
        host: host,
        port: port,
        certificateFingerprint: pin,
        allowsInsecureWAN: false
    )
}

private func deviceJSON(id: String) -> String {
    #"{"id":"\#(id)","model":"BP4SL3V2","hardware_revision":"V2","application_firmware":"1.4.9","ota_firmware":"1.0.3","cid":773,"features_raw":32767,"features":{},"available":{"current_time":true,"ota":true,"dc":true,"usbc":true},"mode":"ota","connection":{"connected":true,"phase":"bootloader","reconnect":"bootloader"},"commands":{"active":[],"recent":[]},"magic_dns_name":"wattline.example.ts.net"}"#
}

private final class RecordingHTTPFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let client: any RouterHTTPClient
    private var recorded: [RouterEndpoint] = []

    init(client: any RouterHTTPClient) {
        self.client = client
    }

    var endpoints: [RouterEndpoint] { lock.withLock { recorded } }

    func make(_ endpoint: RouterEndpoint) throws -> any RouterHTTPClient {
        lock.withLock { recorded.append(endpoint) }
        return client
    }
}
