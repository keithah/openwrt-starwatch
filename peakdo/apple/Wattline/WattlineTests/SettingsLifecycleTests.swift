import Foundation
import XCTest
import WattlineCore
@testable import Wattline

@MainActor
final class SettingsLifecycleTests: XCTestCase {
    func testCanceledMaintenanceClockSleepRemovesRegisteredSleeper() async throws {
        let clock = TestDeviceClock()
        let task = Task { try await clock.sleep(for: .seconds(100)) }
        try await waitUntil { await clock.sleeperCount == 1 }
        task.cancel()
        _ = try? await task.value
        try await waitUntil { await clock.sleeperCount == 0 }
    }
    func testRestartWriteFailureWhileStillConnectedShowsRetryWithoutRecovery() async throws {
        let clock = TestDeviceClock()
        let transport = LifecycleTransport(reconnectAfterRestart: false, restartFails: true)
        let model = try await makeConnectedModel(transport, clock: clock)

        await model.restartDevice()

        guard case .restartFailed = model.maintenanceState else {
            return XCTFail("An ordinary restart write failure must expose Retry")
        }
        XCTAssertEqual(model.reconnectAttemptsForTesting, 0)
        XCTAssertEqual(model.route, .connected)
    }

    func testRestartWaitsForScopedDisconnectThenReconnectsAtFifteenSecondsWithoutScan() async throws {
        let clock = TestDeviceClock()
        let transport = LifecycleTransport(reconnectAfterRestart: true, deferReconnect: true)
        let model = try await makeConnectedModel(transport, clock: clock)
        let initialScanStarts = model.scanStartsForTesting

        await model.restartDevice()
        XCTAssertEqual(model.maintenanceState, .restarting)
        XCTAssertEqual(model.reconnectAttemptsForTesting, 0)

        try await waitUntil { await transport.reconnectIsWaiting }
        await clock.advance(by: .seconds(15))
        await transport.releaseReconnect()
        try await eventually { model.connectionStatus == .connected && model.maintenanceState == .idle }
        XCTAssertEqual(model.scanStartsForTesting, initialScanStarts)
        XCTAssertGreaterThanOrEqual(model.reconnectAttemptsForTesting, 1)
    }

    func testWriteErrorAfterExpectedDisconnectStillRecovers() async throws {
        let clock = TestDeviceClock()
        let transport = LifecycleTransport(reconnectAfterRestart: true, restartFailsAfterDisconnect: true, deferReconnect: true)
        let model = try await makeConnectedModel(transport, clock: clock)

        await model.restartDevice()
        XCTAssertEqual(model.maintenanceState, .restarting)
        try await waitUntil { await transport.reconnectIsWaiting }
        await clock.advance(by: .seconds(15))
        await transport.releaseReconnect()
        try await eventually { model.connectionStatus == .connected && model.maintenanceState == .idle }
    }

    func testRestartAwaitsAsynchronousDisconnectDeliveredAfterWriteError() async throws {
        let clock = TestDeviceClock()
        let transport = LifecycleTransport(
            reconnectAfterRestart: true,
            restartFailsAfterDisconnect: true,
            emitDisconnectAfterThrow: true,
            deferReconnect: true
        )
        let model = try await makeConnectedModel(transport, clock: clock)

        await model.restartDevice()

        XCTAssertEqual(model.maintenanceState, .restarting)
        try await waitUntil { await transport.reconnectIsWaiting }
        await clock.advance(by: .seconds(15))
        await transport.releaseReconnect()
        try await eventually { model.connectionStatus == .connected && model.maintenanceState == .idle }
    }

    func testRestartRecoveryExposesRetryAtThirtySeconds() async throws {
        let clock = TestDeviceClock()
        let transport = LifecycleTransport(reconnectAfterRestart: true, deferReconnect: true)
        let model = try await makeConnectedModel(transport, clock: clock)

        await model.restartDevice()
        try await waitUntil { await transport.reconnectIsWaiting }
        await clock.advance(by: .seconds(30))
        try await eventually { if case .restartFailed = model.maintenanceState { return true }; return false }
        XCTAssertEqual(model.route, .connected)
    }

