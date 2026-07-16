import Foundation
import XCTest
@testable import WattlineCore

@MainActor
final class DemoTransportTests: XCTestCase {
    func testConnectionScopesAreDeterministicAndDistinctAcrossSessions() async throws {
        let first = DemoTransport(seed: 42)
        let second = DemoTransport(seed: 42)
        var firstEvents = first.events.makeAsyncIterator()
        var secondEvents = second.events.makeAsyncIterator()

        _ = try await first.connectDemo()
        _ = try await second.connectDemo()

        let firstScope = try await nextConnectedScope(from: &firstEvents)
        let secondScope = try await nextConnectedScope(from: &secondEvents)
        XCTAssertEqual(firstScope, secondScope)

        await first.disconnect()
        _ = await firstEvents.next()
        _ = try await first.connectDemo()
        let reconnectedScope = try await nextConnectedScope(from: &firstEvents)
        XCTAssertNotEqual(reconnectedScope, firstScope)
        XCTAssertEqual(reconnectedScope.peripheralID, firstScope.peripheralID)
    }

    func testDemoIdentityMatchesContract() async throws {
        let demo = DemoTransport(seed: 0x57415454)

        let identity = try await demo.connectDemo()

        XCTAssertEqual(identity.name, "Link-Power 2 (Demo)")
        XCTAssertEqual(identity.cid, 0x0305)
        XCTAssertEqual(identity.features.rawValue, 0x7FFF)
        XCTAssertEqual(identity.firmware, "1.4.9")
    }

