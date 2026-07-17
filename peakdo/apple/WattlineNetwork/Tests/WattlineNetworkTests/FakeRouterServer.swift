import Foundation
@testable import WattlineNetwork

final class FakeRouterServer: RouterHTTPClient, RouterEventStream, @unchecked Sendable {
    struct Request: Equatable, Sendable {
        let method: String
        let path: String
        let body: Data?
        let authorization: String?
    }

    private let lock = NSLock()
    private var storedRequests: [Request] = []
    private var responseData = Data("{}".utf8)
    private var responseStatus = 200
    private var eventContinuation: AsyncThrowingStream<Data, Error>.Continuation?

    var requests: [Request] { lock.withLock { storedRequests } }
    var lastRequest: Request? { requests.last }

    func setResponse(data: Data, statusCode: Int = 200) {
        lock.withLock { responseData = data; responseStatus = statusCode }
    }

    func get(_ path: String, token: String) async throws -> (Data, HTTPURLResponse) {
        try await request("GET", path, body: nil, token: token)
    }

    func request(_ method: String, _ path: String, body: Data?, token: String) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { storedRequests.append(Request(method: method, path: path, body: body, authorization: "Bearer \(token)")) }
        let (data, status) = lock.withLock { (responseData, responseStatus) }
        let response = HTTPURLResponse(url: URL(string: "http://fake.local\(path)")!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }

    func events(path: String, token: String) -> AsyncThrowingStream<Data, Error> {
        lock.withLock { storedRequests.append(Request(method: "GET", path: path, body: nil, authorization: "Bearer \(token)")) }
        return AsyncThrowingStream { continuation in
            lock.withLock { eventContinuation = continuation }
        }
    }

    func push(_ data: Data) { lock.withLock { eventContinuation?.yield(data) } }
    func pushFrame(_ frame: String) {
        var parser = SSEFrameParser()
        do {
            for line in frame.split(separator: "\n", omittingEmptySubsequences: false) {
                if let data = try parser.consume(String(line)) { push(data) }
            }
            if let data = parser.finish() { push(data) }
        } catch { fail(error) }
    }
    func close() { lock.withLock { eventContinuation?.finish(); eventContinuation = nil } }
    func fail(_ error: Error) { lock.withLock { eventContinuation?.finish(throwing: error); eventContinuation = nil } }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }; return body()
    }
}
