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
    private var gateRegistrationWaiters: [CheckedContinuation<Void, Never>] = []
    private var callCountWaiters: [(minimum: Int, continuation: CheckedContinuation<Void, Never>)] = []
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
        response(status: 200, json, contentType: contentType)
    }

    static func response(
        status: Int,
        _ json: String,
        contentType: String = "application/json"
    ) -> Result<(Data, HTTPURLResponse), Error> {
        .success((
            Data(json.utf8),
            HTTPURLResponse(
                url: URL(string: "https://router.local:8378")!,
                statusCode: status,
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
        if gateRequests {
            await withCheckedContinuation { gate in
                let (gateWaiters, callWaiters) = lock.withLock {
                    _calls.append(Call(method: method, path: path, body: body, token: token))
                    pendingGates.append(gate)
                    let gateWaiters = gateRegistrationWaiters
                    gateRegistrationWaiters = []
                    let callWaiters = removeSatisfiedCallCountWaiters()
                    return (gateWaiters, callWaiters)
                }
                gateWaiters.forEach { $0.resume() }
                callWaiters.forEach { $0.resume() }
            }
        } else {
            let callWaiters = lock.withLock {
                _calls.append(Call(method: method, path: path, body: body, token: token))
                return removeSatisfiedCallCountWaiters()
            }
            callWaiters.forEach { $0.resume() }
        }
        let next = lock.withLock { results.isEmpty ? nil : results.removeFirst() }
        guard let next else { throw NetworkError.decode("ScriptedRouterHTTPClient exhausted") }
        return try next.get()
    }

    func waitForGateRegistration() async {
        await withCheckedContinuation { continuation in
            let isAlreadyRegistered = lock.withLock {
                guard pendingGates.isEmpty else { return true }
                gateRegistrationWaiters.append(continuation)
                return false
            }
            if isAlreadyRegistered { continuation.resume() }
        }
    }

    func waitForCallCount(_ minimum: Int) async {
        await withCheckedContinuation { continuation in
            let isAlreadySatisfied = lock.withLock {
                guard _calls.count < minimum else { return true }
                callCountWaiters.append((minimum, continuation))
                return false
            }
            if isAlreadySatisfied { continuation.resume() }
        }
    }

    func releaseGates() {
        let gates = lock.withLock {
            let value = pendingGates
            pendingGates = []
            return value
        }
        gates.forEach { $0.resume() }
    }

    func releaseNextGate() {
        let gate = lock.withLock {
            pendingGates.isEmpty ? nil : pendingGates.removeFirst()
        }
        gate?.resume()
    }

    private func removeSatisfiedCallCountWaiters() -> [CheckedContinuation<Void, Never>] {
        let satisfied = callCountWaiters.filter { _calls.count >= $0.minimum }
        callCountWaiters.removeAll { _calls.count >= $0.minimum }
        return satisfied.map(\.continuation)
    }
}
