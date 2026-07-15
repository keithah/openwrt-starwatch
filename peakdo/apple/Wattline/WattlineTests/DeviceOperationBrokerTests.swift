import Foundation
@testable import Wattline
import WattlineCore
import XCTest

final class DeviceOperationBrokerTests: XCTestCase {
    func testBrokerUsesAttachedSessionAndRejectsStaleGeneration() async throws {
        let reply = Data([Command.dcControl.rawValue, Action.set.rawValue | 0x80, 0])
        let replay = ReplayTransport(steps: [.reply(bytes: reply)])
        let session = DeviceSession(transport: replay)
        let broker = DeviceOperationBroker()
        let peripheralID = UUID()
        await broker.attach(.init(
            generation: 4,
            peripheralID: peripheralID,
            transport: replay,
            session: session
        ))

        _ = try await broker.perform(.setDC(true), generation: 4)
        await assertThrows(.superseded) {
            try await broker.perform(.setDC(false), generation: 3)
        }

        let maximumInFlightCount = await replay.maximumInFlightCount
        XCTAssertEqual(maximumInFlightCount, 1)
    }

    func testConnectedContextIsReusedWithoutReconnect() async throws {
        let harness = await makeHarness(generation: 3)
        await harness.broker.handleConnectionEvent(
            .connected(harness.peripheralID),
            generation: 3
        )

        let generation = try await harness.broker.withConnection(to: harness.peripheralID) {
            $0.generation
        }

        XCTAssertEqual(generation, 3)
        let requests = await harness.reconnect.requests
        XCTAssertEqual(requests, [])
    }

    func testAttachingDifferentPeripheralInSameGenerationRequiresReconnect() async {
        let harness = await makeHarness(generation: 3)
        await harness.broker.handleConnectionEvent(
            .connected(harness.peripheralID),
            generation: 3
        )
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
        for _ in 0..<20 { await Task.yield() }

        let requests = await harness.reconnect.requests
        XCTAssertEqual(requests, [.init(id: nextPeripheralID, generation: 3)])
        result.cancel()
        await assertCancellation { try await result.value }
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
        await harness.broker.handleConnectionEvent(
            .connected(harness.peripheralID),
            generation: 8
        )

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
        await harness.broker.handleConnectionEvent(
            .connected(harness.peripheralID),
            generation: 8
        )

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
        await harness.broker.handleConnectionEvent(.terminal, generation: 8)

        let pendingConnectionCount = await harness.broker.pendingConnectionCount
        XCTAssertEqual(pendingConnectionCount, 0)
    }

    func testTerminalFailureRemovesWaiterAndLateSuccessCannotResumeItAgain() async {
        let harness = await makeHarness(generation: 8)
        let result = Task {
            try await harness.broker.withConnection(to: harness.peripheralID) { _ in true }
        }
        await harness.reconnect.waitForRequestCount(1)

        await harness.broker.handleConnectionEvent(.terminal, generation: 8)
        await assertThrows(.unavailable) { try await result.value }
        await harness.broker.handleConnectionEvent(
            .connected(harness.peripheralID),
            generation: 8
        )

        let pendingConnectionCount = await harness.broker.pendingConnectionCount
        XCTAssertEqual(pendingConnectionCount, 0)
    }

    func testStaleGenerationCallbackIsQuarantinedFromCurrentWaiter() async throws {
        let harness = await makeHarness(generation: 9)
        let result = Task {
            try await harness.broker.withConnection(to: harness.peripheralID) { $0.generation }
        }
        await harness.reconnect.waitForRequestCount(1)

        await harness.broker.handleConnectionEvent(
            .connected(harness.peripheralID),
            generation: 8
        )
        let pendingBeforeCurrentCallback = await harness.broker.pendingConnectionCount
        XCTAssertEqual(pendingBeforeCurrentCallback, 1)
        await harness.broker.handleConnectionEvent(
            .connected(harness.peripheralID),
            generation: 9
        )

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
        await harness.broker.handleConnectionEvent(
            .connected(harness.peripheralID),
            generation: 9
        )

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
        let broker = DeviceOperationBroker(clock: clock) { id, requestedGeneration in
            await reconnect.record(id: id, generation: requestedGeneration)
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
}

private struct BrokerHarness: Sendable {
    let broker: DeviceOperationBroker
    let reconnect: ReconnectRequestSpy
    let clock: BrokerTestClock
    let peripheralID: UUID
}

private actor ReconnectRequestSpy {
    struct Request: Equatable, Sendable {
        let id: UUID
        let generation: UInt
    }

    private(set) var requests: [Request] = []

    func record(id: UUID, generation: UInt) {
        requests.append(Request(id: id, generation: generation))
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
