import XCTest
@testable import WattlineCore

final class SerializedTransactionsTests: XCTestCase {
    func testCallerCancellationPropagatesIntoOperation() async throws {
        let transactions = SerializedTransactions()
        let probe = SerializationProbe()
        let task = Task {
            try await transactions.enqueue {
                await probe.record(.firstStarted)
                do {
                    try await Task.sleep(for: .seconds(5))
                    return 1
                } catch is CancellationError {
                    await probe.record(.firstCancelled)
                    throw CancellationError()
                }
            }
        }
        await probe.waitUntilContains(.firstStarted)

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled caller must not receive a successful operation result")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, received \(error)")
        }
        let events = await probe.events
        XCTAssertTrue(events.contains(.firstCancelled))
    }

    func testCancelledPredecessorDoesNotBreakSuccessorSerializationOrder() async throws {
        let transactions = SerializedTransactions()
        let probe = SerializationProbe()
        let first = Task {
            try await transactions.enqueue {
                await probe.record(.firstStarted)
                do {
                    try await Task.sleep(for: .seconds(5))
                    return 1
                } catch is CancellationError {
                    await probe.record(.firstCancelled)
                    throw CancellationError()
                }
            }
        }
        await probe.waitUntilContains(.firstStarted)
        let second = Task {
            try await transactions.enqueue {
                await probe.record(.second)
                return 2
            }
        }
        first.cancel()

        do {
            _ = try await first.value
            XCTFail("expected cancelled predecessor")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, received \(error)")
        }
        await probe.waitUntilContains(.second)
        let third = Task {
            try await transactions.enqueue {
                await probe.record(.third)
                return 3
            }
        }
        let secondValue = try await second.value
        let thirdValue = try await third.value
        XCTAssertEqual(secondValue, 2)
        XCTAssertEqual(thirdValue, 3)
        let events = await probe.events
        XCTAssertEqual(events, [.firstStarted, .firstCancelled, .second, .third])
    }
}

private actor SerializationProbe {
    enum Event: Equatable { case firstStarted, firstCancelled, second, third }
    private(set) var events: [Event] = []
    func record(_ event: Event) { events.append(event) }
    func waitUntilContains(_ event: Event) async {
        while !events.contains(event) { await Task.yield() }
    }
}
