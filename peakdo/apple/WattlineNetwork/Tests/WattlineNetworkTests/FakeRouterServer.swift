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
    private var defaultResponse = Response(data: Data("{}".utf8), statusCode: 200)
    private var responsesByPath: [String: Response] = [:]
    private var eventContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var storedEventStreamCount = 0

    private struct Response {
        let data: Data
        let statusCode: Int
    }

    var requests: [Request] { lock.withLock { storedRequests } }
    var lastRequest: Request? { requests.last }
    var eventStreamCount: Int { lock.withLock { storedEventStreamCount } }

    func setResponse(data: Data, statusCode: Int = 200) {
        lock.withLock { defaultResponse = Response(data: data, statusCode: statusCode) }
    }

    func setResponse(data: Data, statusCode: Int = 200, for path: String) {
        lock.withLock {
            responsesByPath[path] = Response(data: data, statusCode: statusCode)
        }
    }

    func get(_ path: String, token: String) async throws -> (Data, HTTPURLResponse) {
        try await request("GET", path, body: nil, token: token)
    }

    func request(_ method: String, _ path: String, body: Data?, token: String) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { storedRequests.append(Request(method: method, path: path, body: body, authorization: "Bearer \(token)")) }
        let configured = lock.withLock { responsesByPath[path] ?? defaultResponse }
        let response = HTTPURLResponse(url: URL(string: "http://fake.local\(path)")!, statusCode: configured.statusCode, httpVersion: nil, headerFields: nil)!
        return (configured.data, response)
    }

    func events(path: String, token: String) -> AsyncThrowingStream<Data, Error> {
        let (configured, previous) = lock.withLock {
            storedRequests.append(Request(method: "GET", path: path, body: nil, authorization: "Bearer \(token)"))
            storedEventStreamCount += 1
            return (responsesByPath[path] ?? defaultResponse, eventContinuation)
        }
        return AsyncThrowingStream { continuation in
            previous?.finish()
            guard (200..<300).contains(configured.statusCode) else {
                continuation.finish(throwing: configured.statusCode == 401
                    ? NetworkError.unauthorized
                    : NetworkError.httpStatus(
                        configured.statusCode,
                        String(data: configured.data, encoding: .utf8) ?? ""
                    ))
                return
            }
            lock.withLock { eventContinuation = continuation }
        }
    }

    @discardableResult
    func pushPayload(_ data: Data) -> Bool {
        guard let continuation = lock.withLock({ eventContinuation }) else { return false }
        if case .terminated = continuation.yield(data) { return false }
        return true
    }

    @discardableResult
    func pushPayload(_ payload: String) -> Bool {
        pushPayload(Data(payload.utf8))
    }

    @discardableResult
    func close() -> Bool {
        guard let continuation = takeEventContinuation() else { return false }
        continuation.finish()
        return true
    }

    @discardableResult
    func fail(_ error: Error) -> Bool {
        guard let continuation = takeEventContinuation() else { return false }
        continuation.finish(throwing: error)
        return true
    }

    func waitForEventStreamCount(_ expectedCount: Int) async throws {
        for _ in 0..<20_000 {
            if eventStreamCount >= expectedCount { return }
            await Task.yield()
        }
        throw FakeRouterServerError.timedOutWaitingForEventStream(expectedCount)
    }

    private func takeEventContinuation() -> AsyncThrowingStream<Data, Error>.Continuation? {
        lock.withLock {
            defer { eventContinuation = nil }
            return eventContinuation
        }
    }
}

private enum FakeRouterServerError: Error {
    case timedOutWaitingForEventStream(Int)
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }; return body()
    }
}
