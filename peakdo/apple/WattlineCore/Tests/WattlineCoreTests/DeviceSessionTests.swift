import Foundation
import XCTest
@testable import WattlineCore

@MainActor
final class DeviceSessionTests: XCTestCase {
    func testStaleLifecycleScopesCannotMutateCurrentConnection() async {
        let peripheralID = UUID()
        let old = DeviceConnectionScope(peripheralID: peripheralID, sessionID: UUID())
        let current = DeviceConnectionScope(peripheralID: peripheralID, sessionID: UUID())
        let session = DeviceSession(transport: ReplayTransport())

        await session.receive(.connected(old))
        await session.receive(.disconnected(old, nil))
        await session.receive(.reconnecting(current))
        await session.receive(.connected(current))
        await session.receive(.disconnected(old, TransportFailure(message: "stale terminal")))
        await session.receive(.connected(old))
        await session.receive(.reconnecting(old))

        var state = await session.state
        XCTAssertNotEqual(state.connection, .disconnected)
        XCTAssertNil(state.lastError)

        await session.receive(.disconnected(current, TransportFailure(message: "current terminal")))
        state = await session.state
        XCTAssertEqual(state.connection, .disconnected)
        XCTAssertEqual(state.lastError, "current terminal")
    }

    func testRetiredScopeCannotReactivateOrReplaceIdentityWhenNoScopeIsActive() async {
        let peripheralID = UUID()
        let retired = DeviceConnectionScope(peripheralID: peripheralID, sessionID: UUID())
        let session = DeviceSession(transport: ReplayTransport())
        let staleIdentity = DeviceIdentitySnapshot(
            peripheralID: peripheralID,
            advertisedName: "Stale",
            mode: .application,
            capabilities: DeviceCapabilities(features: [])
        )

        await session.receive(.connected(retired))
        await session.receive(.disconnected(retired, TransportFailure(message: "ended")))
        await session.receive(.connected(retired))
        await session.receive(.handshakeCompleted(staleIdentity, scope: retired))

        let state = await session.state
        XCTAssertEqual(state.connection, .disconnected)
        XCTAssertEqual(state.lastError, "ended")
        XCTAssertNil(state.identity)
    }

    func testStateStreamPublishesPendingConfirmationAndClearsStaleError() async throws {
        let clock = TestDeviceClock()
        let reply = Data([Command.dcControl.rawValue, Action.set.rawValue | 0x80, 0])
        let session = DeviceSession(
            transport: ReplayTransport(steps: [.reply(bytes: reply)]),
            clock: clock
        )
        var iterator = session.states.makeAsyncIterator()
        _ = await iterator.next()

        let operation = Task { try await session.perform(.setDC(true)) }
        let nextState = await iterator.next()
        let pending = try XCTUnwrap(nextState)
        XCTAssertEqual(pending.pendingMutations.count, 1)
        XCTAssertNil(pending.lastError)
        _ = try await operation.value

        let confirmed = try DCPortStatus(frame: Data([1, 0, 0, 0, 0, 0, 0, 0]))
        await session.receive(.dc(confirmed, timestamp: await clock.now))
        var confirmation: DeviceState?
        while confirmation?.pendingMutations.isEmpty != true {
            confirmation = await iterator.next()
        }
        XCTAssertNil(confirmation?.lastError)
    }

    func testLateConfirmationAfterTimeoutClearsMutationError() async throws {
        let clock = TestDeviceClock()
        let reply = Data([Command.dcControl.rawValue, Action.set.rawValue | 0x80, 0])
        let session = DeviceSession(
            transport: ReplayTransport(steps: [.reply(bytes: reply)]),
            clock: clock
        )

        _ = try await session.perform(.setDC(true))
        await clock.waitForSleepers(1)
        await clock.advance(by: .seconds(3))
        let didTimeOut = await eventually {
            await session.state.lastError == "Device did not confirm the requested change."
        }
        XCTAssertTrue(didTimeOut)
        let timedOut = await session.state
        XCTAssertEqual(timedOut.lastError, "Device did not confirm the requested change.")

        let confirmed = try DCPortStatus(frame: Data([1, 0, 0, 0, 0, 0, 0, 0]))
        await session.receive(.dc(confirmed, timestamp: await clock.now))

        let lateConfirmation = await session.state
        XCTAssertNil(lateConfirmation.lastError)
    }

