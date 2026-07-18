import Foundation
@testable import Wattline
import WattlineCore
import XCTest

final class DeviceOperationBrokerTests: XCTestCase {
    func testBrokerUsesAttachedSessionAndRejectsStaleGeneration() async throws {
        let reply = Data([Command.dcControl.rawValue, Action.set.rawValue | 0x80, 0])
        let clock = BrokerTestClock()
        let replay = ReplayTransport(steps: [
            .reply(after: .seconds(1), bytes: reply),
            .reply(bytes: reply),
        ], clock: clock)
        let session = DeviceSession(transport: replay)
        let broker = DeviceOperationBroker()
        let peripheralID = UUID()
        await broker.attach(.init(
            generation: 4,
            peripheralID: peripheralID,
            transport: replay,
            session: session
        ))

        let first = Task { try await broker.perform(.setDC(true), generation: 4) }
        try await eventually { await replay.inFlightCount == 1 }
        try await eventually { await clock.sleeperCount == 1 }
        let second = Task { try await broker.perform(.setDC(false), generation: 4) }

        await clock.advance(by: .seconds(1))
        _ = try await (first.value, second.value)
        await assertThrows(.superseded) {
            try await broker.perform(.setDC(false), generation: 3)
        }

        let maximumInFlightCount = await replay.maximumInFlightCount
        XCTAssertEqual(maximumInFlightCount, 1)
    }

    func testConnectedContextIsReusedWithoutReconnect() async throws {
        let harness = await makeHarness(generation: 3)
        await harness.broker.markConnected(peripheralID: harness.peripheralID, generation: 3)

        let generation = try await harness.broker.withConnection(to: harness.peripheralID) {
            $0.generation
        }

        XCTAssertEqual(generation, 3)
        let requests = await harness.reconnect.requests
        XCTAssertEqual(requests, [])
    }

