import Foundation
import XCTest
@testable import WattlineCore

@MainActor
final class ReplayTransportTests: XCTestCase {
    func testTransactionsNeverOverlap() async throws {
        let clock = TestDeviceClock()
        let reply = Data([Command.dcControl.rawValue, Action.set.rawValue | 0x80, 0])
        let replay = ReplayTransport(
            steps: [.reply(after: .seconds(1), bytes: reply), .reply(bytes: reply)],
            clock: clock
        )

        async let first = replay.perform(.setDC(true))
        async let second = replay.perform(.setDC(true))
        await clock.waitForSleepers(1)

        let inFlightCount = await replay.inFlightCount
        XCTAssertEqual(inFlightCount, 1)
        await clock.advance(by: .seconds(1))
        _ = try await (first, second)
        let maximumInFlightCount = await replay.maximumInFlightCount
        XCTAssertEqual(maximumInFlightCount, 1)
    }

    func testReplyIsValidatedAndReturned() async throws {
        let replay = ReplayTransport(steps: [
            .reply(bytes: Data([Command.typeCPowerLimit.rawValue, Action.get.rawValue | 0x80, 0, 3]))
        ])

        let outcome = try await replay.perform(.getPowerLimit(.global))

        guard case let .reply(reply) = outcome else {
            return XCTFail("Expected a reply outcome")
        }
        XCTAssertEqual(reply.result, 0)
        XCTAssertEqual(reply.payload, Data([3]))
    }

    func testExpectedDisconnectPoliciesCompleteSuccessfully() async throws {
        let restart = ReplayTransport(steps: [.disconnect(error: ReplayTestError.linkLost)])
        let ota = ReplayTransport(steps: [.disconnect(error: ReplayTestError.linkLost)])
        let shutdown = ReplayTransport(steps: [.disconnect(error: ReplayTestError.linkLost)])

        let restartOutcome = try await restart.perform(.restart)
        let restartPolicy = await restart.reconnectPolicy
        let otaOutcome = try await ota.perform(.enterOTA)
        let otaPolicy = await ota.reconnectPolicy
        let shutdownOutcome = try await shutdown.perform(.shutdown)
        let shutdownPolicy = await shutdown.reconnectPolicy
        XCTAssertEqual(restartOutcome, .sent)
        XCTAssertEqual(restartPolicy, .armed)
        XCTAssertEqual(otaOutcome, .sent)
        XCTAssertEqual(otaPolicy, .awaitingOTAMode)
        XCTAssertEqual(shutdownOutcome, .sent)
        XCTAssertEqual(shutdownPolicy, .disarmed)
    }

    func testUnexpectedDisconnectFailsCommand() async {
        let replay = ReplayTransport(steps: [.disconnect(error: ReplayTestError.linkLost)])

        do {
            _ = try await replay.perform(.setDC(true))
            XCTFail("Expected disconnect to fail a normal command")
        } catch let error as ReplayTransportError {
            XCTAssertEqual(error, .disconnected("linkLost"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTelemetryStepEmitsEventBeforeReply() async throws {
        let status = try DCPortStatus(frame: Data([1, 0, 0, 0, 0, 0, 0, 0]))
        let replay = ReplayTransport(steps: [
            .telemetry(.dc(status, timestamp: .zero)),
            .reply(bytes: Data([Command.dcControl.rawValue, Action.set.rawValue | 0x80, 0])),
        ])
        var iterator = replay.events.makeAsyncIterator()

        _ = try await replay.perform(.setDC(true))

        _ = await iterator.next()
        let telemetryEvent = await iterator.next()
        XCTAssertEqual(telemetryEvent, .dc(status, timestamp: .zero))
    }

    func testWriteFailureIsSurfaced() async {
        let replay = ReplayTransport(steps: [.writeFailure(ReplayTestError.writeFailed)])

        do {
            _ = try await replay.perform(.setDC(true))
            XCTFail("Expected write failure")
        } catch let error as ReplayTransportError {
            XCTAssertEqual(error, .writeFailed("writeFailed"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTransactionDepthIncludesQueuedRefreshAndCommandWithoutIntermediateZero() async throws {
        let clock = TestDeviceClock()
        let reply = Data([Command.dcControl.rawValue, Action.set.rawValue | 0x80, 0])
        let replay = ReplayTransport(steps: [.delay(.seconds(1)), .reply(bytes: reply)], clock: clock)
        var iterator = replay.events.makeAsyncIterator()

        let refresh = Task { try await replay.refreshTelemetry() }
        await clock.waitForSleepers(1)
        let command = Task { try await replay.perform(.setDC(true)) }
        while await replay.pendingTransactionCount < 2 { await Task.yield() }

        await clock.advance(by: .seconds(1))
        try await refresh.value
        _ = try await command.value

        var depths: [Int] = []
        while depths.count < 4, let event = await iterator.next() {
            if case let .transactionDepth(depth) = event { depths.append(depth) }
        }
        XCTAssertEqual(depths, [1, 2, 1, 0])
        let maximumPending = await replay.maximumPendingTransactionCount
        let finalPending = await replay.pendingTransactionCount
        let maximumInFlight = await replay.maximumInFlightCount
        XCTAssertEqual(maximumPending, 2)
        XCTAssertEqual(finalPending, 0)
        XCTAssertEqual(maximumInFlight, 1)
    }

    func testManualTimeOperationsConsumeExplicitReplaySteps() async throws {
        let date = Date(timeIntervalSince1970: 1_720_951_445.5)
        let replay = ReplayTransport(steps: [
            .timeSync,
            .deviceTime(date),
            .deviceTime(nil),
        ])

        try await replay.synchronizeDeviceTime()
        let supportedTime = try await replay.readDeviceTimeIfSupported()
        let unsupportedTime = try await replay.readDeviceTimeIfSupported()

        XCTAssertEqual(supportedTime, date)
        XCTAssertNil(unsupportedTime)
    }

    func testManualTimeOperationFailsWhenReplayStepIsOutOfOrder() async {
        let replay = ReplayTransport(steps: [.deviceTime(Date(timeIntervalSince1970: 0))])

        do {
            try await replay.synchronizeDeviceTime()
            XCTFail("Expected out-of-order replay step to throw")
        } catch {
            XCTAssertEqual(error as? ReplayTransportError, .unexpectedStep)
        }
    }

    func testManualTimeOperationsShareSerializedTransactionQueue() async throws {
        let clock = TestDeviceClock()
        let date = Date(timeIntervalSince1970: 1_720_951_445.5)
        let replay = ReplayTransport(
            steps: [.delay(.seconds(1)), .timeSync, .deviceTime(date)],
            clock: clock
        )

        let sync = Task { try await replay.synchronizeDeviceTime() }
        await clock.waitForSleepers(1)
        let read = Task { try await replay.readDeviceTimeIfSupported() }
        while await replay.pendingTransactionCount < 2 { await Task.yield() }

        await clock.advance(by: .seconds(1))
        try await sync.value
        let readTime = try await read.value
        let maximumInFlightCount = await replay.maximumInFlightCount
        let pendingTransactionCount = await replay.pendingTransactionCount

        XCTAssertEqual(readTime, date)
        XCTAssertEqual(maximumInFlightCount, 1)
        XCTAssertEqual(pendingTransactionCount, 0)
    }
}

private enum ReplayTestError: Error, Sendable {
    case linkLost
    case writeFailed
}
