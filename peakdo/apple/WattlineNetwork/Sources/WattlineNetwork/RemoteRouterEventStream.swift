import Foundation
import GoodCloudKit

public final class RemoteRouterEventStream: RouterEventStream, @unchecked Sendable {
    private let coordinator: any RemoteRelayCoordinating

    public init(coordinator: any RemoteRelayCoordinating) {
        self.coordinator = coordinator
    }

    public func events(path: String, token: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            guard path.hasPrefix("/") else {
                continuation.finish(throwing: NetworkError.invalidURL)
                return
            }

            let task = Task {
                do {
                    let relayStream = await self.coordinator.stream(
                        method: "GET",
                        path: path,
                        headers: [
                            "Authorization": "Bearer \(token)",
                            "Accept": "text/event-stream",
                        ],
                        body: nil
                    )
                    var receivedResponse = false
                    var parser = SSEFrameParser()
                    var line: [UInt8] = []

                    for try await event in relayStream {
                        try Task.checkCancellation()
                        switch event {
                        case .attemptStarted:
                            receivedResponse = false
                            parser = SSEFrameParser()
                            line.removeAll(keepingCapacity: true)
                        case .response(let response):
                            guard !receivedResponse else {
                                throw NetworkError.decode("Remote event stream returned multiple responses")
                            }
                            receivedResponse = true
                            guard (200..<300).contains(response.statusCode) else {
                                throw RouterHTTPErrorMapper.error(
                                    status: response.statusCode,
                                    data: Data(),
                                    token: token
                                )
                            }
                        case .data(let data):
                            guard receivedResponse else {
                                throw NetworkError.decode("Remote event stream returned data before its response")
                            }
                            for byte in data {
                                if byte == 0x0A {
                                    if line.last == 0x0D {
                                        line.removeLast()
                                    }
                                    if let payload = try parser.consume(line) {
                                        continuation.yield(payload)
                                    }
                                    line.removeAll(keepingCapacity: true)
                                } else {
                                    line.append(byte)
                                }
                            }
                        }
                    }

                    guard receivedResponse else {
                        throw NetworkError.decode("Remote event stream ended before its response")
                    }
                    // As with the LAN SSE transport, EOF never completes an
                    // unterminated event. Any partial line/frame is discarded.
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
