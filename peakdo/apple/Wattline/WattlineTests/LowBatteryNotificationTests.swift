import Foundation
import XCTest
import WattlineCore
@testable import Wattline

final class LowBatteryNotificationTests: XCTestCase {
    func testAuthorizationIsRequestedOnlyWhenEnabledAndOnlyOnce() async {
        let recorder = NotificationRecorder()
        let coordinator = await MainActor.run { LowBatteryNotificationCoordinator(notifications: recorder) }
        let initial = await recorder.authorizationRequests
        XCTAssertEqual(initial, 0)
        await coordinator.setEnabled(true)
        await coordinator.setEnabled(true)
        let requests = await recorder.authorizationRequests
        let categories = await recorder.categories.count
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(categories, 1)
    }

    func testDCActionIsStructurallyAbsentWithoutCapability() async {
        let recorder = NotificationRecorder()
        let coordinator = await MainActor.run { LowBatteryNotificationCoordinator(notifications: recorder, capabilities: { DeviceCapabilities(features: []) }) }
        await coordinator.setEnabled(true)
        let included = await recorder.lastIncludedDCAction
        XCTAssertFalse(included)
    }

    func testActionDoesNotSucceedOnWriteAckBeforeTelemetry() async {
        let recorder = NotificationRecorder()
        let id = UUID()
        let transport = ReplayTransport(steps: [.reply(bytes: Data([Command.dcControl.rawValue, 0x81, 0]))])
        let broker = Wattline.DeviceOperationBroker()
        let session = DeviceSession(transport: transport)
        await broker.attach(.init(generation: 1, peripheralID: id, transport: transport, session: session))
        await broker.markConnected(peripheralID: id, generation: 1)
        let snapshot = SharedDeviceSnapshot(peripheralID: id, featuresRawValue: FeatureFlags.dcControl.rawValue, battery: nil, dc: .init(enabled: true, status: .idle, voltage: 0, current: 0, power: 0), typeC: nil, connection: .live, observedAt: Date())
        let coordinator = await MainActor.run {
            LowBatteryNotificationCoordinator(notifications: recorder, broker: broker, peripheralID: { id }, snapshot: { snapshot }, capabilities: { DeviceCapabilities(features: [.dcControl]) }, telemetryTimeout: .milliseconds(20))
        }
        let result = await coordinator.handleAction(identifier: "WATTLINE_TURN_OFF_DC")
        XCTAssertEqual(result, .timedOut)
    }
}

actor NotificationRecorder: NotificationCenterAdapter {
    private(set) var authorizationRequests = 0
    private(set) var categories = [Bool]()
    private(set) var lastIncludedDCAction = false
    func requestAuthorization() async throws -> Bool { authorizationRequests += 1; return true }
    func registerLowBatteryCategory(includeDCAction: Bool) async { categories.append(includeDCAction); lastIncludedDCAction = includeDCAction }
    func postLowBattery(level: Int, threshold: Int) async throws {}
}
