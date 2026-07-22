import Foundation

public enum RouterRouteKind: Equatable, Sendable {
    case local
    case remote
}

enum RouterRouteFallbackPolicy {
    private static let reachabilityCodes: Set<URLError.Code> = [
        .notConnectedToInternet,
        .cannotFindHost,
        .cannotConnectToHost,
        .networkConnectionLost,
        .timedOut,
        .dnsLookupFailed,
    ]

    static func permitsRemoteFallback(_ error: Error) -> Bool {
        guard !Task.isCancelled, !(error is CancellationError) else {
            return false
        }
        if let urlError = error as? URLError {
            return reachabilityCodes.contains(urlError.code)
        }
        if case NetworkError.transport = error {
            return true
        }
        return false
    }
}

public actor PreferredRouterRoute {
    public private(set) var selected: RouterRouteKind = .local
    private var selectionGeneration: UInt64 = 0

    private let lanHTTP: any RouterHTTPClient
    private let lanEvents: any RouterEventStream
    private let remoteHTTP: any RouterHTTPClient
    private let remoteEvents: any RouterEventStream

    public init(
        lanHTTP: any RouterHTTPClient,
        lanEvents: any RouterEventStream,
        remoteHTTP: any RouterHTTPClient,
        remoteEvents: any RouterEventStream
    ) {
        self.lanHTTP = lanHTTP
        self.lanEvents = lanEvents
        self.remoteHTTP = remoteHTTP
        self.remoteEvents = remoteEvents
    }

    func request(
        _ method: String,
        _ path: String,
        body: Data?,
        token: String
    ) async throws -> (Data, HTTPURLResponse) {
        if selected == .remote {
            return try await remoteHTTP.request(method, path, body: body, token: token)
        }
        let requestGeneration = selectionGeneration

        do {
            let result = try await lanHTTP.request(method, path, body: body, token: token)
            if selectionGeneration == requestGeneration {
                selected = .local
            }
            return result
        } catch {
            guard RouterRouteFallbackPolicy.permitsRemoteFallback(error) else {
                throw error
            }
            if selectionGeneration == requestGeneration {
                select(.remote)
            }
            return try await remoteHTTP.request(method, path, body: body, token: token)
        }
    }

    func localEvents(path: String, token: String) -> AsyncThrowingStream<Data, Error> {
        lanEvents.events(path: path, token: token)
    }

    func remoteEvents(path: String, token: String) -> AsyncThrowingStream<Data, Error> {
        remoteEvents.events(path: path, token: token)
    }

    func select(_ route: RouterRouteKind) {
        selectionGeneration &+= 1
        selected = route
    }
}

public final class PreferredRouterHTTPClient: RouterHTTPClient, @unchecked Sendable {
    private let route: PreferredRouterRoute

    public init(route: PreferredRouterRoute) {
        self.route = route
    }

    public func get(_ path: String, token: String) async throws -> (Data, HTTPURLResponse) {
        try await request("GET", path, body: nil, token: token)
    }

    public func request(
        _ method: String,
        _ path: String,
        body: Data?,
        token: String
    ) async throws -> (Data, HTTPURLResponse) {
        try await route.request(method, path, body: body, token: token)
    }
}

public final class PreferredRouterEventStream: RouterEventStream, @unchecked Sendable {
    private let route: PreferredRouterRoute

    public init(route: PreferredRouterRoute) {
        self.route = route
    }

    public func events(path: String, token: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let local = await self.route.localEvents(path: path, token: token)
                    var receivedLocalEvent = false
                    do {
                        for try await event in local {
                            try Task.checkCancellation()
                            if !receivedLocalEvent {
                                receivedLocalEvent = true
                                await self.route.select(.local)
                            }
                            continuation.yield(event)
                        }
                        if !receivedLocalEvent {
                            await self.route.select(.local)
                        }
                        continuation.finish()
                        return
                    } catch {
                        guard !receivedLocalEvent,
                              RouterRouteFallbackPolicy.permitsRemoteFallback(error)
                        else {
                            throw error
                        }
                    }

                    try Task.checkCancellation()
                    await self.route.select(.remote)
                    let remote = await self.route.remoteEvents(path: path, token: token)
                    for try await event in remote {
                        try Task.checkCancellation()
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