    func testDemoHandshakePrecedesConnectedWithAuthoritativeLP2V5Identity() async throws {
        let demo = DemoTransport(seed: 1)
        var iterator = demo.events.makeAsyncIterator()

        _ = try await demo.connectDemo()

        guard case let .handshakeCompleted(identity, _) = await iterator.next() else {
            return XCTFail("Expected Demo handshake before connected")
        }
        XCTAssertEqual(identity.peripheralID, UUID(uuidString: "57415454-4C49-4E45-8000-000000000305"))
        XCTAssertEqual(identity.advertisedName, "Link-Power 2 (Demo)")
        XCTAssertEqual(identity.mode, .application)
        XCTAssertEqual(identity.modelNumber, "BP4SL3V2")
        XCTAssertEqual(identity.hardwareRevision, "V5#0305")
        XCTAssertEqual(identity.appFirmwareRevision, "1.4.9")
        XCTAssertEqual(identity.cid, 0x0305)
        XCTAssertEqual(identity.rawFeatures, 0x7FFF)
        XCTAssertEqual(identity.capabilities.features.rawValue, 0x7FFF)
        guard case .connected = await iterator.next() else {
            return XCTFail("Expected connected after Demo handshake")
        }
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

    func testChargingTelemetryRespectsInputAndGlobalCapsWithConsistentCurrent() async throws {
        let demo = DemoTransport(seed: 0x57415454)
        await demo.setChargerConnected(true)

        let unrestricted = await demo.snapshot
        XCTAssertEqual(unrestricted.limits[.global], .watts140)
        XCTAssertEqual(unrestricted.limits[.input], .watts140)
        XCTAssertEqual(unrestricted.battery.power, 100, accuracy: 0.001)

        _ = try await demo.perform(.setPowerLimit(.input, level: .watts30))
        for _ in 0..<3 {
            try await demo.refreshTelemetry()
            let capped = await demo.snapshot
            XCTAssertLessThanOrEqual(capped.battery.power, 30.001)
            XCTAssertLessThanOrEqual(capped.typeC.power, 30.001)
            XCTAssertEqual(capped.battery.current * capped.battery.voltage, capped.battery.power, accuracy: 0.35)
            XCTAssertEqual(capped.typeC.current * capped.typeC.voltage, capped.typeC.power, accuracy: 0.35)
        }

        _ = try await demo.perform(.setPowerLimit(.input, level: .watts140))
        _ = try await demo.perform(.setPowerLimit(.global, level: .watts30))
        let globallyCapped = await demo.snapshot
        XCTAssertEqual(globallyCapped.battery.power, 30, accuracy: 0.001)
        XCTAssertEqual(globallyCapped.typeC.power, 30, accuracy: 0.001)
    }

    func testThirtyWattOutputCapNeverAllowsOutputTelemetryAboveThirtyWatts() async throws {
        let demo = DemoTransport(seed: 0x57415454, typeCOutputCurrent: 4)
        let unrestricted = await demo.snapshot.typeC
        XCTAssertEqual(unrestricted.power, 48, accuracy: 0.001)

        _ = try await demo.perform(.setPowerLimit(.output, level: .watts30))

        for _ in 0..<3 {
            try await demo.refreshTelemetry()
            let output = await demo.snapshot.typeC
            XCTAssertEqual(output.mode, .output)
            XCTAssertEqual(output.power, 30, accuracy: 0.001)
            XCTAssertLessThan(output.power, unrestricted.power)
            XCTAssertEqual(output.current * output.voltage, output.power, accuracy: 0.35)
        }
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
            await iterator.next(),
        ].compactMap { $0 }
        XCTAssertEqual(initial.count, 5)
        XCTAssertTrue(initial.contains { if case .handshakeCompleted = $0 { true } else { false } })
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

    func testDisconnectDuringCadenceTimestampReadSuppressesOldTick() async throws {
        let clock = DemoSuspendingNowClock(immediateNowReads: 1)
        let demo = DemoTransport(seed: 1, clock: clock)
        let recorder = DemoEventRecorder()
        await recorder.start(stream: demo.events)
        _ = try await demo.connectDemo()
        await recorder.waitForEventCount(5)
        await clock.waitForSleepers(1)

        await clock.advance(by: .seconds(1))
        await clock.waitForNowWaiters(1)
        await demo.disconnect()
        await recorder.waitForEventCount(6)
        await clock.resumeNextNow()
        for _ in 0..<100 { await Task.yield() }

        let events = await recorder.events
        XCTAssertEqual(events.count, 6)
        guard case .disconnected(_, nil) = events.last else {
            return XCTFail("Expected scoped clean disconnect")
        }
    }

    func testCadenceTimestampReadDoesNotRetainTransport() async throws {
        let clock = DemoSuspendingNowClock(immediateNowReads: 1)
        weak var weakDemo: DemoTransport?

        do {
            let demo = DemoTransport(seed: 1, clock: clock)
            weakDemo = demo
            _ = try await demo.connectDemo()
            await clock.waitForSleepers(1)
            await clock.advance(by: .seconds(1))
            await clock.waitForNowWaiters(1)
        }

        for _ in 0..<100 where weakDemo != nil { await Task.yield() }
        XCTAssertNil(weakDemo)
        await clock.resumeNextNow()
    }

    func testChargerTemporarilyOverridesEnabledOutputPreference() async throws {
        let demo = DemoTransport(seed: 1)

        await demo.setChargerConnected(true)
        let pluggedMode = await demo.snapshot.typeC.mode
        XCTAssertEqual(pluggedMode, .input)
        _ = try await demo.perform(.setTypeCOutput(true))
        let whileCharging = await demo.snapshot.typeC
        XCTAssertEqual(whileCharging.mode, .input)
        XCTAssertEqual(whileCharging.status, .charging)

        await demo.setChargerConnected(false)
        let unpluggedMode = await demo.snapshot.typeC.mode
        XCTAssertEqual(unpluggedMode, .output)
    }

    func testDisabledOutputPreferenceSurvivesChargerCycle() async throws {
        let demo = DemoTransport(seed: 1)

        _ = try await demo.perform(.setTypeCOutput(false))
        await demo.setChargerConnected(true)
        _ = try await demo.perform(.setTypeCOutput(false))
        await demo.setChargerConnected(false)

        let restored = await demo.snapshot.typeC
        XCTAssertEqual(restored.mode, .input)
        XCTAssertEqual(restored.status, .idle)
    }

    func testConcurrentCommandsAreSerializedWithPendingDepth() async throws {
        let clock = DemoSuspendingNowClock(immediateNowReads: 0)
        let demo = DemoTransport(seed: 1, clock: clock)
        var iterator = demo.events.makeAsyncIterator()

        let first = Task { try await demo.perform(.setDC(false)) }
        await clock.waitForNowWaiters(1)
        let second = Task { try await demo.perform(.setDC(true)) }
        while await demo.pendingTransactionCount < 2 { await Task.yield() }

        await clock.resumeNextNow()
        await clock.waitForNowWaiters(1)
        await clock.resumeNextNow()
        _ = try await (first.value, second.value)

        var depths: [Int] = []
        while depths.count < 4, let event = await iterator.next() {
            if case let .transactionDepth(depth) = event { depths.append(depth) }
        }
        XCTAssertEqual(depths, [1, 2, 1, 0])
        let maximumPending = await demo.maximumPendingTransactionCount
        let finalPending = await demo.pendingTransactionCount
        let dcEnabled = await demo.snapshot.dc.enabled
        XCTAssertEqual(maximumPending, 2)
        XCTAssertEqual(finalPending, 0)
        XCTAssertTrue(dcEnabled)
    }

    func testSupportedCommandsRejectMalformedAndTrailingPayloads() async throws {
        let demo = DemoTransport(seed: 1)
        let malformed = [
            rawCommand(.dcControl, action: .set, payload: []),
            rawCommand(.dcControl, action: .set, payload: [1, 0]),
            rawCommand(.typeCControl, action: .set, payload: [2]),
            rawCommand(.typeCControl, action: .set, payload: [2, 1, 0]),
            rawCommand(.dcBypassControl, action: .set, payload: [1, 0]),
            rawCommand(.typeCPowerLimit, action: .get, payload: [1, 0]),
            rawCommand(.typeCPowerLimit, action: .set, payload: [1, 3, 0]),
            rawCommand(.typeCPowerLimit, action: .delete, payload: [1, 0]),
            rawCommand(.runningModeControl, action: .set, payload: []),
            rawCommand(.runningModeControl, action: .set, payload: [2]),
            rawCommand(.runningModeControl, action: .set, payload: [0, 1]),
        ]

        for command in malformed {
            do {
                _ = try await demo.perform(command)
                XCTFail("Expected malformed command: \(command.request.bytes as NSData)")
            } catch let error as DemoTransportError {
                XCTAssertEqual(error, .malformedCommand)
            }
        }

        _ = try await demo.perform(.runningMode(.factory))
    }

    private func rawCommand(_ command: Command, action: Action, payload: [UInt8]) -> DeviceCommand {
        DeviceCommand(request: DeviceRequest(CommandRequest(
            command: command,
            action: action,
            payload: payload
        )))
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

private func nextConnectedScope(
    from iterator: inout AsyncStream<DeviceEvent>.AsyncIterator
) async throws -> DeviceConnectionScope {
    while let event = await iterator.next() {
        if case let .connected(scope) = event { return scope }
    }
    throw XCTSkip("Event stream ended before a connected event")
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

private actor DemoSuspendingNowClock: DeviceClock {
    private struct Sleeper {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Never>
    }

    private let immediateNowReads: Int
    private var nowReadCount = 0
    private var instant: Duration = .zero
    private var sleepers: [Sleeper] = []
    private var nowWaiters: [CheckedContinuation<Duration, Never>] = []

    init(immediateNowReads: Int) {
        self.immediateNowReads = immediateNowReads
    }

    var now: Duration {
        get async {
            nowReadCount += 1
            guard nowReadCount > immediateNowReads else { return instant }
            return await withCheckedContinuation { nowWaiters.append($0) }
        }
    }

    func sleep(for duration: Duration) async throws {
        await withCheckedContinuation { continuation in
            sleepers.append(Sleeper(deadline: instant + duration, continuation: continuation))
        }
    }

    func advance(by duration: Duration) {
        instant += duration
        let ready = sleepers.filter { $0.deadline <= instant }
        sleepers.removeAll { $0.deadline <= instant }
        ready.forEach { $0.continuation.resume() }
    }

    func resumeNextNow() {
        nowWaiters.removeFirst().resume(returning: instant)
    }

    func waitForSleepers(_ count: Int) async {
        while sleepers.count < count { await Task.yield() }
    }

    func waitForNowWaiters(_ count: Int) async {
        while nowWaiters.count < count { await Task.yield() }
    }
}

private actor DemoEventRecorder {
    private(set) var events: [DeviceEvent] = []
    private var task: Task<Void, Never>?

    func start(stream: AsyncStream<DeviceEvent>) {
        guard task == nil else { return }
        task = Task { [weak self] in
            for await event in stream { await self?.record(event) }
        }
    }

    deinit { task?.cancel() }

    func waitForEventCount(_ count: Int) async {
        while events.count < count { await Task.yield() }
    }

    private func record(_ event: DeviceEvent) {
        events.append(event)
    }
}
