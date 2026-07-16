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

    func testAuthorizationDeniedIsObservableAndDoesNotEnable() async {
        let recorder = NotificationRecorder(authorization: false)
        let coordinator = await MainActor.run { LowBatteryNotificationCoordinator(notifications: recorder) }
        let result = await coordinator.setEnabled(true)
        let enabled = await MainActor.run { coordinator.isEnabled }
        XCTAssertEqual(result, .denied)
        XCTAssertFalse(enabled)
    }

    func testAuthorizationDeniedAllowsRetryAfterPermissionChanges() async {
        let recorder = ToggleableNotificationRecorder(authorization: false)
        let coordinator = await MainActor.run { LowBatteryNotificationCoordinator(notifications: recorder) }
        let first = await coordinator.setEnabled(true)
        XCTAssertEqual(first, .denied)
        await recorder.setAuthorization(true)
        let second = await coordinator.setEnabled(true)
        let enabled = await MainActor.run { coordinator.isEnabled }
        let requests = await recorder.authorizationRequests
        XCTAssertEqual(second, .success)
        XCTAssertTrue(enabled)
        XCTAssertEqual(requests, 2)
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

    func testActionSucceedsOnlyAfterAuthoritativeTelemetry() async {
        let recorder = NotificationRecorder()
        let id = UUID()
        let transport = ReplayTransport(steps: [.reply(bytes: Data([Command.dcControl.rawValue, 0x81, 0]))])
        let broker = Wattline.DeviceOperationBroker()
        let session = DeviceSession(transport: transport)
        await broker.attach(.init(generation: 1, peripheralID: id, transport: transport, session: session))
        await broker.markConnected(peripheralID: id, generation: 1)
        let box = await MainActor.run { SnapshotBox(snapshot: makeSnapshot(id: id, enabled: true)) }
        let coordinator = await MainActor.run {
            LowBatteryNotificationCoordinator(notifications: recorder, broker: broker, peripheralID: { id }, snapshot: { box.snapshot }, capabilities: { DeviceCapabilities(features: [.dcControl]) }, telemetryTimeout: .milliseconds(100))
        }
        Task { try? await Task.sleep(for: .milliseconds(20)); await MainActor.run { box.snapshot = makeSnapshot(id: id, enabled: false) } }
        let result = await coordinator.handleAction(identifier: "WATTLINE_TURN_OFF_DC")
        XCTAssertEqual(result, .success)
    }

    func testActionMapsUnsupportedAndUnavailableDistinctly() async {
        let recorder = NotificationRecorder()
        let unsupported = await MainActor.run { LowBatteryNotificationCoordinator(notifications: recorder, capabilities: { DeviceCapabilities(features: []) }) }
        let unsupportedResult = await unsupported.handleAction(identifier: "WATTLINE_TURN_OFF_DC")
        XCTAssertEqual(unsupportedResult, .unsupported)
        let unavailable = await MainActor.run { LowBatteryNotificationCoordinator(notifications: recorder, capabilities: { DeviceCapabilities(features: [.dcControl]) }) }
        let unavailableResult = await unavailable.handleAction(identifier: "WATTLINE_TURN_OFF_DC")
        XCTAssertEqual(unavailableResult, .unavailable)
    }

    func testAlreadyLowDischargingSampleAlertsAfterEnable() async {
        let recorder = NotificationRecorder()
        let coordinator = await MainActor.run { LowBatteryNotificationCoordinator(notifications: recorder) }
        _ = await coordinator.setEnabled(true)
        let id = UUID()
        let battery = SharedBatterySnapshot(enabled: true, status: .discharging, isFull: false, maxCapacity: 100, capacity: 19, level: 19, voltage: 0, current: 0, power: 0, remainingMinutes: 0)
        let snapshot = SharedDeviceSnapshot(peripheralID: id, featuresRawValue: 0, battery: battery, dc: nil, typeC: nil, connection: .live, observedAt: Date())
        await coordinator.receive(snapshot)
        let posts = await recorder.posts
        XCTAssertEqual(posts.count, 1)
    }
}

@MainActor final class SnapshotBox {
    var snapshot: SharedDeviceSnapshot
    init(snapshot: SharedDeviceSnapshot) { self.snapshot = snapshot }
}

@MainActor func makeSnapshot(id: UUID, enabled: Bool) -> SharedDeviceSnapshot {
    SharedDeviceSnapshot(peripheralID: id, featuresRawValue: FeatureFlags.dcControl.rawValue, battery: nil, dc: .init(enabled: enabled, status: .idle, voltage: 0, current: 0, power: 0), typeC: nil, connection: .live, observedAt: Date())
}

actor NotificationRecorder: NotificationCenterAdapter {
    let authorization: Bool
    private(set) var authorizationRequests = 0
    private(set) var categories = [Bool]()
    private(set) var lastIncludedDCAction = false
    private(set) var posts = [(Int, Int)]()
    init(authorization: Bool = true) { self.authorization = authorization }
    func requestAuthorization() async throws -> Bool { authorizationRequests += 1; return authorization }
    func registerLowBatteryCategory(includeDCAction: Bool) async { categories.append(includeDCAction); lastIncludedDCAction = includeDCAction }
    func postLowBattery(level: Int, threshold: Int) async throws { posts.append((level, threshold)) }
}

actor ToggleableNotificationRecorder: NotificationCenterAdapter {
    var authorization: Bool
    private(set) var authorizationRequests = 0
    init(authorization: Bool) { self.authorization = authorization }
    func setAuthorization(_ value: Bool) { authorization = value }
    func requestAuthorization() async throws -> Bool { authorizationRequests += 1; return authorization }
    func registerLowBatteryCategory(includeDCAction: Bool) async {}
    func postLowBattery(level: Int, threshold: Int) async throws {}
}