    func testTelemetryBecomesStaleAfterTenSeconds() async throws {
        let clock = TestDeviceClock()
        let session = DeviceSession(transport: ReplayTransport(), clock: clock)
        let battery = try BatteryStatus(frame: Data(repeating: 0, count: 16))

        await session.receive(.battery(battery, timestamp: await clock.now))
        var state = await session.state
        XCTAssertEqual(state.freshness, .live)
        await clock.waitForSleepers(1)

        await clock.advance(by: .seconds(11))
        let didBecomeStale = await eventually {
            await session.state.freshness == .stale
        }
        XCTAssertTrue(didBecomeStale)
        state = await session.state
        XCTAssertEqual(state.freshness, .stale)
    }

    func testFreshnessUsesSessionReceiptTimeWhenTransportClockHasDifferentOrigin() async throws {
        let transportClock = TestDeviceClock()
        let sessionClock = TestDeviceClock()
        await sessionClock.advance(by: .seconds(100))
        let session = DeviceSession(transport: ReplayTransport(clock: transportClock), clock: sessionClock)
        let battery = try BatteryStatus(frame: Data(repeating: 0, count: 16))

        await session.receive(.battery(battery, timestamp: await transportClock.now))
        var state = await session.state
        guard state.freshness == .live else {
            return XCTFail("Fresh telemetry was treated as old because clock origins differ")
        }
        await sessionClock.waitForSleepers(1)

        await sessionClock.advance(by: .seconds(9))
        await Task.yield()
        state = await session.state
        XCTAssertEqual(state.freshness, .live)

        await sessionClock.advance(by: .seconds(2))
        let didBecomeStale = await eventually {
            await session.state.freshness == .stale
        }
        XCTAssertTrue(didBecomeStale)
        state = await session.state
        XCTAssertEqual(state.freshness, .stale)
    }

    func testNewTelemetrySupersedesEarlierStalenessDeadline() async throws {
        let clock = TestDeviceClock()
        let session = DeviceSession(transport: ReplayTransport(), clock: clock)
        let first = try DCPortStatus(frame: Data([0, 0, 0, 0, 0, 0, 0, 0]))
        let second = try DCPortStatus(frame: Data([1, 0, 0, 0, 0, 0, 0, 0]))

        await session.receive(.dc(first, timestamp: await clock.now))
        await clock.waitForSleepers(1)
        await clock.advance(by: .seconds(9))
        await session.receive(.dc(second, timestamp: await clock.now))
        await clock.waitForSleepers(2)
        await clock.advance(by: .seconds(1))
        await Task.yield()

        let state = await session.state
        XCTAssertEqual(state.freshness, .live)
        XCTAssertEqual(state.dc, second)
    }

    func testDisconnectPreservesLastKnownTelemetry() async throws {
        let session = DeviceSession(transport: ReplayTransport(), clock: TestDeviceClock())
        let status = try DCPortStatus(frame: Data([1, 0, 0, 0, 0, 0, 0, 0]))
        await session.receive(.dc(status, timestamp: .zero))

        let scope = DeviceConnectionScope(peripheralID: UUID(), sessionID: UUID())
        await session.receive(.connected(scope))
        await session.receive(.disconnected(scope, TransportFailure(message: "link lost")))

        let state = await session.state
        XCTAssertEqual(state.connection, .disconnected)
        XCTAssertEqual(state.freshness, .stale)
        XCTAssertEqual(state.dc, status)
        XCTAssertEqual(state.lastError, "link lost")
    }