    func testLateOldScopeDisconnectCannotTerminateRecoveredSession() async throws {
        let clock = TestDeviceClock()
        let transport = LifecycleTransport(reconnectAfterRestart: true)
        let model = try await makeConnectedModel(transport, clock: clock)

        await model.restartDevice()
        try await eventually { model.connectionStatus == .connected && model.maintenanceState == .idle }
        let scopes = await transport.scopes
        XCTAssertGreaterThanOrEqual(scopes.count, 2)
        await transport.emit(.disconnected(scopes[0], nil))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.connectionStatus, .connected)
        XCTAssertEqual(model.route, .connected)
    }
    func testRestartEntersRestartingAndReconnectsSamePeripheralWithoutScanning() async throws {
        let transport = LifecycleTransport(reconnectAfterRestart: true)
        let model = try await makeConnectedModel(transport)

        await model.restartDevice()

        XCTAssertEqual(model.maintenanceState, .restarting)
        try await eventually { model.connectionStatus == .connected && model.maintenanceState == .idle }
        let ids = await transport.connectedIDs
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids[0], ids[1])
        let scanStarts = await transport.scanStarts
        XCTAssertEqual(scanStarts, 1, "Restart reconnects the saved peripheral; it must not start a scan")
    }

    func testShutdownSuccessReturnsToScanAndDoesNotReconnect() async throws {
        let transport = LifecycleTransport(reconnectAfterRestart: false)
        let model = try await makeConnectedModel(transport)

        await model.shutdownDevice()

        try await eventually { model.route == .scan }
        XCTAssertEqual(model.maintenanceState, .idle)
        let reconnects = await transport.restartConnectCount
        let scanStarts = await transport.scanStarts
        XCTAssertEqual(reconnects, 0)
        XCTAssertEqual(scanStarts, 2, "Initial scan plus the explicit post-shutdown scan")
        let commandBytes = await transport.lastCommandBytes
        let disconnectPolicy = await transport.lastDisconnectPolicy
        XCTAssertEqual(commandBytes, Data([0x46, 0x4D]))
        XCTAssertEqual(disconnectPolicy, .successThenDisarmReconnect)
    }

    func testShutdownWriteFailureRetainsSelectionAndReportsOrdinaryFailure() async throws {
        let transport = LifecycleTransport(reconnectAfterRestart: false, shutdownFails: true)
        let model = try await makeConnectedModel(transport)

        await model.shutdownDevice()

        XCTAssertEqual(model.route, .connected)
        XCTAssertEqual(model.maintenanceState, .idle)
        guard case .disconnected(let message) = model.connectionStatus else {
            return XCTFail("Expected ordinary disconnected error presentation")
        }
        XCTAssertNotNil(message)
    }

    func testDemoRestartUsesSameUUIDAndShutdownReturnsToScan() async throws {
        let persistence = AppPersistence(defaults: UserDefaults(suiteName: "LifecycleDemo-\(UUID().uuidString)")!)
        persistence.onboardingComplete = true
        let model = AppModel(persistence: persistence, transportFactory: { DemoTransport(seed: 7) })
        model.enterDemo()
        try await eventually { model.connectionStatus == .connected }

        await model.restartDevice()
        try await eventually { model.connectionStatus == .connected && model.maintenanceState == .idle }
        XCTAssertEqual(model.route, .connected)

        await model.shutdownDevice()
        try await eventually { model.route == .scan }
        XCTAssertTrue(model.isDemo, "Demo badge remains visible after shutdown")
        XCTAssertEqual(model.connectionStatus, .disconnected(nil))
    }

    private func makeConnectedModel(_ transport: LifecycleTransport, clock: any DeviceClock = ContinuousDeviceClock()) async throws -> AppModel {
        let suite = "WattlineTests.SettingsLifecycle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let persistence = AppPersistence(defaults: defaults)
        persistence.onboardingComplete = true
        let model = AppModel(persistence: persistence, transportFactory: { transport }, maintenanceClock: clock)
        model.requestBluetoothAfterPriming()
        model.choose(DiscoveredDevice(id: LifecycleTransport.deviceID, localName: "Link-Power 2", rssi: -40, mode: .application))
        try await eventually { model.connectionStatus == .connected }
        return model
    }

    private func eventually(condition: @escaping () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            if ContinuousClock.now >= deadline { return XCTFail("Condition was not met before timeout") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitUntil(_ condition: @escaping () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            if ContinuousClock.now >= deadline { return XCTFail("Readiness barrier was not reached") }
            await Task.yield()
        }
    }
}