    func testAttachingDifferentPeripheralInSameGenerationRequiresReconnect() async throws {
        let harness = await makeHarness(generation: 3)
        await harness.broker.markConnected(peripheralID: harness.peripheralID, generation: 3)
        let nextPeripheralID = UUID()
        let transport = ReplayTransport()
        await harness.broker.attach(.init(
            generation: 3,
            peripheralID: nextPeripheralID,
            transport: transport,
            session: DeviceSession(transport: transport)
        ))

        let result = Task {
            try await harness.broker.withConnection(to: nextPeripheralID) { _ in true }
        }
        try await eventually { await harness.reconnect.requests.count == 1 }

        let requests = await harness.reconnect.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.peripheralID, nextPeripheralID)
        XCTAssertEqual(requests.first?.generation, 3)
        result.cancel()
        await assertCancellation { try await result.value }
    }

    func testSameGenerationPeripheralReplacementSupersedesOldWaiterExactlyOnce() async {
        let harness = await makeHarness(generation: 3)
        let oldOperationCount = OperationCounter()
        let old = Task {
            try await harness.broker.withConnection(to: harness.peripheralID) { _ in
                await oldOperationCount.increment()
                return true
            }
        }
        await harness.reconnect.waitForRequestCount(1)

        let nextPeripheralID = UUID()
        let nextTransport = ReplayTransport()
        await harness.broker.attach(.init(
            generation: 3,
            peripheralID: nextPeripheralID,
            transport: nextTransport,
            session: DeviceSession(transport: nextTransport)
        ))
        let next = Task {
            try await harness.broker.withConnection(to: nextPeripheralID) { context in
                context.peripheralID
            }
        }
        await harness.reconnect.waitForRequestCount(2)
        let attempts = await harness.reconnect.requests

        await harness.broker.handleConnectionEvent(.connected, attempt: attempts[1])

        await assertThrows(.superseded) { try await old.value }
        let oldInvocationCount = await oldOperationCount.value
        let nextResult = try? await next.value
        let pendingConnectionCount = await harness.broker.pendingConnectionCount
        XCTAssertEqual(oldInvocationCount, 0)
        XCTAssertEqual(nextResult, nextPeripheralID)
        XCTAssertEqual(pendingConnectionCount, 0)
    }

    func testStaleSameGenerationTerminalCannotResolveReplacementWaiter() async throws {
        let harness = await makeHarness(generation: 3)
        let old = Task {
            try await harness.broker.withConnection(to: harness.peripheralID) { _ in true }
        }
        await harness.reconnect.waitForRequestCount(1)
        let oldAttempt = await harness.reconnect.requests[0]

        let nextPeripheralID = UUID()
        let nextTransport = ReplayTransport()
        await harness.broker.attach(.init(
            generation: 3,
            peripheralID: nextPeripheralID,
            transport: nextTransport,
            session: DeviceSession(transport: nextTransport)
        ))
        let next = Task {
            try await harness.broker.withConnection(to: nextPeripheralID) { $0.peripheralID }
        }
        await harness.reconnect.waitForRequestCount(2)
        let nextAttempt = await harness.reconnect.requests[1]

        await harness.broker.handleConnectionEvent(.terminal, attempt: oldAttempt)
        let pendingAfterStaleEvent = await harness.broker.pendingConnectionCount
        XCTAssertEqual(pendingAfterStaleEvent, 1)
        await harness.broker.handleConnectionEvent(.connected, attempt: nextAttempt)

        await assertThrows(.superseded) { try await old.value }
        let nextResult = try await next.value
        XCTAssertEqual(nextResult, nextPeripheralID)
    }

    func testSamePeripheralLifecycleReplacementSupersedesOldWaiter() async {
        let harness = await makeHarness(generation: 3)
        let result = Task {
            try await harness.broker.withConnection(to: harness.peripheralID) { _ in true }
        }
        await harness.reconnect.waitForRequestCount(1)

        let replacementTransport = ReplayTransport()
        await harness.broker.attach(.init(
            generation: 3,
            peripheralID: harness.peripheralID,
            transport: replacementTransport,
            session: DeviceSession(transport: replacementTransport)
        ))

        await assertThrows(.superseded) { try await result.value }
        let attempt = await harness.reconnect.requests[0]
        await harness.broker.handleConnectionEvent(.connected, attempt: attempt)
        let pendingConnectionCount = await harness.broker.pendingConnectionCount
        XCTAssertEqual(pendingConnectionCount, 0)
    }

    func testConnectionAttemptUsesCollisionFreeIdentity() async {
        let harness = await makeHarness(generation: 3)
        let first = Task {
            try await harness.broker.withConnection(to: harness.peripheralID) { _ in true }
        }
        await harness.reconnect.waitForRequestCount(1)
        let second = Task {
            try await harness.broker.withConnection(to: harness.peripheralID) { _ in true }
        }
        await harness.reconnect.waitForRequestCount(2)

        let attempts = await harness.reconnect.requests
        XCTAssertNotEqual(attempts[0].token, attempts[1].token)
        let _: UUID = attempts[0].token

        second.cancel()
        await assertCancellation { try await second.value }
        await assertThrows(.superseded) { try await first.value }
    }

    func testClockOperationsUseTheAttachedTransport() async throws {
        let expectedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let replay = ReplayTransport(steps: [.timeSync, .deviceTime(expectedDate)])
        let broker = DeviceOperationBroker()
        await broker.attach(.init(
            generation: 4,
            peripheralID: UUID(),
            transport: replay,
            session: DeviceSession(transport: replay)
        ))

        try await broker.syncClock(generation: 4)
        let date = try await broker.readClock(generation: 4)

        XCTAssertEqual(date, expectedDate)
        let maximumInFlightCount = await replay.maximumInFlightCount
        XCTAssertEqual(maximumInFlightCount, 1)
    }

    func testConnectionAtNinePointNineSecondsBeatsTimeout() async throws {
        let harness = await makeHarness(generation: 8)
        let result = Task {
            try await harness.broker.withConnection(to: harness.peripheralID) { $0.generation }
        }
        await harness.reconnect.waitForRequestCount(1)
        await harness.clock.waitForSleepers(1)

        await harness.clock.advance(by: .milliseconds(9_900))
        let attempt = await harness.reconnect.requests[0]
        await harness.broker.handleConnectionEvent(.connected, attempt: attempt)

        let generation = try await result.value
        let pendingConnectionCount = await harness.broker.pendingConnectionCount
        XCTAssertEqual(generation, 8)
        XCTAssertEqual(pendingConnectionCount, 0)
    }

    func testConnectionTimesOutAtTenSecondsWithoutSleepingInRealTime() async {
        let harness = await makeHarness(generation: 8)
        let result = Task {
            try await harness.broker.withConnection(to: harness.peripheralID) { _ in true }
        }
        await harness.reconnect.waitForRequestCount(1)
        await harness.clock.waitForSleepers(1)

        await harness.clock.advance(by: .seconds(10))

        await assertThrows(.timedOut) { try await result.value }
        let pendingConnectionCount = await harness.broker.pendingConnectionCount
        XCTAssertEqual(pendingConnectionCount, 0)
    }

    func testCancellationRemovesAndResumesWaiterExactlyOnce() async {
        let harness = await makeHarness(generation: 8)
        let result = Task {
            try await harness.broker.withConnection(to: harness.peripheralID) { _ in true }
        }
        await harness.reconnect.waitForRequestCount(1)

        result.cancel()
        await assertCancellation { try await result.value }
        let attempt = await harness.reconnect.requests[0]
        await harness.broker.handleConnectionEvent(.connected, attempt: attempt)

        let pendingConnectionCount = await harness.broker.pendingConnectionCount
        XCTAssertEqual(pendingConnectionCount, 0)
    }

    func testDetachRemovesAndResumesMatchingWaiterExactlyOnce() async {
        let harness = await makeHarness(generation: 8)
        let result = Task {
            try await harness.broker.withConnection(to: harness.peripheralID) { _ in true }
        }
        await harness.reconnect.waitForRequestCount(1)

        await harness.broker.detach(generation: 8)
        await assertThrows(.unavailable) { try await result.value }
        let attempt = await harness.reconnect.requests[0]
        await harness.broker.handleConnectionEvent(.terminal, attempt: attempt)

        let pendingConnectionCount = await harness.broker.pendingConnectionCount
        XCTAssertEqual(pendingConnectionCount, 0)
    }

    func testTerminalFailureRemovesWaiterAndLateSuccessCannotResumeItAgain() async {
        let harness = await makeHarness(generation: 8)
        let result = Task {
            try await harness.broker.withConnection(to: harness.peripheralID) { _ in true }
        }
        await harness.reconnect.waitForRequestCount(1)

        let attempt = await harness.reconnect.requests[0]
        await harness.broker.handleConnectionEvent(.terminal, attempt: attempt)
        await assertThrows(.unavailable) { try await result.value }
        await harness.broker.handleConnectionEvent(.connected, attempt: attempt)

        let pendingConnectionCount = await harness.broker.pendingConnectionCount
        XCTAssertEqual(pendingConnectionCount, 0)
    }

    func testStaleGenerationCallbackIsQuarantinedFromCurrentWaiter() async throws {
        let harness = await makeHarness(generation: 9)
        let result = Task {
            try await harness.broker.withConnection(to: harness.peripheralID) { $0.generation }
        }
        await harness.reconnect.waitForRequestCount(1)

        let staleAttempt = DeviceOperationBroker.ConnectionAttempt(
            generation: 8,
            peripheralID: harness.peripheralID,
            lifecycleID: UUID(),
            token: UUID()
        )
        await harness.broker.handleConnectionEvent(.connected, attempt: staleAttempt)
        let pendingBeforeCurrentCallback = await harness.broker.pendingConnectionCount
        XCTAssertEqual(pendingBeforeCurrentCallback, 1)
        let attempt = await harness.reconnect.requests[0]
        await harness.broker.handleConnectionEvent(.connected, attempt: attempt)

        let generation = try await result.value
        XCTAssertEqual(generation, 9)
    }

    func testAttachOfNewGenerationSupersedesOlderConnectionWaiter() async {
        let harness = await makeHarness(generation: 8)
        let old = Task {
            try await harness.broker.withConnection(to: harness.peripheralID) { _ in true }
        }
        await harness.reconnect.waitForRequestCount(1)

        let newTransport = ReplayTransport()
        await harness.broker.attach(.init(
            generation: 9,
            peripheralID: harness.peripheralID,
            transport: newTransport,
            session: DeviceSession(transport: newTransport)
        ))

        await assertThrows(.superseded) { try await old.value }
        let pendingConnectionCount = await harness.broker.pendingConnectionCount
        let requestCount = await harness.reconnect.requests.count
        XCTAssertEqual(pendingConnectionCount, 0)
        XCTAssertEqual(requestCount, 1)
    }

    func testDetachOnlyAffectsMatchingGeneration() async throws {
        let harness = await makeHarness(generation: 9)
        await harness.broker.markConnected(peripheralID: harness.peripheralID, generation: 9)

        await harness.broker.detach(generation: 8)
        _ = try await harness.broker.withConnection(to: harness.peripheralID) { $0 }
        await harness.broker.detach(generation: 9)

        await assertThrows(.unavailable) {
            try await harness.broker.perform(.setDC(true), generation: 9)
        }
    }

    private func makeHarness(generation: UInt) async -> BrokerHarness {
        let peripheralID = UUID()
        let reconnect = ReconnectRequestSpy()
        let clock = BrokerTestClock()
        let broker = DeviceOperationBroker(clock: clock) { attempt in
            await reconnect.record(attempt)
        }
        let transport = ReplayTransport()
        let session = DeviceSession(transport: transport)
        let context = DeviceOperationBroker.Context(
            generation: generation,
            peripheralID: peripheralID,
            transport: transport,
            session: session
        )
        await broker.attach(context)
        return BrokerHarness(
            broker: broker,
            reconnect: reconnect,
            clock: clock,
            peripheralID: peripheralID
        )
    }

    private func assertThrows<T: Sendable>(
        _ expected: DeviceOperationBroker.BrokerError,
        operation: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as DeviceOperationBroker.BrokerError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func assertCancellation<T: Sendable>(
        operation: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected CancellationError", file: file, line: line)
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func eventually(
        timeout: Duration = .seconds(2),
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            if clock.now >= deadline {
                XCTFail("Condition was not met before timeout", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct BrokerHarness: Sendable {
    let broker: DeviceOperationBroker
    let reconnect: ReconnectRequestSpy
    let clock: BrokerTestClock
    let peripheralID: UUID
}

private actor OperationCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor ReconnectRequestSpy {
    private(set) var requests: [DeviceOperationBroker.ConnectionAttempt] = []

    func record(_ attempt: DeviceOperationBroker.ConnectionAttempt) {
        requests.append(attempt)
    }

    func waitForRequestCount(_ count: Int) async {
        while requests.count < count { await Task.yield() }
    }
}

private actor BrokerTestClock: DeviceClock {
    private struct Sleeper {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Never>
    }

    private(set) var now: Duration = .zero
    private var sleepers: [Sleeper] = []
    var sleeperCount: Int { sleepers.count }

    func sleep(for duration: Duration) async throws {
        await withCheckedContinuation { continuation in
            sleepers.append(Sleeper(deadline: now + duration, continuation: continuation))
        }
    }

    func advance(by duration: Duration) {
        now += duration
        let ready = sleepers.filter { $0.deadline <= now }
        sleepers.removeAll { $0.deadline <= now }
        ready.forEach { $0.continuation.resume() }
    }

    func waitForSleepers(_ count: Int) async {
        while sleepers.count < count { await Task.yield() }
    }
}