    func testConnectedEventCannotDowngradeTelemetryThatIsAlreadyLive() async throws {
        let clock = TestDeviceClock()
        let session = DeviceSession(transport: ReplayTransport(), clock: clock)
        let battery = try BatteryStatus(frame: Data(repeating: 0, count: 16))
        await session.receive(.battery(battery, timestamp: .zero))

        await session.receive(.connected(DeviceConnectionScope(peripheralID: UUID(), sessionID: UUID())))

        let state = await session.state
        XCTAssertEqual(state.connection, .live)
        XCTAssertEqual(state.freshness, .live)
        XCTAssertEqual(state.battery, battery)
    }

    func testPendingMutationClearsOnlyWhenTelemetryConfirmsIt() async throws {
        let clock = TestDeviceClock()
        let reply = Data([Command.dcControl.rawValue, Action.set.rawValue | 0x80, 0])
        let session = DeviceSession(transport: ReplayTransport(steps: [.reply(bytes: reply)]), clock: clock)

        _ = try await session.perform(.setDC(true))
        var state = await session.state
        XCTAssertEqual(state.pendingMutations.count, 1)
        let off = try DCPortStatus(frame: Data([0, 0, 0, 0, 0, 0, 0, 0]))
        await session.receive(.dc(off, timestamp: await clock.now))
        state = await session.state
        XCTAssertEqual(state.pendingMutations.count, 1)
        let on = try DCPortStatus(frame: Data([1, 0, 0, 0, 0, 0, 0, 0]))
        await session.receive(.dc(on, timestamp: await clock.now))
        state = await session.state
        XCTAssertTrue(state.pendingMutations.isEmpty)
    }

    func testBypassNonstandardReplyWaitsForTelemetryAndTimesOutAfterTenSeconds() async throws {
        let clock = TestDeviceClock()
        let replay = ReplayTransport(steps: [
            .reply(bytes: Data([0x14, 0x81, 0xFD])),
        ])
        let session = DeviceSession(transport: replay, clock: clock)

        _ = try await session.perform(.setBypass(true))
        var state = await session.state
        XCTAssertEqual(state.pendingMutations.map(\.reconciler), [.bypass(true)])
        XCTAssertNil(state.lastError)

        let bypassOff = try DCPortStatus(frame: Data([1, 0, 0, 0, 0, 0, 0, 0, 0]))
        await session.receive(.dc(bypassOff, timestamp: await clock.now))
        state = await session.state
        XCTAssertEqual(state.pendingMutations.map(\.reconciler), [.bypass(true)])

        await clock.waitForSleepers(2)
        await clock.advance(by: .seconds(9))
        await Task.yield()
        state = await session.state
        XCTAssertEqual(state.pendingMutations.map(\.reconciler), [.bypass(true)])
        XCTAssertNil(state.lastError)

        await clock.advance(by: .seconds(2))
        let didTimeOut = await eventually {
            await session.state.pendingMutations.isEmpty
        }
        XCTAssertTrue(didTimeOut)
        state = await session.state
        XCTAssertTrue(state.pendingMutations.isEmpty)
        XCTAssertEqual(state.lastError, "Device did not confirm the requested change.")

        let bypassOn = try DCPortStatus(frame: Data([1, 0, 0, 0, 0, 0, 0, 0, 1]))
        await session.receive(.dc(bypassOn, timestamp: await clock.now))
        state = await session.state
        XCTAssertNil(state.lastError, "Late authoritative telemetry must reconcile the timeout")
    }

    func testMutationTimeoutClearsPendingAndPreservesTelemetryTruth() async throws {
        let clock = TestDeviceClock()
        let reply = Data([Command.dcControl.rawValue, Action.set.rawValue | 0x80, 0])
        let session = DeviceSession(transport: ReplayTransport(steps: [.reply(bytes: reply)]), clock: clock)
        let off = try DCPortStatus(frame: Data([0, 0, 0, 0, 0, 0, 0, 0]))
        await session.receive(.dc(off, timestamp: await clock.now))

        _ = try await session.perform(.setDC(true))
        await clock.waitForSleepers(2)
        await clock.advance(by: .seconds(3))
        let didTimeOut = await eventually {
            await session.state.pendingMutations.isEmpty
        }
        XCTAssertTrue(didTimeOut)

        let state = await session.state
        XCTAssertTrue(state.pendingMutations.isEmpty)
        XCTAssertEqual(state.dc, off)
        XCTAssertEqual(state.lastError, "Device did not confirm the requested change.")
    }

