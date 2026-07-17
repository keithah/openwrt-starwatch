import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol RouterEventStream: Sendable {
    func events(path: String, token: String) -> AsyncThrowingStream<Data, Error>
}

struct SSEFrameParser {
    private(set) var dataLines: [String] = []
    mutating func consume(_ line: String) throws -> Data? {
        if line.isEmpty {
            guard !dataLines.isEmpty else { return nil }
            defer { dataLines.removeAll(keepingCapacity: true) }
            return Data(dataLines.joined(separator: "\n").utf8)
        }
        if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5))
            if value.first == " " { value.removeFirst() }
            dataLines.append(value)
            return nil
        }
        if line.hasPrefix(":") { return nil }
        throw NetworkError.decode("Malformed SSE frame")
    }
    mutating func finish() -> Data? {
        guard !dataLines.isEmpty else { return nil }
        defer { dataLines.removeAll(keepingCapacity: true) }
        return Data(dataLines.joined(separator: "\n").utf8)
    }
}

public final class SSEClient: RouterEventStream, @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func events(path: String, token: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            guard path.hasPrefix("/"), let url = URL(string: path, relativeTo: self.baseURL)?.absoluteURL else {
                continuation.finish(throwing: NetworkError.invalidURL)
                return
            }
            let task = Task {
                do {
                    var request = URLRequest(url: url)
                    request.httpMethod = "GET"
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await self.session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw NetworkError.decode("Non-HTTP response") }
                    guard (200..<300).contains(http.statusCode) else { throw NetworkError.httpStatus(http.statusCode, "") }
                    var parser = SSEFrameParser()
                    var line = ""
                    for try await byte in bytes {
                        if byte == 0x0A {
                            if line.last == "\r" { line.removeLast() }
                            if let data = try parser.consume(line) { continuation.yield(data) }
                            line.removeAll(keepingCapacity: true)
                        } else {
                            line.append(Character(UnicodeScalar(byte)))
                        }
                    }
                    if !line.isEmpty {
                        if line.last == "\r" { line.removeLast() }
                        if let data = try parser.consume(line) { continuation.yield(data) }
                    }
                    if let data = parser.finish() { continuation.yield(data) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public typealias URLSessionEventStream = SSEClient
