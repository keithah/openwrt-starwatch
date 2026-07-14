import Foundation
import XCTest
@testable import WattlineCore

@MainActor
final class DemoTransportTests: XCTestCase {
    func testDemoIdentityMatchesContract() async throws {
        let demo = DemoTransport(seed: 0x57415454)

        let identity = try await demo.connectDemo()

        XCTAssertEqual(identity.name, "Link-Power 2 (Demo)")
        XCTAssertEqual(identity.cid, 0x0305)
        XCTAssertEqual(identity.features.rawValue, 0x7FFF)
        XCTAssertEqual(identity.firmware, "1.4.9")
    }

    func testTypeCOutputChangesModeWhileEnabledStaysTrue() async throws {
        let demo = DemoTransport(seed: 1)

        _ = try await demo.perform(.setTypeCOutput(false))

        let status = await demo.snapshot.typeC
        XCTAssertTrue(status.enabled)
        XCTAssertEqual(status.mode, .input)
    }

    func testLimitSetClearReadbackAndRuntimeUnset() async throws {
        let demo = DemoTransport(seed: 1)

        _ = try await demo.perform(.setPowerLimit(.input, level: .watts30))
        let setReadback = try await demo.perform(.getPowerLimit(.input))
        _ = try await demo.perform(.clearPowerLimit(.input))
        let clearedReadback = try await demo.perform(.getPowerLimit(.input))
        let runtimeReadback = try await demo.perform(.getPowerLimit(.runtime))

        XCTAssertEqual(setReadback.replyPayload, Data([PowerLimitLevel.watts30.rawValue]))
        XCTAssertEqual(clearedReadback.replyPayload, Data([PowerLimitLevel.watts65.rawValue]))
        XCTAssertEqual(runtimeReadback.replyResult, 0xFF)
        let snapshot = await demo.snapshot
        XCTAssertEqual(snapshot.limits[.input], .watts65)
        XCTAssertNil(snapshot.limits[.runtime])
    }

    func testDCControlAndChargerFlipUpdatePlausibleSnapshot() async throws {
        let demo = DemoTransport(seed: 1)

        _ = try await demo.perform(.setDC(false))
        let dcDisabled = await demo.snapshot.dc.enabled
        XCTAssertFalse(dcDisabled)

        await demo.setChargerConnected(true)
        let charging = await demo.snapshot
        XCTAssertTrue(charging.chargerConnected)
        XCTAssertEqual(charging.battery.status, .charging)
        XCTAssertEqual(charging.battery.power, 100, accuracy: 0.001)
        XCTAssertEqual(charging.typeC.mode, .input)
        XCTAssertEqual(charging.typeC.status, .charging)

        await demo.setChargerConnected(false)
        let discharging = await demo.snapshot
        XCTAssertEqual(discharging.battery.status, .discharging)
        XCTAssertEqual(discharging.battery.power, -45, accuracy: 0.001)
    }

    func testConnectAndOneSecondCadenceEmitNormalTransportEvents() async throws {
        let clock = DemoTestClock()
        let demo = DemoTransport(seed: 1, clock: clock)
        var iterator = demo.events.makeAsyncIterator()

        let identity = try await demo.connectDemo()
        XCTAssertEqual(identity.cid, 0x0305)

        let initial = [
            await iterator.next(),
            await iterator.next(),
            await iterator.next(),
            await iterator.next(),
        ].compactMap { $0 }
        XCTAssertEqual(initial.count, 4)
        XCTAssertTrue(initial.contains { if case .connected = $0 { true } else { false } })
        XCTAssertTrue(initial.contains { if case .battery = $0 { true } else { false } })
        XCTAssertTrue(initial.contains { if case .dc = $0 { true } else { false } })
        XCTAssertTrue(initial.contains { if case .typeC = $0 { true } else { false } })

        await clock.waitForSleepers(1)
        await clock.advance(by: .milliseconds(999))
        let sleeperCount = await clock.sleeperCount
        XCTAssertEqual(sleeperCount, 1)
        await clock.advance(by: .milliseconds(1))

        let tick = [
            await iterator.next(),
            await iterator.next(),
            await iterator.next(),
        ].compactMap { $0 }
        XCTAssertEqual(tick.count, 3)
        let timestamp = tick.compactMap(\.telemetryTimestamp).first
        XCTAssertEqual(timestamp, .seconds(1))
        await demo.disconnect()
    }

    func testSeededJitterIsRepeatableBoundedAndRuntimeIsDerived() async throws {
        let first = DemoTransport(seed: 0x57415454)
        let second = DemoTransport(seed: 0x57415454)

        try await first.refreshTelemetry()
        try await second.refreshTelemetry()
        let firstSnapshot = await first.snapshot
        let secondSnapshot = await second.snapshot

        XCTAssertEqual(firstSnapshot, secondSnapshot)
        XCTAssertEqual(firstSnapshot.battery.level, 62)
        XCTAssertEqual(firstSnapshot.dc.voltage, 19.6, accuracy: 19.6 * 0.02)
        XCTAssertEqual(firstSnapshot.dc.current, 1.2, accuracy: 1.2 * 0.02)
        XCTAssertEqual(firstSnapshot.typeC.voltage, 12, accuracy: 12 * 0.02)
        XCTAssertEqual(firstSnapshot.typeC.current, 1.4, accuracy: 1.4 * 0.02)
        let expectedMinutes = UInt16((firstSnapshot.battery.capacity / abs(firstSnapshot.battery.power) * 60).rounded())
        XCTAssertEqual(firstSnapshot.battery.remainingMinutes, expectedMinutes)
    }

    func testCadenceTaskDoesNotRetainTransportUntilExplicitDisconnect() async throws {
        let clock = DemoTestClock()
        weak var weakDemo: DemoTransport?

        do {
            let demo = DemoTransport(seed: 1, clock: clock)
            weakDemo = demo
            _ = try await demo.connectDemo()
            await clock.waitForSleepers(1)
        }

        for _ in 0..<100 where weakDemo != nil { await Task.yield() }
        XCTAssertNil(weakDemo)
    }

}

private extension CommandOutcome {
    var replyPayload: Data? {
        guard case let .reply(reply) = self else { return nil }
        return reply.payload
    }

    var replyResult: UInt8? {
        guard case let .reply(reply) = self else { return nil }
        return reply.result
    }
}

private extension DeviceEvent {
    var telemetryTimestamp: DeviceTimestamp? {
        switch self {
        case let .battery(_, timestamp), let .dc(_, timestamp), let .typeC(_, timestamp): timestamp
        default: nil
        }
    }
}

private actor DemoTestClock: DeviceClock {
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
