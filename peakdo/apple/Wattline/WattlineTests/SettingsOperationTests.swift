import CoreBluetooth
import Foundation
import WattlineCore
import XCTest
@testable import Wattline

@MainActor
final class SettingsOperationTests: XCTestCase {
    func testSyncClockWriteFailureDoesNotRecordLastSync() async throws {
        let transport = SettingsTestTransport(clockWrite: .failure, clockRead: .unsupported)
        let model = try await makeConnectedModel(transport)

        await model.syncClock()

        XCTAssertNil(model.lastClockSync)
    }

    func testSyncClockWithUnsupportedReadShowsUnavailableWithoutEstimate() async throws {
        let transport = SettingsTestTransport(clockWrite: .success, clockRead: .unsupported)
        let model = try await makeConnectedModel(transport)

        await model.syncClock()

        XCTAssertNotNil(model.lastClockSync)
        XCTAssertNil(model.deviceClockDrift)
        XCTAssertEqual(model.clockStatusText, "Drift unavailable")
    }

    func testSyncClockWithReadErrorShowsUnavailableWithoutEstimate() async throws {
        let transport = SettingsTestTransport(clockWrite: .success, clockRead: .failure)
        let model = try await makeConnectedModel(transport)

        await model.syncClock()

        XCTAssertNotNil(model.lastClockSync)
        XCTAssertNil(model.deviceClockDrift)
        XCTAssertEqual(model.clockStatusText, "Drift unavailable")
    }

    func testBypassNonstandardReplyLeavesTelemetryUnchangedAndOnlyMatchingTelemetryClearsPending() async throws {
        let transport = SettingsTestTransport(clockWrite: .success, clockRead: .unsupported)
        let model = try await makeConnectedModel(transport)
        let off = try DCPortStatus(frame: Data(repeating: 0, count: 9))
        await transport.emit(.dc(off, timestamp: .zero))
        try await eventually { model.state.dc == off }

        model.setBypass(true)
        try await eventually { model.state.pendingMutations.contains { $0.reconciler == .bypass(true) } }
        XCTAssertEqual(model.state.dc, off, "A nonstandard bypass reply must not mutate telemetry")

        var nonmatchingFrame = Data(repeating: 0, count: 9)
        nonmatchingFrame[0] = 1
        let nonmatching = try DCPortStatus(frame: nonmatchingFrame)
        await transport.emit(.dc(nonmatching, timestamp: .seconds(1)))
        try await eventually { model.state.dc == nonmatching }
        XCTAssertTrue(model.state.pendingMutations.contains { $0.reconciler == .bypass(true) }, "Only matching telemetry should reconcile bypass")

        var onFrame = Data(repeating: 0, count: 9)
        onFrame[0] = 1
        onFrame[8] = 1
        let on = try DCPortStatus(frame: onFrame)
        await transport.emit(.dc(on, timestamp: .seconds(2)))
        try await eventually { model.state.dc == on && !model.state.pendingMutations.contains { $0.reconciler == .bypass(true) } }
    }

    func testPendingDCQueryMatchesRequestedTargetRatherThanConfirmedEnabledValue() async throws {
        let transport = SettingsTestTransport(clockWrite: .success, clockRead: .unsupported)
        let model = try await makeConnectedModel(transport)
        let off = try DCPortStatus(frame: Data(repeating: 0, count: 8))
        await transport.emit(.dc(off, timestamp: .zero))
        try await eventually { model.state.dc == off }
        model.setDC(true)
        try await eventually { model.state.pendingMutations.contains { $0.reconciler == .dcEnabled(true) } }

        XCTAssertEqual(model.state.dc?.enabled, false, "Confirmed telemetry remains off while the requested on mutation is pending")
    }

    private func makeConnectedModel(_ transport: SettingsTestTransport) async throws -> AppModel {
        let suite = "WattlineTests.SettingsOperation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let persistence = AppPersistence(defaults: defaults)
        let model = AppModel(persistence: persistence, transportFactory: { transport })
        model.requestBluetoothAfterPriming()
        model.choose(DiscoveredDevice(id: UUID(), localName: "Link-Power 2", rssi: -40, mode: .application))
        try await eventually {
            guard model.connectionStatus == .connected else { return false }
            return await model.deviceOperationBroker.hasConnectedContext
        }
        return model
    }

    private func eventually(condition: @escaping () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await condition()) {
            if ContinuousClock.now >= deadline { XCTFail("Condition was not met before timeout"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor SettingsTestTransport: DeviceTransport {
    enum ClockWrite: Sendable { case success, failure }
    enum ClockRead: Sendable { case unsupported, failure }
    enum Failure: Error { case expected }

    nonisolated let events: AsyncStream<DeviceEvent>
    private let continuation: AsyncStream<DeviceEvent>.Continuation
    private let clockWrite: ClockWrite
    private let clockRead: ClockRead

    init(clockWrite: ClockWrite, clockRead: ClockRead) {
        let pair = AsyncStream<DeviceEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
        self.clockWrite = clockWrite
        self.clockRead = clockRead
    }

    func startScan() async throws {}
    func stopScan() async {}
    func connect(to id: UUID, scope: DeviceConnectionScope) async throws { continuation.yield(.connected(scope)) }
    func disconnect() async {}
    func perform(_ command: DeviceCommand) async throws -> CommandOutcome {
        if command.reconciler == .bypass(true) {
            return .reply(try command.validate(Data([Command.dcBypassControl.rawValue, Action.set.rawValue | 0x80, 0xFD])))
        }
        return .sent
    }
    func refreshTelemetry() async throws {}
    func synchronizeDeviceTime() async throws {
        if clockWrite == .failure { throw Failure.expected }
    }
    func readDeviceTimeIfSupported() async throws -> Date? {
        switch clockRead {
        case .unsupported: return nil
        case .failure: throw Failure.expected
        }
    }

    func emit(_ event: DeviceEvent) {
        continuation.yield(event)
    }
}
