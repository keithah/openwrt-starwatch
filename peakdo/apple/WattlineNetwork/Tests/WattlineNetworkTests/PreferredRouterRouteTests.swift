import Foundation
@testable import WattlineNetwork
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class PreferredRouterRouteTests: XCTestCase {
    func testLANSuccessNeverCallsRemoteAndSelectsLocal() async throws {
        let lan = ScriptedPreferredHTTPClient(results: [.success(Self.okResponse(body: #"{"ok":true}"#))])
        let remote = ScriptedPreferredHTTPClient(results: [])
        let route = PreferredRouterRoute(
            lanHTTP: lan,
            lanEvents: ScriptedPreferredEventStream(scripts: []),
            remoteHTTP: remote,
            remoteEvents: ScriptedPreferredEventStream(scripts: [])
        )

        _ = try await PreferredRouterHTTPClient(route: route).get(
            "/api/v1/status",
            token: "wattline-token"
        )

        let lanCallCount = await lan.callCount
        let remoteCallCount = await remote.callCount
        let selected = await route.selected
        XCTAssertEqual(lanCallCount, 1)
        XCTAssertEqual(remoteCallCount, 0)
        XCTAssertEqual(selected, .local)
    }

    func testOnlyExplicitReachabilityFailuresPermitRemoteFallback() async throws {
        let permitted: [Error] = [
            URLError(.notConnectedToInternet),
            URLError(.cannotFindHost),
            URLError(.cannotConnectToHost),
            URLError(.networkConnectionLost),
            URLError(.timedOut),
            URLError(.dnsLookupFailed),
            NetworkError.transport("typed transport failure"),
        ]
        for error in permitted {
            let remote = ScriptedPreferredHTTPClient(results: [.success(Self.okResponse())])
            let route = Self.makeRoute(lanError: error, remoteHTTP: remote)

            _ = try await PreferredRouterHTTPClient(route: route).get(
                "/api/v1/status",
                token: "wattline-token"
            )

            let remoteCallCount = await remote.callCount
            let selected = await route.selected
            XCTAssertEqual(remoteCallCount, 1, "expected fallback for \(error)")
            XCTAssertEqual(selected, .remote)
        }
    }

    func testTLSAuthAPIDecodeAndCancellationFailuresNeverCallRemote() async {
        let authoritative: [Error] = [
            URLError(.serverCertificateUntrusted),
            URLError(.secureConnectionFailed),
            URLError(.cancelled),
            NetworkError.unauthorized,
            NetworkError.api(status: 409, code: .operationInProgress, message: "busy"),
            NetworkError.httpStatus(500, "server"),
            NetworkError.decode("bad json"),
            NetworkError.goodCloudSessionExpired,
            CancellationError(),
        ]
        for error in authoritative {
            let remote = ScriptedPreferredHTTPClient(results: [.success(Self.okResponse())])
            let route = Self.makeRoute(lanError: error, remoteHTTP: remote)

            do {
                _ = try await PreferredRouterHTTPClient(route: route).get(
                    "/api/v1/status",
                    token: "wattline-token"
                )
                XCTFail("expected authoritative LAN failure for \(error)")
            } catch {
                // The exact LAN failure remains authoritative.
            }

            let remoteCallCount = await remote.callCount
            let selected = await route.selected
            XCTAssertEqual(remoteCallCount, 0, "must not fall back for \(error)")
            XCTAssertEqual(selected, .local)
        }
    }

    func testRemoteSelectionIsSharedBySubsequentHTTPRequestsInBatch() async throws {
        let lan = ScriptedPreferredHTTPClient(results: [
            .failure(URLError(.cannotConnectToHost)),
            .success(Self.okResponse()),
        ])
        let remote = ScriptedPreferredHTTPClient(results: [
            .success(Self.okResponse()),
            .success(Self.okResponse()),
        ])
        let route = PreferredRouterRoute(
            lanHTTP: lan,
            lanEvents: ScriptedPreferredEventStream(scripts: []),
            remoteHTTP: remote,
            remoteEvents: ScriptedPreferredEventStream(scripts: [])
        )
        let client = PreferredRouterHTTPClient(route: route)

        _ = try await client.get("/api/v1/status", token: "wattline-token")
        _ = try await client.request(
            "PUT",
            "/api/v1/settings",
            body: Data(#"{"enabled":true}"#.utf8),
            token: "wattline-token"
        )

        let lanCallCount = await lan.callCount
        let remoteCallCount = await remote.callCount
        let selected = await route.selected
        XCTAssertEqual(lanCallCount, 1)
        XCTAssertEqual(remoteCallCount, 2)
        XCTAssertEqual(selected, .remote)
    }

    func testEachSSEConnectionProbesLANBeforeRemote() async throws {
        let lanEvents = ScriptedPreferredEventStream(scripts: [
            .failure(URLError(.cannotConnectToHost)),
            .values([Data(#"{"route":"local"}"#.utf8)]),
        ])
        let remoteEvents = ScriptedPreferredEventStream(scripts: [
            .values([Data(#"{"route":"remote"}"#.utf8)]),
        ])
        let route = PreferredRouterRoute(
            lanHTTP: ScriptedPreferredHTTPClient(results: []),
            lanEvents: lanEvents,
            remoteHTTP: ScriptedPreferredHTTPClient(results: []),
            remoteEvents: remoteEvents
        )
        let events = PreferredRouterEventStream(route: route)

        let first = try await Self.first(events.events(path: "/api/v1/events", token: "token"))
        let second = try await Self.first(events.events(path: "/api/v1/events", token: "token"))

        XCTAssertEqual(String(decoding: first, as: UTF8.self), #"{"route":"remote"}"#)
        XCTAssertEqual(String(decoding: second, as: UTF8.self), #"{"route":"local"}"#)
        XCTAssertEqual(lanEvents.openCount, 2)
        XCTAssertEqual(remoteEvents.openCount, 1)
        let selected = await route.selected
        XCTAssertEqual(selected, .local)
    }

    func testSSEAuthoritativeFailureDoesNotOpenRemote() async {
        let lanEvents = ScriptedPreferredEventStream(scripts: [
            .failure(NetworkError.unauthorized),
        ])
        let remoteEvents = ScriptedPreferredEventStream(scripts: [
            .values([Data("unexpected".utf8)]),
        ])
        let route = PreferredRouterRoute(
            lanHTTP: ScriptedPreferredHTTPClient(results: []),
            lanEvents: lanEvents,
            remoteHTTP: ScriptedPreferredHTTPClient(results: []),
            remoteEvents: remoteEvents
        )

        do {
            _ = try await Self.first(
                PreferredRouterEventStream(route: route).events(
                    path: "/api/v1/events",
                    token: "token"
                )
            )
            XCTFail("expected LAN authentication failure")
        } catch {
            XCTAssertEqual(error as? NetworkError, .unauthorized)
        }

        XCTAssertEqual(lanEvents.openCount, 1)
        XCTAssertEqual(remoteEvents.openCount, 0)
    }

    private static func makeRoute(
        lanError: Error,
        remoteHTTP: ScriptedPreferredHTTPClient
    ) -> PreferredRouterRoute {
        PreferredRouterRoute(
            lanHTTP: ScriptedPreferredHTTPClient(results: [.failure(lanError)]),
            lanEvents: ScriptedPreferredEventStream(scripts: []),
            remoteHTTP: remoteHTTP,
            remoteEvents: ScriptedPreferredEventStream(scripts: [])
        )
    }

    private static func okResponse(body: String = #"{"ok":true}"#) -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(
            url: URL(string: "http://router.local:8377/api/v1/status")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(body.utf8), response)
    }

    private static func first(
        _ stream: AsyncThrowingStream<Data, Error>
    ) async throws -> Data {
        for try await value in stream {
            return value
        }
        throw NetworkError.streamEnded
    }
}

private actor ScriptedPreferredHTTPClient: RouterHTTPClient {
    private var results: [Result<(Data, HTTPURLResponse), Error>]
    private(set) var callCount = 0

    init(results: [Result<(Data, HTTPURLResponse), Error>]) {
        self.results = results
    }

    func get(_ path: String, token: String) async throws -> (Data, HTTPURLResponse) {
        try await request("GET", path, body: nil, token: token)
    }

    func request(
        _ method: String,
        _ path: String,
        body: Data?,
        token: String
    ) async throws -> (Data, HTTPURLResponse) {
        callCount += 1
        guard !results.isEmpty else {
            throw NetworkError.transport("unexpected HTTP request")
        }
        return try results.removeFirst().get()
    }
}

private final class ScriptedPreferredEventStream: RouterEventStream, @unchecked Sendable {
    enum Script: @unchecked Sendable {
        case values([Data])
        case failure(Error)
    }

    private let lock = NSLock()
    private var scripts: [Script]
    private var opens = 0

    init(scripts: [Script]) {
        self.scripts = scripts
    }

    var openCount: Int { lock.withLock { opens } }

    func events(path: String, token: String) -> AsyncThrowingStream<Data, Error> {
        let script = lock.withLock { () -> Script in
            opens += 1
            guard !scripts.isEmpty else {
                return .failure(NetworkError.transport("unexpected event stream open"))
            }
            return scripts.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            switch script {
            case .values(let values):
                for value in values {
                    continuation.yield(value)
                }
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            }
        }
    }
}