    func testCommandFollowUpReturnsAuthoritativeReadback() async throws {
        let replay = ReplayTransport(steps: [
            .reply(bytes: Data([Command.typeCPowerLimit.rawValue, Action.set.rawValue | 0x80, 0])),
            .reply(bytes: Data([Command.typeCPowerLimit.rawValue, Action.get.rawValue | 0x80, 0, 3])),
        ])
        let session = DeviceSession(transport: replay, clock: TestDeviceClock())

        let outcome = try await session.perform(.setPowerLimit(.global, level: .watts65))

        guard case let .reply(reply) = outcome else {
            return XCTFail("Expected the follow-up readback")
        }
        XCTAssertEqual(reply.payload, Data([3]))
    }

    func testConcurrentCommandAndReadbackPairsAreAtomic() async throws {
        let clock = TestDeviceClock()
        let replay = ReplayTransport(steps: [
            .reply(after: .seconds(1), bytes: Data([Command.typeCPowerLimit.rawValue, Action.set.rawValue | 0x80, 0])),
            .reply(bytes: Data([Command.typeCPowerLimit.rawValue, Action.get.rawValue | 0x80, 0, 3])),
            .reply(bytes: Data([Command.typeCPowerLimit.rawValue, Action.set.rawValue | 0x80, 0])),
            .reply(bytes: Data([Command.typeCPowerLimit.rawValue, Action.get.rawValue | 0x80, 0, 4])),
        ], clock: clock)
        let session = DeviceSession(transport: replay, clock: clock)

        let first = Task { try await session.perform(.setPowerLimit(.global, level: .watts65)) }
        await clock.waitForSleepers(1)
        let second = Task { try await session.perform(.setPowerLimit(.input, level: .watts100)) }
        while await session.logicalOperationDepth < 2 { await Task.yield() }
        await clock.advance(by: .seconds(1))

        let outcomes = try await (first.value, second.value)
        XCTAssertEqual(outcomes.0.replyPayload, Data([3]))
        XCTAssertEqual(outcomes.1.replyPayload, Data([4]))
        let finalDepth = await session.logicalOperationDepth
        XCTAssertEqual(finalDepth, 0)
    }

    func testTransportTimestampDoesNotMakeFreshReceiptImmediatelyStale() async throws {
        let clock = TestDeviceClock()
        await clock.advance(by: .seconds(20))
        let session = DeviceSession(transport: ReplayTransport(), clock: clock)
        let status = try DCPortStatus(frame: Data([1, 0, 0, 0, 0, 0, 0, 0]))

        await session.receive(.dc(status, timestamp: .zero))
        await clock.waitForSleepers(1)

        let state = await session.state
        let sleeperCount = await clock.sleeperCount
        XCTAssertEqual(state.freshness, .live)
        XCTAssertEqual(sleeperCount, 1)
    }

    func testFreshnessDeadlineStartsWhenSessionReceivesTelemetry() async throws {
        let clock = TestDeviceClock()
        await clock.advance(by: .seconds(9))
        let session = DeviceSession(transport: ReplayTransport(), clock: clock)
        let status = try DCPortStatus(frame: Data([1, 0, 0, 0, 0, 0, 0, 0]))

        await session.receive(.dc(status, timestamp: .zero))
        await clock.waitForSleepers(1)
        await clock.advance(by: .seconds(1))
        await Task.yield()

        var state = await session.state
        XCTAssertEqual(state.freshness, .live)

        await clock.advance(by: .seconds(9))
        let didBecomeStale = await eventually {
            await session.state.freshness == .stale
        }
        XCTAssertTrue(didBecomeStale)
        state = await session.state
        XCTAssertEqual(state.freshness, .stale)
    }

