import Foundation
import WattlineNetwork
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Deterministic RouterHTTPClient double. Mirrors production HTTPClient behavior:
/// scripted errors are thrown pre-mapped (HTTPClient maps non-2xx via
/// RouterHTTPErrorMapper before returning), successes return (Data, 200-response).
final class ScriptedRouterHTTPClient: RouterHTTPClient, @unchecked Sendable {
    struct Call: Equatable {
        let method: String
        let path: String
        let body: Data?
        let token: String
    }

    private let lock = NSLock()
    private var results: [Result<(Data, HTTPURLResponse), Error>]
    private var pendingGates: [CheckedContinuation<Void, Never>] = []
    private var _calls: [Call] = []
    private let gateRequests: Bool

    init(
        results: [Result<(Data, HTTPURLResponse), Error>],
        gateRequests: Bool = false
    ) {
        self.results = results
        self.gateRequests = gateRequests
    }

    var calls: [Call] { lock.withLock { _calls } }

    static func ok(
        _ json: String,
        contentType: String = "application/json"
    ) -> Result<(Data, HTTPURLResponse), Error> {
        .success((
            Data(json.utf8),
            HTTPURLResponse(
                url: URL(string: "https://router.local:8378")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": contentType]
            )!
        ))
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
        lock.withLock {
            _calls.append(Call(method: method, path: path, body: body, token: token))
        }
        if gateRequests {
            await withCheckedContinuation { continuation in
                lock.withLock { pendingGates.append(continuation) }
            }
        }
        let next = lock.withLock { results.isEmpty ? nil : results.removeFirst() }
        guard let next else { throw NetworkError.decode("ScriptedRouterHTTPClient exhausted") }
        return try next.get()
    }

    func releaseGates() {
        let gates = lock.withLock {
            let value = pendingGates
            pendingGates = []
            return value
        }
        gates.forEach { $0.resume() }
    }
}
