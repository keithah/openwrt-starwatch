import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol RouterEventStream: Sendable {
    func events(path: String, token: String) -> AsyncThrowingStream<Data, Error>
}

struct SSEFrameParser {
    private(set) var dataLines: [Data] = []

    mutating func consume(_ line: [UInt8]) throws -> Data? {
        if line.isEmpty {
            guard !dataLines.isEmpty else { return nil }
            defer { dataLines.removeAll(keepingCapacity: true) }
            var payload = Data()
            for (index, dataLine) in dataLines.enumerated() {
                if index > 0 { payload.append(0x0A) }
                payload.append(dataLine)
            }
            return payload
        }

        if line.first == 0x3A { return nil }
        let colon = line.firstIndex(of: 0x3A)
        let field = line[..<(colon ?? line.endIndex)]
        guard field.elementsEqual("data".utf8) else {
            // Field names and ignored values may contain malformed UTF-8;
            // they are intentionally never decoded.
            return nil
        }

        guard let colon else {
            dataLines.append(Data())
            return nil
        }

        var valueStart = line.index(after: colon)
        if valueStart < line.endIndex, line[valueStart] == 0x20 {
            valueStart = line.index(after: valueStart)
        }
        dataLines.append(Data(line[valueStart...]))
        return nil
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
                    if http.statusCode == 401 { throw NetworkError.unauthorized }
                    guard (200..<300).contains(http.statusCode) else { throw NetworkError.httpStatus(http.statusCode, "") }
                    var parser = SSEFrameParser()
                    var line: [UInt8] = []
                    for try await byte in bytes {
                        if byte == 0x0A {
                            if line.last == 0x0D { line.removeLast() }
                            if let data = try parser.consume(line) { continuation.yield(data) }
                            line.removeAll(keepingCapacity: true)
                        } else {
                            line.append(byte)
                        }
                    }
                    // EOF does not terminate an SSE event. Any remaining line
                    // or accumulated data belongs to a truncated payload and
                    // is deliberately discarded.
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