    func testOlderOutOfOrderTelemetryCannotOverwriteNewerState() async throws {
        let clock = TestDeviceClock()
        await clock.advance(by: .seconds(2))
        let session = DeviceSession(transport: ReplayTransport(), clock: clock)
        let newer = try DCPortStatus(frame: Data([1, 0, 0, 0, 0, 0, 0, 0]))
        let older = try DCPortStatus(frame: Data([0, 0, 0, 0, 0, 0, 0, 0]))

        await session.receive(.dc(newer, timestamp: .seconds(2)))
        await session.receive(.dc(older, timestamp: .seconds(1)))

        let state = await session.state
        XCTAssertEqual(state.dc, newer)
        XCTAssertEqual(state.lastTelemetryAt, .seconds(2))
    }

    func testOlderSampleFromAnotherTelemetryChannelStillUpdatesThatChannel() async throws {
        let clock = TestDeviceClock()
        await clock.advance(by: .seconds(2))
        let session = DeviceSession(transport: ReplayTransport(), clock: clock)
        let battery = try BatteryStatus(frame: Data(repeating: 0, count: 16))
        let dc = try DCPortStatus(frame: Data([1, 0, 0, 0, 0, 0, 0, 0]))

        await session.receive(.battery(battery, timestamp: .seconds(2)))
        await session.receive(.dc(dc, timestamp: .seconds(1)))

        let state = await session.state
        XCTAssertEqual(state.dc, dc)
        XCTAssertEqual(state.lastTelemetryAt, .seconds(2))
    }

    func testMutationTimeoutBudgetIncludesSlowCommandIO() async throws {
        let clock = TestDeviceClock()
        let reply = Data([Command.dcControl.rawValue, Action.set.rawValue | 0x80, 0])
        let replay = ReplayTransport(steps: [.reply(after: .seconds(4), bytes: reply)], clock: clock)
        let session = DeviceSession(transport: replay, clock: clock)

        let operation = Task { try await session.perform(.setDC(true)) }
        await clock.waitForSleepers(2)
        await clock.advance(by: .seconds(3))
        let didTimeOut = await eventually {
            await session.state.pendingMutations.isEmpty
        }
        XCTAssertTrue(didTimeOut)

        var state = await session.state
        XCTAssertTrue(state.pendingMutations.isEmpty)
        XCTAssertEqual(state.lastError, "Device did not confirm the requested change.")
        await clock.advance(by: .seconds(1))
        _ = try await operation.value
        state = await session.state
        XCTAssertTrue(state.pendingMutations.isEmpty)
    }

    func testStartIsIdempotentAndConsumesBufferedEvents() async throws {
        let status = try DCPortStatus(frame: Data([1, 0, 0, 0, 0, 0, 0, 0]))
        let replay = ReplayTransport(steps: [
            .telemetry(.dc(status, timestamp: .zero)),
            .reply(bytes: Data([Command.dcControl.rawValue, Action.set.rawValue | 0x80, 0])),
        ])
        _ = try await replay.perform(.setDC(true))
        let session = DeviceSession(transport: replay, clock: TestDeviceClock())

        await session.start()
        await session.start()
        while await session.state.dc == nil { await Task.yield() }

        let state = await session.state
        let isRunning = await session.isEventConsumerRunning
        XCTAssertEqual(state.dc, status)
        XCTAssertTrue(isRunning)
    }

    private func eventually(
        timeout: Duration = .seconds(1),
        condition: @escaping () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }
}

private extension CommandOutcome {
    var replyPayload: Data? {
        guard case let .reply(reply) = self else { return nil }
        return reply.payload
    }
}

actor TestDeviceClock: DeviceClock {
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
        while sleepers.count < count {
            await Task.yield()
        }
    }
}
