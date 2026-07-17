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

    func testHTTPClientRejectsInvalidURL() async {
        let client = HTTPClient(baseURL: URL(string: "http://fixture.local")!, session: session())
        do { _ = try await client.get("://bad", token: "secret"); XCTFail("expected error") }
        catch { XCTAssertEqual(error as? NetworkError, .invalidURL) }
    }

    func testSSEClientParsesRawDataFramesAndBlankLines() async throws {
        let wire = "data: {\"n\":1}\n\ndata: second\n\ndata: third\n"
        URLProtocolFixture.response = .init(status: 200, body: Data(wire.utf8), contentType: "text/event-stream")
        let client = SSEClient(baseURL: URL(string: "http://fixture.local")!, session: session())
        var values: [Data] = []
        for try await value in client.events(path: "/events", token: "token") { values.append(value) }
        XCTAssertEqual(values, [Data(#"{"n":1}"#.utf8), Data("second".utf8), Data("third".utf8)])
        XCTAssertEqual(URLProtocolFixture.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer token")
    }

    func testSSEClientRejectsMalformedRawFrame() async {
        URLProtocolFixture.response = .init(status: 200, body: Data("event: unsupported\n\n".utf8), contentType: "text/event-stream")
        let client = SSEClient(baseURL: URL(string: "http://fixture.local")!, session: session())
        do { for try await _ in client.events(path: "/events", token: "token") {}; XCTFail("expected error") }
        catch { XCTAssertEqual(error as? NetworkError, .decode("Malformed SSE frame")) }
    }

    func testSSEClientClosesWithoutExtraEvents() async throws {
        URLProtocolFixture.response = .init(status: 200, body: Data(), contentType: "text/event-stream")
        let client = SSEClient(baseURL: URL(string: "http://fixture.local")!, session: session())
        var count = 0
        for try await _ in client.events(path: "/events", token: "token") { count += 1 }
        XCTAssertEqual(count, 0)
    }
}

final class URLProtocolFixture: URLProtocol {
    struct Response { let status: Int; let body: Data; var contentType = "application/json" }
    nonisolated(unsafe) static var response = Response(status: 200, body: Data())
    nonisolated(unsafe) static var lastRequest: URLRequest?
    static func reset() { response = Response(status: 200, body: Data()); lastRequest = nil }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let response = Self.response
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": response.contentType])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
