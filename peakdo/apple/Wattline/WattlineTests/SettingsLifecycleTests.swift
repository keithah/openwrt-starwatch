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

    func testOverlappingRestartsResolveReplacedWaiterExactlyOnce() async throws {
        let clock = TestDeviceClock()
        let transport = LifecycleTransport(
            reconnectAfterRestart: true,
            deferRestartPerform: true
        )
        let model = try await makeConnectedModel(transport, clock: clock)
        let firstFinished = CompletionProbe()
        let secondFinished = CompletionProbe()

        let first = Task {
            await model.restartDevice()
            await firstFinished.mark()
        }
        try await waitUntil { await transport.restartPerformCount == 1 }
        let firstOperationID = try XCTUnwrap(model.restartOperationIDForTesting)

        let second = Task {
            await model.restartDevice()
            await secondFinished.mark()
        }
        do {
            try await waitUntil {
                guard let currentOperationID = model.restartOperationIDForTesting else { return false }
                return currentOperationID != firstOperationID
            }
        } catch {
            await transport.releaseRestartPerform(1)
            _ = try? await waitUntil { await transport.restartPerformCount == 2 }
            await transport.releaseRestartPerform(2)
            _ = try? await waitUntil { await transport.pendingDisconnectScope != nil }
            await transport.releasePendingDisconnect()
            first.cancel()
            second.cancel()
            throw error
        }
        XCTAssertEqual(model.maintenanceState, .restarting)

        await transport.releaseRestartPerform(1)
        try await waitUntil { await transport.restartPerformCount == 2 }
        await transport.releaseRestartPerform(2)
        try await waitUntil { await transport.pendingDisconnectScope != nil }
        await transport.releasePendingDisconnect()

        do {
            try await waitUntil {
                let didFinishFirst = await firstFinished.isMarked
                let didFinishSecond = await secondFinished.isMarked
                return didFinishFirst && didFinishSecond
            }
        } catch {
            first.cancel()
            second.cancel()
            throw error
        }
        try await waitUntil {
            model.connectionStatus == .connected && model.maintenanceState == .idle
        }
    }

    func testCancelingRestartCallerRemovesItsWaiterWithoutAdvancingClock() async throws {
        let clock = TestDeviceClock()
        let transport = LifecycleTransport(reconnectAfterRestart: true)
        let model = try await makeConnectedModel(transport, clock: clock)
        let finished = CompletionProbe()
        let restart = Task {
            await model.restartDevice()
            await finished.mark()
        }

        try await waitUntil { await transport.pendingDisconnectScope != nil }
        try await waitUntil { await clock.sleeperCount == 1 }
        restart.cancel()

        do {
            try await waitUntil {
                let didFinish = await finished.isMarked
                let sleeperCount = await clock.sleeperCount
                return didFinish && sleeperCount == 0
            }
        } catch {
            await clock.advance(by: .seconds(1))
            await restart.value
            throw error
        }
        XCTAssertEqual(model.maintenanceState, .idle)
    }

    func testReplacingGenerationCancelsOldRestartTimeoutWithoutClobberingHealthySession() async throws {
        let clock = TestDeviceClock()
        let transport = LifecycleTransport(reconnectAfterRestart: true)
        let model = try await makeConnectedModel(transport, clock: clock)
        let finished = CompletionProbe()
        let oldRestart = Task {
            await model.restartDevice()
            await finished.mark()
        }

        try await waitUntil { await transport.pendingDisconnectScope != nil }
        try await waitUntil { await clock.sleeperCount == 1 }
        model.enterDemo()
        try await waitUntil {
            guard model.connectionStatus == .connected,
                  model.maintenanceState == .idle,
                  model.isDemo
            else { return false }
            return await model.deviceOperationBroker.hasConnectedContext
        }

        await clock.advance(by: .seconds(1))
        try await waitUntil { await finished.isMarked }
        await oldRestart.value

        XCTAssertEqual(model.connectionStatus, .connected)
        XCTAssertEqual(model.maintenanceState, .idle)
        XCTAssertEqual(model.route, .connected)
        XCTAssertTrue(model.isDemo)
        let hasConnectedContext = await model.deviceOperationBroker.hasConnectedContext
        XCTAssertTrue(hasConnectedContext)
    }
    func testRestartWriteFailureWhileStillConnectedShowsRetryWithoutRecovery() async throws {
        let clock = TestDeviceClock()
        let transport = LifecycleTransport(reconnectAfterRestart: false, restartFails: true)
        let model = try await makeConnectedModel(transport, clock: clock)

        let restart = Task { await model.restartDevice() }
        try await waitUntil { await clock.sleeperCount == 1 }
        await clock.advance(by: .seconds(1))
        await restart.value

        try await waitUntil {
            if case .restartFailed = model.maintenanceState { return true }
            return false
        }
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

        try await restartAfterReleasingDisconnect(model, transport: transport)
        try await waitUntil { await transport.reconnectIsWaiting }
        XCTAssertEqual(model.maintenanceState, .restarting)
        XCTAssertEqual(model.reconnectAttemptsForTesting, 1)
        await clock.advance(by: .seconds(15))
        await transport.releaseReconnect()
        try await waitUntil {
            model.connectionStatus == .connected && model.maintenanceState == .idle
        }
        XCTAssertEqual(model.scanStartsForTesting, initialScanStarts)
        XCTAssertGreaterThanOrEqual(model.reconnectAttemptsForTesting, 1)
    }

    func testRestartReconnectOwnerAlonePresentsConnectedAfterBrokerReadiness() async throws {
        let clock = TestDeviceClock()
        let transport = LifecycleTransport(reconnectAfterRestart: true, deferReconnect: true)
        let completion = AsyncCallBarrier()
        let model = try await makeConnectedModel(
            transport,
            clock: clock,
            brokerCompletionBarrier: { await completion.waitIfHeld() }
        )
        let broker = model.deviceOperationBroker

        try await restartAfterReleasingDisconnect(model, transport: transport)
        try await waitUntil { await transport.deferredReconnectScopes.count == 1 }
        let deferredScopes = await transport.deferredReconnectScopes
        let reconnectScope = try XCTUnwrap(deferredScopes.first)

        await transport.emit(.connected(reconnectScope))
        await transport.emit(.discovered(LifecycleTransport.eventBarrierDevice))
        try await waitUntil {
            model.discoveredDevices.contains { $0.id == LifecycleTransport.eventBarrierDevice.id }
        }

        XCTAssertNotEqual(model.connectionStatus, .connected)
        XCTAssertEqual(model.maintenanceState, .restarting)
        let brokerReadyBeforeOwner = await broker.hasConnectedContext
        XCTAssertFalse(brokerReadyBeforeOwner)

        await completion.holdNext()
        await transport.releaseReconnect(scope: reconnectScope)
        try await waitUntil { await completion.isBlocked }
        XCTAssertNotEqual(model.connectionStatus, .connected)
        XCTAssertEqual(model.maintenanceState, .restarting)
        let brokerReadyWhileHeld = await broker.hasConnectedContext
        XCTAssertFalse(brokerReadyWhileHeld)

        await completion.release()
        try await waitUntil {
            guard model.connectionStatus == .connected,
                  model.maintenanceState == .idle
            else { return false }
            return await broker.hasConnectedContext
        }
    }

    func testWriteErrorAfterExpectedDisconnectStillRecovers() async throws {
        let clock = TestDeviceClock()
        let transport = LifecycleTransport(reconnectAfterRestart: true, restartFailsAfterDisconnect: true, deferReconnect: true)
        let model = try await makeConnectedModel(transport, clock: clock)

        try await restartAfterReleasingDisconnect(model, transport: transport)
        try await waitUntil { await transport.reconnectIsWaiting }
        XCTAssertEqual(model.maintenanceState, .restarting)
        await clock.advance(by: .seconds(15))
        await transport.releaseReconnect()
        try await waitUntil {
            model.connectionStatus == .connected && model.maintenanceState == .idle
        }
    }

    func testLateConnectedForRestartedScopeDoesNotCancelRestart() async throws {
        let clock = TestDeviceClock()
        let transport = LifecycleTransport(reconnectAfterRestart: true, deferReconnect: true)
        let model = try await makeConnectedModel(transport, clock: clock)
        let connectedScopes = await transport.scopes
        let originalScope = try XCTUnwrap(connectedScopes.first)
        let restart = Task { await model.restartDevice() }

        try await waitUntil { await transport.pendingDisconnectScope == originalScope }
        try await waitUntil { await clock.sleeperCount == 1 }
        let operationID = try XCTUnwrap(model.restartOperationIDForTesting)

        await transport.emit(.connected(originalScope))
        await transport.emit(.discovered(LifecycleTransport.eventBarrierDevice))
        try await waitUntil {
            model.discoveredDevices.contains { $0.id == LifecycleTransport.eventBarrierDevice.id }
        }

        guard model.maintenanceState == .restarting,
              model.restartOperationIDForTesting == operationID
        else {
            await clock.advance(by: .seconds(1))
            await restart.value
            return XCTFail("A late connected event for the pre-restart scope canceled the owned restart")
        }

        await transport.releasePendingDisconnect()
        await restart.value
        try await waitUntil { await transport.reconnectIsWaiting }
        await transport.releaseReconnect()
        try await waitUntil {
            model.connectionStatus == .connected && model.maintenanceState == .idle
        }
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
        let connectedScopes = await transport.scopes
        let originalScope = try XCTUnwrap(connectedScopes.first)

        let restart = Task { await model.restartDevice() }

        try await waitUntil { await transport.pendingDisconnectScope == originalScope }
        let staleScope = DeviceConnectionScope(
            peripheralID: originalScope.peripheralID,
            sessionID: UUID(uuidString: "361F1FE1-08FB-4963-A795-934823A7E4BC")!
        )
        XCTAssertNotEqual(staleScope, originalScope)
        await transport.emit(.disconnected(staleScope, nil))
        await transport.emit(.discovered(LifecycleTransport.eventBarrierDevice))
        try await waitUntil {
            model.discoveredDevices.contains { $0.id == LifecycleTransport.eventBarrierDevice.id }
        }
        let stillPendingScope = await transport.pendingDisconnectScope
        XCTAssertEqual(stillPendingScope, originalScope)
        XCTAssertEqual(model.reconnectAttemptsForTesting, 0)
        await transport.releasePendingDisconnect()
        await restart.value
        try await waitUntil { await transport.reconnectIsWaiting }
        XCTAssertEqual(model.maintenanceState, .restarting)
        await clock.advance(by: .seconds(15))
        await transport.releaseReconnect()
        try await waitUntil {
            model.connectionStatus == .connected && model.maintenanceState == .idle
        }
    }

    func testRestartRecoveryExposesRetryAtThirtySeconds() async throws {
        let clock = TestDeviceClock()
        let transport = LifecycleTransport(reconnectAfterRestart: true, deferReconnect: true)
        let model = try await makeConnectedModel(transport, clock: clock)

        try await restartAfterReleasingDisconnect(model, transport: transport)
        try await waitUntil { await transport.reconnectIsWaiting }
        try await waitUntil { await clock.sleeperCount == 1 }
        await clock.advance(by: .seconds(30))
        try await waitUntil {
            if case .restartFailed = model.maintenanceState { return true }
            return false
        }
        XCTAssertEqual(model.route, .connected)
    }

    func testRetryAfterRestartRecoveryTimeoutStartsFreshAttemptAndQuarantinesLateCompletion() async throws {
        let clock = TestDeviceClock()
        let transport = LifecycleTransport(reconnectAfterRestart: true, deferReconnect: true)
        let model = try await makeConnectedModel(transport, clock: clock)
        let broker = model.deviceOperationBroker

        try await restartAfterReleasingDisconnect(model, transport: transport)
        try await waitUntil { await transport.deferredReconnectScopes.count == 1 }
        let initialDeferredScopes = await transport.deferredReconnectScopes
        let oldScope = try XCTUnwrap(initialDeferredScopes.first)
        try await waitUntil { await clock.sleeperCount == 1 }

        await clock.advance(by: .seconds(30))
        try await waitUntil {
            if case .restartFailed = model.maintenanceState { return true }
            return false
        }

        await model.retryRestart()
        do {
            try await waitUntil {
                let pendingCount = await transport.deferredReconnectScopes.count
                return pendingCount == 2 && model.reconnectAttemptsForTesting == 2
            }
        } catch {
            await transport.releaseReconnect(scope: oldScope)
            throw error
        }
        let reconnectScopes = await transport.deferredReconnectScopes
        let freshScope = try XCTUnwrap(reconnectScopes.last)
        XCTAssertNotEqual(oldScope, freshScope)
        XCTAssertEqual(model.maintenanceState, .restarting)

        await transport.releaseReconnect(scope: oldScope)
        try await waitUntil { await transport.completedReconnectScopes.contains(oldScope) }
        await transport.emit(.discovered(LifecycleTransport.eventBarrierDevice))
        try await waitUntil {
            model.discoveredDevices.contains { $0.id == LifecycleTransport.eventBarrierDevice.id }
        }

        XCTAssertNotEqual(model.connectionStatus, .connected)
        XCTAssertEqual(model.maintenanceState, .restarting)
        let brokerReadyAfterStaleCompletion = await broker.hasConnectedContext
        XCTAssertFalse(brokerReadyAfterStaleCompletion)

        await transport.releaseReconnect(scope: freshScope)
        try await waitUntil {
            guard model.connectionStatus == .connected,
                  model.maintenanceState == .idle
            else { return false }
            return await broker.hasConnectedContext
        }
        XCTAssertEqual(model.reconnectAttemptsForTesting, 2)
    }

    func testLateOldScopeDisconnectCannotTerminateRecoveredSession() async throws {
        let clock = TestDeviceClock()
        let transport = LifecycleTransport(reconnectAfterRestart: true)
        let model = try await makeConnectedModel(transport, clock: clock)

        try await restartAfterReleasingDisconnect(model, transport: transport)
        try await waitUntil {
            model.connectionStatus == .connected && model.maintenanceState == .idle
        }
        try await waitUntil { await transport.scopes.count >= 2 }
        let scopes = await transport.scopes
        let oldScope = scopes[0]
        let recoveredScope = scopes[1]
        XCTAssertNotEqual(oldScope, recoveredScope)
        await transport.emit(.disconnected(oldScope, nil))
        await transport.emit(.discovered(LifecycleTransport.eventBarrierDevice))
        try await waitUntil {
            model.discoveredDevices.contains { $0.id == LifecycleTransport.eventBarrierDevice.id }
        }
        XCTAssertEqual(model.connectionStatus, .connected)
        XCTAssertEqual(model.route, .connected)
    }
    func testRestartEntersRestartingAndReconnectsSamePeripheralWithoutScanning() async throws {
        let transport = LifecycleTransport(reconnectAfterRestart: true, deferReconnect: true)
        let model = try await makeConnectedModel(transport)

        try await restartAfterReleasingDisconnect(model, transport: transport)

        try await waitUntil { await transport.reconnectIsWaiting }
        XCTAssertEqual(model.maintenanceState, .restarting)
        await transport.releaseReconnect()
        try await waitUntil {
            model.connectionStatus == .connected && model.maintenanceState == .idle
        }
        let ids = await transport.connectedIDs
        XCTAssertEqual(ids.count, 2)
        guard ids.count >= 2 else {
            XCTFail("restart should reconnect the saved peripheral")
            return
        }
        XCTAssertEqual(ids[0], ids[1])
        let scanStarts = await transport.scanStarts
        XCTAssertEqual(scanStarts, 1, "Restart reconnects the saved peripheral; it must not start a scan")
    }

    func testShutdownSuccessReturnsToScanAndDoesNotReconnect() async throws {
        let transport = LifecycleTransport(reconnectAfterRestart: false)
        let model = try await makeConnectedModel(transport)
        let initialScanStarts = await transport.scanStarts

        await model.shutdownDevice()

        try await waitUntil { model.route == .scan }
        try await waitUntil { await transport.scanStarts == initialScanStarts + 1 }
        XCTAssertEqual(model.maintenanceState, .idle)
        let reconnects = await transport.restartConnectCount
        let scanStarts = await transport.scanStarts
        XCTAssertEqual(reconnects, 0)
        XCTAssertEqual(scanStarts, initialScanStarts + 1, "Shutdown starts one explicit scan")
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
        let model = AppModel(persistence: persistence, transportFactory: { DemoTransport(seed: 7) })
        model.enterDemo()
        try await waitUntil {
            guard model.connectionStatus == .connected else { return false }
            return await model.deviceOperationBroker.hasConnectedContext
        }

        await model.restartDevice()
        try await waitUntil {
            model.connectionStatus == .connected && model.maintenanceState == .idle
        }
        XCTAssertEqual(model.route, .connected)

        await model.shutdownDevice()
        try await waitUntil { model.route == .scan }
        XCTAssertTrue(model.isDemo, "Demo badge remains visible after shutdown")
        XCTAssertEqual(model.connectionStatus, .disconnected(nil))
    }

    private func makeConnectedModel(
        _ transport: LifecycleTransport,
        clock: any DeviceClock = ContinuousDeviceClock(),
        brokerCompletionBarrier: @escaping AppModel.BrokerCompletionBarrier = {}
    ) async throws -> AppModel {
        let suite = "WattlineTests.SettingsLifecycle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let persistence = AppPersistence(defaults: defaults)
        let model = AppModel(
            persistence: persistence,
            transportFactory: { transport },
            brokerCompletionBarrier: brokerCompletionBarrier,
            maintenanceClock: clock
        )
        model.requestBluetoothAfterPriming()
        model.choose(DiscoveredDevice(id: LifecycleTransport.deviceID, localName: "Link-Power 2", rssi: -40, mode: .application))
        try await waitUntil {
            guard model.connectionStatus == .connected else { return false }
            return await model.deviceOperationBroker.hasConnectedContext
        }
        return model
    }

    private func restartAfterReleasingDisconnect(
        _ model: AppModel,
        transport: LifecycleTransport
    ) async throws {
        let restart = Task { await model.restartDevice() }
        try await waitUntil { await transport.pendingDisconnectScope != nil }
        XCTAssertEqual(model.reconnectAttemptsForTesting, 0)
        await transport.releasePendingDisconnect()
        await restart.value
    }

    private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard clock.now < deadline else { throw AsyncTestWaitError.timedOut }
            await Task.yield()
        }
    }
}

