import Foundation
import XCTest
@testable import WattlineCore

@MainActor
final class DeviceSessionTests: XCTestCase {
    func testTelemetryBecomesStaleAfterTenSeconds() async throws {
        let clock = TestDeviceClock()
        let session = DeviceSession(transport: ReplayTransport(), clock: clock)
        let battery = try BatteryStatus(frame: Data(repeating: 0, count: 16))

        await session.receive(.battery(battery, timestamp: await clock.now))
        var state = await session.state
        XCTAssertEqual(state.freshness, .live)
        await clock.waitForSleepers(1)

        await clock.advance(by: .seconds(11))
        await Task.yield()
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

        await session.receive(.disconnected(TransportFailure(message: "link lost")))

        let state = await session.state
        XCTAssertEqual(state.connection, .disconnected)
        XCTAssertEqual(state.freshness, .stale)
        XCTAssertEqual(state.dc, status)
        XCTAssertEqual(state.lastError, "link lost")
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

    func testMutationTimeoutClearsPendingAndPreservesTelemetryTruth() async throws {
        let clock = TestDeviceClock()
        let reply = Data([Command.dcControl.rawValue, Action.set.rawValue | 0x80, 0])
        let session = DeviceSession(transport: ReplayTransport(steps: [.reply(bytes: reply)]), clock: clock)
        let off = try DCPortStatus(frame: Data([0, 0, 0, 0, 0, 0, 0, 0]))
        await session.receive(.dc(off, timestamp: await clock.now))

        _ = try await session.perform(.setDC(true))
        await clock.waitForSleepers(2)
        await clock.advance(by: .seconds(3))
        await Task.yield()

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
}

actor TestDeviceClock: DeviceClock {
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
        while sleepers.count < count {
            await Task.yield()
        }
    }
}
