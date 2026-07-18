import Foundation
import XCTest
@testable import WattlineNetwork

final class HTTPAndSSEClientTests: XCTestCase {
    override func tearDown() {
        URLProtocolFixture.reset()
        super.tearDown()
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolFixture.self]
        return URLSession(configuration: configuration)
    }

    func testHTTPClientUsesBearerAndDecodesJSON() async throws {
        URLProtocolFixture.response = .init(status: 200, body: Data(#"{"ok":true}"#.utf8))
        let client = HTTPClient(baseURL: URL(string: "http://fixture.local")!, session: session())
        let (data, response) = try await client.get("/health", token: "secret")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? [String: Bool], ["ok": true])
        XCTAssertEqual(URLProtocolFixture.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    }

    func testHTTPClientThrowsNon2xxNetworkError() async {
        URLProtocolFixture.response = .init(status: 503, body: Data("down".utf8))
        let client = HTTPClient(baseURL: URL(string: "http://fixture.local")!, session: session())
        do { _ = try await client.get("/health", token: "secret"); XCTFail("expected error") }
        catch { XCTAssertEqual(error as? NetworkError, .httpStatus(503, "down")) }
    }

    func testHTTPClientDecodesCanonicalAPIErrorEnvelope() async {
        URLProtocolFixture.response = .init(
            status: 409,
            body: Data(#"{"error":{"code":"capability_unsupported","message":"Operation is not supported","details":{}}}"#.utf8)
        )
        let client = HTTPClient(baseURL: URL(string: "http://fixture.local")!, session: session())

        do {
            _ = try await client.get("/api/v1/device", token: "secret-token")
            XCTFail("expected canonical API error")
        } catch {
            XCTAssertEqual(
                error as? NetworkError,
                .api(status: 409, code: .capabilityUnsupported, message: "Operation is not supported")
            )
            XCTAssertFalse(String(describing: error).contains("secret-token"))
        }
    }

    func testHTTPClientMapsUnauthorizedWithoutExposingToken() async {
        URLProtocolFixture.response = .init(
            status: 401,
            body: Data("invalid secret-token".utf8)
        )
        let client = HTTPClient(baseURL: URL(string: "http://fixture.local")!, session: session())

        do {
            _ = try await client.get("/api/v1/status", token: "secret-token")
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? NetworkError, .unauthorized)
            XCTAssertFalse(String(describing: error).contains("secret-token"))
        }
    }

    func testHTTPClientRedactsTokenFromHTTPErrorBody() async {
        URLProtocolFixture.response = .init(
            status: 503,
            body: Data("request rejected for secret-token".utf8)
        )
        let client = HTTPClient(baseURL: URL(string: "http://fixture.local")!, session: session())

        do {
            _ = try await client.get("/api/v1/status", token: "secret-token")
            XCTFail("expected HTTP error")
        } catch {
            XCTAssertEqual(
                error as? NetworkError,
                .httpStatus(503, "request rejected for [REDACTED]")
            )
            XCTAssertFalse(String(describing: error).contains("secret-token"))
        }
    }

    func testHTTPClientRejectsInvalidURL() async {
        let client = HTTPClient(baseURL: URL(string: "http://fixture.local")!, session: session())
        do { _ = try await client.get("://bad", token: "secret"); XCTFail("expected error") }
        catch { XCTAssertEqual(error as? NetworkError, .invalidURL) }
    }

    func testSSEClientParsesRawDataFramesAndBlankLines() async throws {
        let wire = "data: {\"n\":1}\n\ndata: second\n\ndata: third\n\n"
        URLProtocolFixture.response = .init(status: 200, body: Data(wire.utf8), contentType: "text/event-stream")
        let client = SSEClient(baseURL: URL(string: "http://fixture.local")!, session: session())
        var values: [Data] = []
        for try await value in client.events(path: "/events", token: "token") { values.append(value) }
        XCTAssertEqual(values, [Data(#"{"n":1}"#.utf8), Data("second".utf8), Data("third".utf8)])
        XCTAssertEqual(URLProtocolFixture.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer token")
    }

    func testSSEClientDecodesUTF8WhenMultibyteCharactersSpanChunks() async throws {
        URLProtocolFixture.response = .init(
            status: 200,
            body: Data(),
            chunks: [
                Data("data: {\"name\":\"caf".utf8),
                Data([0xC3]),
                Data([0xA9, 0x20, 0xE2]),
                Data([0x9A, 0xA1, 0x22, 0x7D, 0x0A, 0x0A])
            ],
            contentType: "text/event-stream"
        )
        let client = SSEClient(baseURL: URL(string: "http://fixture.local")!, session: session())

        var values: [Data] = []
        for try await value in client.events(path: "/events", token: "token") {
            values.append(value)
        }

        XCTAssertEqual(values, [Data(#"{"name":"café ⚡"}"#.utf8)])
    }

    func testSSEClientPreservesInvalidUTF8InDataForStrictJSONRejection() async throws {
        var invalidJSON = Data(#"{"connected":true,"bad":""#.utf8)
        invalidJSON.append(0xFF)
        invalidJSON.append(contentsOf: Data(#""}"#.utf8))
        var wire = Data("data: ".utf8)
        wire.append(invalidJSON)
        wire.append(contentsOf: Data("\n\n".utf8))
        URLProtocolFixture.response = .init(
            status: 200,
            body: wire,
            contentType: "text/event-stream"
        )
        let client = SSEClient(baseURL: URL(string: "http://fixture.local")!, session: session())

        var values: [Data] = []
        for try await value in client.events(path: "/events", token: "token") {
            values.append(value)
        }

        XCTAssertEqual(values, [invalidJSON])
        XCTAssertNil(String(data: invalidJSON, encoding: .utf8))
    }

    func testSSEClientIgnoresStandardAndUnknownNonDataFields() async throws {
        let wire = "event: telemetry\nid: 7\nretry: 1000\nfuture-field: yes\ndata: accepted\n\n"
        URLProtocolFixture.response = .init(status: 200, body: Data(wire.utf8), contentType: "text/event-stream")
        let client = SSEClient(baseURL: URL(string: "http://fixture.local")!, session: session())

        var values: [Data] = []
        for try await value in client.events(path: "/events", token: "token") {
            values.append(value)
        }

        XCTAssertEqual(values, [Data("accepted".utf8)])
    }

    func testSSEClientAcceptsBareDataAsEmptyPayload() async throws {
        URLProtocolFixture.response = .init(
            status: 200,
            body: Data("data\n\n".utf8),
            contentType: "text/event-stream"
        )
        let client = SSEClient(baseURL: URL(string: "http://fixture.local")!, session: session())

        var values: [Data] = []
        for try await value in client.events(path: "/events", token: "token") {
            values.append(value)
        }

        XCTAssertEqual(values, [Data()])
    }

    func testSSEClientDiscardsUnterminatedEventAtEOF() async throws {
        URLProtocolFixture.response = .init(
            status: 200,
            body: Data("data: truncated".utf8),
            contentType: "text/event-stream"
        )
        let client = SSEClient(baseURL: URL(string: "http://fixture.local")!, session: session())

        var values: [Data] = []
        for try await value in client.events(path: "/events", token: "token") {
            values.append(value)
        }

        XCTAssertTrue(values.isEmpty)
    }

    func testSSEClientClosesWithoutExtraEvents() async throws {
        URLProtocolFixture.response = .init(status: 200, body: Data(), contentType: "text/event-stream")
        let client = SSEClient(baseURL: URL(string: "http://fixture.local")!, session: session())
        var count = 0
        for try await _ in client.events(path: "/events", token: "token") { count += 1 }
        XCTAssertEqual(count, 0)
    }

    func testSSEClientYieldsFramesBeforeConnectionFinishes() async throws {
        URLProtocolFixture.response = .init(
            status: 200,
            body: Data(),
            chunks: [Data("data: first\n\n".utf8), Data("data: second\n\n".utf8)],
            finishDelayNanoseconds: 300_000_000,
            contentType: "text/event-stream"
        )
        let client = SSEClient(baseURL: URL(string: "http://fixture.local")!, session: session())
        var iterator = client.events(path: "/events", token: "token").makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertFalse(URLProtocolFixture.didFinishLoading)
        let second = try await iterator.next()
        XCTAssertFalse(URLProtocolFixture.didFinishLoading)
        XCTAssertEqual(first, Data("first".utf8))
        XCTAssertEqual(second, Data("second".utf8))
        let end = try await iterator.next()
        XCTAssertNil(end)
    }

    func testSSEClientRejectsNon2xxStatus() async {
        URLProtocolFixture.response = .init(status: 503, body: Data("down".utf8), contentType: "text/event-stream")
        let client = SSEClient(baseURL: URL(string: "http://fixture.local")!, session: session())
        do { for try await _ in client.events(path: "/events", token: "token") {}; XCTFail("expected error") }
        catch { XCTAssertEqual(error as? NetworkError, .httpStatus(503, "")) }
    }

    func testSSEClientMapsUnauthorizedWithoutExposingToken() async {
        URLProtocolFixture.response = .init(
            status: 401,
            body: Data("invalid secret-token".utf8),
            contentType: "text/event-stream"
        )
        let client = SSEClient(baseURL: URL(string: "http://fixture.local")!, session: session())

        do {
            for try await _ in client.events(path: "/events", token: "secret-token") {}
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? NetworkError, .unauthorized)
            XCTAssertFalse(String(describing: error).contains("secret-token"))
        }
    }

    func testSSEClientRejectsInvalidPath() async {
        let client = SSEClient(baseURL: URL(string: "http://fixture.local")!, session: session())
        do { for try await _ in client.events(path: "events", token: "token") {}; XCTFail("expected error") }
        catch { XCTAssertEqual(error as? NetworkError, .invalidURL) }
    }
}

final class URLProtocolFixture: URLProtocol {
    struct Response {
        let status: Int
        let body: Data
        var chunks: [Data] = []
        var finishDelayNanoseconds: UInt64 = 0
        var contentType = "application/json"
    }
    nonisolated(unsafe) static var response = Response(status: 200, body: Data())
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var didFinishLoading = false
    static func reset() { response = Response(status: 200, body: Data()); lastRequest = nil; didFinishLoading = false }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let response = Self.response
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": response.contentType])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        let chunks = response.chunks.isEmpty ? [response.body] : response.chunks
        for chunk in chunks where !chunk.isEmpty { client?.urlProtocol(self, didLoad: chunk) }
        if response.finishDelayNanoseconds == 0 {
            Self.didFinishLoading = true
            client?.urlProtocolDidFinishLoading(self)
        } else {
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(response.finishDelayNanoseconds))) { [weak self] in
                guard let self else { return }
                Self.didFinishLoading = true
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
    }
    override func stopLoading() {}
}
