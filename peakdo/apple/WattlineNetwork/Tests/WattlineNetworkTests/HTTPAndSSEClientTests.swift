import Foundation
import XCTest
@testable import WattlineNetwork

final class HTTPAndSSEClientTests: XCTestCase {
    func testHTTPRecordsBearerAndDecodesJSON() async throws {
        let server = FakeRouterServer()
        server.setResponse(data: Data(#"{"ok":true}"#.utf8))
        let (data, response) = try await server.get("/health", token: "secret")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Bool])
        XCTAssertEqual(object["ok"], true)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(server.lastRequest?.authorization, "Bearer secret")
    }

    func testSSEDataFramesAndBlankLines() async throws {
        let server = FakeRouterServer()
        let stream = server.events(path: "/events", token: "token")
        let task = Task { () -> [Data] in
            var values: [Data] = []
            do { for try await value in stream { values.append(value) } } catch { XCTFail("unexpected error: \(error)") }
            return values
        }
        server.pushFrame("data: {\"n\":1}\n\ndata: second\n\ndata: third\n")
        server.close()
        let values = await task.value
        XCTAssertEqual(values, [Data(#"{"n":1}"#.utf8), Data("second".utf8), Data("third".utf8)])
    }

    func testSSEStreamClosureProducesNoExtraEvents() async {
        let server = FakeRouterServer()
        let stream = server.events(path: "/events", token: "token")
        let task = Task { () throws -> Int in var count = 0; for try await _ in stream { count += 1 }; return count }
        server.close()
        let count = try? await task.value
        XCTAssertEqual(count, 0)
    }

    func testMalformedSSEFrameRejectsStream() async {
        let server = FakeRouterServer()
        let stream = server.events(path: "/events", token: "token")
        let task = Task { () -> Error? in
            do { for try await _ in stream {} ; return nil } catch { return error }
        }
        server.pushFrame("event: unsupported\n\n")
        let error = await task.value
        XCTAssertEqual(error as? NetworkError, .decode("Malformed SSE frame"))
    }
}
