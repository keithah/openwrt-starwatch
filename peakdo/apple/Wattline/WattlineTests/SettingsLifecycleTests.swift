import Foundation
import XCTest
import WattlineCore
@testable import Wattline

@MainActor
final class SettingsLifecycleTests: XCTestCase {
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
        XCTAssertFalse(model.isDemo, "Returning to scan must leave the demo session")
    }

    private func makeConnectedModel(_ transport: LifecycleTransport) async throws -> AppModel {
        let suite = "WattlineTests.SettingsLifecycle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let persistence = AppPersistence(defaults: defaults)
        persistence.onboardingComplete = true
        let model = AppModel(persistence: persistence, transportFactory: { transport })
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
}

private actor LifecycleTransport: DeviceTransport {
    static let deviceID = UUID(uuidString: "2A7F650A-AB0A-4D25-90B1-9B71E4CF1A01")!
    nonisolated let events: AsyncStream<DeviceEvent>
    private let continuation: AsyncStream<DeviceEvent>.Continuation
    private let reconnectAfterRestart: Bool
    private let shutdownFails: Bool
    private(set) var connectedIDs: [UUID] = []
    private(set) var scanStarts = 0
    private(set) var restartConnectCount = 0
    private var activeScope: DeviceConnectionScope?

    init(reconnectAfterRestart: Bool, shutdownFails: Bool = false) {
        let pair = AsyncStream<DeviceEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
        self.reconnectAfterRestart = reconnectAfterRestart
        self.shutdownFails = shutdownFails
    }

    func startScan() async throws { scanStarts += 1 }
    func stopScan() async {}
    func makeConnectionScope(for id: UUID) async -> DeviceConnectionScope {
        DeviceConnectionScope(peripheralID: id, sessionID: UUID())
    }
    func connect(to id: UUID, scope: DeviceConnectionScope) async throws {
        connectedIDs.append(id)
        if connectedIDs.count > 1 { restartConnectCount += 1 }
        activeScope = scope
        continuation.yield(.connected(scope))
    }
    func disconnect() async {}
    func perform(_ command: DeviceCommand) async throws -> CommandOutcome {
        if command.disconnectPolicy == .successThenDisarmReconnect {
            if shutdownFails { throw TransportFailure(message: "FM write failed") }
            if let activeScope { continuation.yield(.disconnected(activeScope, nil)) }
            return .sent
        }
        if command.disconnectPolicy == .successThenReconnect, reconnectAfterRestart {
            if let activeScope { continuation.yield(.disconnected(activeScope, nil)) }
            let scope = await makeConnectionScope(for: Self.deviceID)
            try await connect(to: Self.deviceID, scope: scope)
        }
        return .sent
    }
    func refreshTelemetry() async throws {}
    func synchronizeDeviceTime() async throws {}
    func readDeviceTimeIfSupported() async throws -> Date? { nil }
}