private actor LifecycleTransport: DeviceTransport {
    static let deviceID = UUID(uuidString: "2A7F650A-AB0A-4D25-90B1-9B71E4CF1A01")!
    nonisolated let events: AsyncStream<DeviceEvent>
    private let continuation: AsyncStream<DeviceEvent>.Continuation
    private let reconnectAfterRestart: Bool
    private let shutdownFails: Bool
    private let restartFails: Bool
    private let restartFailsAfterDisconnect: Bool
    private let emitDisconnectAfterThrow: Bool
    private let deferReconnect: Bool
    private(set) var connectedIDs: [UUID] = []
    private(set) var scanStarts = 0
    private(set) var restartConnectCount = 0
    private(set) var lastCommandBytes: Data?
    private(set) var lastDisconnectPolicy: ExpectedDisconnectPolicy?
    private(set) var scopes: [DeviceConnectionScope] = []
    private var activeScope: DeviceConnectionScope?
    private var reconnectWaiter: CheckedContinuation<Void, Never>?
    var reconnectIsWaiting: Bool { reconnectWaiter != nil }

    init(reconnectAfterRestart: Bool, shutdownFails: Bool = false, restartFails: Bool = false, restartFailsAfterDisconnect: Bool = false, emitDisconnectAfterThrow: Bool = false, deferReconnect: Bool = false) {
        let pair = AsyncStream<DeviceEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
        self.reconnectAfterRestart = reconnectAfterRestart
        self.shutdownFails = shutdownFails
        self.restartFails = restartFails
        self.restartFailsAfterDisconnect = restartFailsAfterDisconnect
        self.emitDisconnectAfterThrow = emitDisconnectAfterThrow
        self.deferReconnect = deferReconnect
    }

    func startScan() async throws { scanStarts += 1 }
    func stopScan() async {}
    func makeConnectionScope(for id: UUID) async -> DeviceConnectionScope {
        DeviceConnectionScope(peripheralID: id, sessionID: UUID())
    }
    func connect(to id: UUID, scope: DeviceConnectionScope) async throws {
        if connectedIDs.count > 0, deferReconnect {
            await withCheckedContinuation { continuation in reconnectWaiter = continuation }
        }
        connectedIDs.append(id)
        if connectedIDs.count > 1 { restartConnectCount += 1 }
        activeScope = scope
        scopes.append(scope)
        continuation.yield(.connected(scope))
    }
    func releaseReconnect() { reconnectWaiter?.resume(); reconnectWaiter = nil }
    func emit(_ event: DeviceEvent) { continuation.yield(event) }
    func disconnect() async {}
    func perform(_ command: DeviceCommand) async throws -> CommandOutcome {
        lastCommandBytes = command.request.bytes
        lastDisconnectPolicy = command.disconnectPolicy
        if command.disconnectPolicy == .successThenDisarmReconnect {
            if shutdownFails { throw TransportFailure(message: "FM write failed") }
            if let activeScope { continuation.yield(.disconnected(activeScope, nil)) }
            return .sent
        }
        if command.disconnectPolicy == .successThenReconnect, reconnectAfterRestart {
            if emitDisconnectAfterThrow {
                let scope = activeScope
                if restartFailsAfterDisconnect {
                    if let scope {
                        Task { [continuation] in
                            try? await Task.sleep(for: .milliseconds(20))
                            continuation.yield(.disconnected(scope, nil))
                        }
                    }
                    throw TransportFailure(message: "restart write failed after disconnect")
                }
                if let scope { continuation.yield(.disconnected(scope, nil)) }
            } else {
                if let activeScope { continuation.yield(.disconnected(activeScope, nil)) }
                if restartFailsAfterDisconnect { throw TransportFailure(message: "restart write failed after disconnect") }
            }
        } else if command.disconnectPolicy == .successThenReconnect, restartFails {
            throw TransportFailure(message: "restart write failed")
        }
        return .sent
    }
    func refreshTelemetry() async throws {}
    func synchronizeDeviceTime() async throws {}
    func readDeviceTimeIfSupported() async throws -> Date? { nil }
}

private actor TestDeviceClock: DeviceClock {
    private struct Sleeper {
        let id: UUID
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Error>
    }
    private var elapsed: Duration = .zero
    private var sleepers: [Sleeper] = []
    var sleeperCount: Int { sleepers.count }

    var now: DeviceTimestamp { elapsed }

    func sleep(for duration: Duration) async throws {
        let deadline = elapsed + duration
        if elapsed >= deadline { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelSleeper(id) }
        }
    }

    private func cancelSleeper(_ id: UUID) {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return }
        sleepers.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    func advance(by duration: Duration) {
        elapsed += duration
        let ready = sleepers.partition { $0.deadline <= elapsed }
        sleepers = Array(ready.partitioned)
        for sleeper in ready.ready { sleeper.continuation.resume() }
    }
}

private extension Array {
    func partition(by predicate: (Element) -> Bool) -> (ready: [Element], partitioned: [Element]) {
        reduce(into: (ready: [Element](), partitioned: [Element]())) { result, element in
            if predicate(element) { result.ready.append(element) } else { result.partitioned.append(element) }
        }
    }
}