private actor LifecycleTransport: DeviceTransport {
    private struct DeferredReconnect {
        let scope: DeviceConnectionScope
        let continuation: CheckedContinuation<Void, Never>
    }

    static let deviceID = UUID(uuidString: "2A7F650A-AB0A-4D25-90B1-9B71E4CF1A01")!
    static let eventBarrierDevice = DiscoveredDevice(
        id: UUID(uuidString: "1018C163-43F8-4204-A389-FB04A046A4E5")!,
        localName: "Event barrier",
        rssi: -100,
        mode: .application
    )
    nonisolated let events: AsyncStream<DeviceEvent>
    private let continuation: AsyncStream<DeviceEvent>.Continuation
    private let reconnectAfterRestart: Bool
    private let shutdownFails: Bool
    private let restartFails: Bool
    private let restartFailsAfterDisconnect: Bool
    private let emitDisconnectAfterThrow: Bool
    private let deferReconnect: Bool
    private let deferRestartPerform: Bool
    private(set) var connectedIDs: [UUID] = []
    private(set) var scanStarts = 0
    private(set) var restartConnectCount = 0
    private(set) var lastCommandBytes: Data?
    private(set) var lastDisconnectPolicy: ExpectedDisconnectPolicy?
    private(set) var scopes: [DeviceConnectionScope] = []
    private var activeScope: DeviceConnectionScope?
    private var deferredReconnects: [DeferredReconnect] = []
    private(set) var completedReconnectScopes: [DeviceConnectionScope] = []
    private var restartPerformWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var pendingDisconnectScope: DeviceConnectionScope?
    private(set) var restartPerformCount = 0
    var reconnectIsWaiting: Bool { !deferredReconnects.isEmpty }
    var deferredReconnectScopes: [DeviceConnectionScope] {
        deferredReconnects.map(\.scope)
    }

    init(reconnectAfterRestart: Bool, shutdownFails: Bool = false, restartFails: Bool = false, restartFailsAfterDisconnect: Bool = false, emitDisconnectAfterThrow: Bool = false, deferReconnect: Bool = false, deferRestartPerform: Bool = false) {
        let pair = AsyncStream<DeviceEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
        self.reconnectAfterRestart = reconnectAfterRestart
        self.shutdownFails = shutdownFails
        self.restartFails = restartFails
        self.restartFailsAfterDisconnect = restartFailsAfterDisconnect
        self.emitDisconnectAfterThrow = emitDisconnectAfterThrow
        self.deferReconnect = deferReconnect
        self.deferRestartPerform = deferRestartPerform
    }

    func startScan() async throws { scanStarts += 1 }
    func stopScan() async {}
    func makeConnectionScope(for id: UUID) async -> DeviceConnectionScope {
        DeviceConnectionScope(peripheralID: id, sessionID: UUID())
    }
    func connect(to id: UUID, scope: DeviceConnectionScope) async throws {
        if connectedIDs.count > 0, deferReconnect {
            await withCheckedContinuation { continuation in
                deferredReconnects.append(.init(scope: scope, continuation: continuation))
            }
        }
        connectedIDs.append(id)
        if connectedIDs.count > 1 { restartConnectCount += 1 }
        activeScope = scope
        scopes.append(scope)
        continuation.yield(.connected(scope))
        if connectedIDs.count > 1 {
            completedReconnectScopes.append(scope)
        }
    }
    func releaseReconnect() {
        guard !deferredReconnects.isEmpty else { return }
        deferredReconnects.removeFirst().continuation.resume()
    }
    func releaseReconnect(scope: DeviceConnectionScope) {
        guard let index = deferredReconnects.firstIndex(where: { $0.scope == scope }) else { return }
        deferredReconnects.remove(at: index).continuation.resume()
    }
    func releaseRestartPerform(_ number: Int) {
        restartPerformWaiters.removeValue(forKey: number)?.resume()
    }
    func releasePendingDisconnect() {
        guard let pendingDisconnectScope else { return }
        self.pendingDisconnectScope = nil
        continuation.yield(.disconnected(pendingDisconnectScope, nil))
    }
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
        if command.disconnectPolicy == .successThenReconnect {
            restartPerformCount += 1
            let performNumber = restartPerformCount
            if deferRestartPerform {
                await withCheckedContinuation { continuation in
                    restartPerformWaiters[performNumber] = continuation
                }
            }
        }
        if command.disconnectPolicy == .successThenReconnect, reconnectAfterRestart {
            if emitDisconnectAfterThrow {
                let scope = activeScope
                if restartFailsAfterDisconnect {
                    pendingDisconnectScope = scope
                    throw TransportFailure(message: "restart write failed after disconnect")
                }
                pendingDisconnectScope = scope
            } else {
                pendingDisconnectScope = activeScope
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

private actor CompletionProbe {
    private(set) var isMarked = false

    func mark() {
        isMarked = true
    }
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
