import Foundation
import WattlineCore
import UserNotifications

protocol NotificationCenterAdapter: Sendable {
    func requestAuthorization() async throws -> Bool
    func registerLowBatteryCategory(includeDCAction: Bool) async
    func postLowBattery(level: Int, threshold: Int) async throws
}

enum NotificationActionResult: Equatable, Sendable {
    case success, denied, timedOut, unsupported, unavailable
}

struct SystemNotificationCenterAdapter: NotificationCenterAdapter {
    private let center = UNUserNotificationCenter.current()
    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }
    func registerLowBatteryCategory(includeDCAction: Bool) async {
        var actions: [UNNotificationAction] = []
        if includeDCAction { actions.append(UNNotificationAction(identifier: "WATTLINE_TURN_OFF_DC", title: "Turn off DC Port", options: [])) }
        let category = UNNotificationCategory(identifier: "WATTLINE_LOW_BATTERY", actions: actions, intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }
    func postLowBattery(level: Int, threshold: Int) async throws {
        let content = UNMutableNotificationContent()
        content.title = "Low battery"
        content.body = "Battery is at (level)% (threshold (threshold)%)."
        content.categoryIdentifier = "WATTLINE_LOW_BATTERY"
        let request = UNNotificationRequest(identifier: "wattline.low-battery", content: content, trigger: nil)
        try await center.add(request)
    }
}

@MainActor
final class LowBatteryNotificationCoordinator {
    private let notifications: any NotificationCenterAdapter
    private let broker: DeviceOperationBroker?
    private let peripheralID: @MainActor () -> UUID?
    private let snapshot: @MainActor () -> SharedDeviceSnapshot?
    private let capabilities: @MainActor () -> DeviceCapabilities
    private let telemetryTimeout: Duration
    private var policy = LowBatteryPolicy()
    private(set) var isEnabled = false
    private var authorizationRequested = false

    init(
        notifications: any NotificationCenterAdapter = SystemNotificationCenterAdapter(),
        broker: DeviceOperationBroker? = nil,
        peripheralID: @escaping @MainActor () -> UUID? = { nil },
        snapshot: @escaping @MainActor () -> SharedDeviceSnapshot? = { nil },
        capabilities: @escaping @MainActor () -> DeviceCapabilities = { DeviceCapabilities(features: []) },
        telemetryTimeout: Duration = .seconds(10)
    ) {
        self.notifications = notifications; self.broker = broker; self.peripheralID = peripheralID; self.snapshot = snapshot; self.capabilities = capabilities; self.telemetryTimeout = telemetryTimeout
    }

    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        if enabled {
            guard !authorizationRequested else { isEnabled = true; return }
            authorizationRequested = true
            guard (try? await notifications.requestAuthorization()) == true else { return }
            isEnabled = true
            await notifications.registerLowBatteryCategory(includeDCAction: capabilities().hasDCControl)
        } else { isEnabled = false; policy = LowBatteryPolicy() }
    }

    func receive(_ snapshot: SharedDeviceSnapshot) async {
        guard isEnabled, let battery = snapshot.battery else { return }
        if policy.evaluate(level: Int(battery.level), status: battery.status, enabled: true, hasBattery: true) == .alert {
            try? await notifications.postLowBattery(level: Int(battery.level), threshold: policy.threshold)
        }
    }

    func handleAction(identifier: String) async -> NotificationActionResult {
        guard identifier == "WATTLINE_TURN_OFF_DC" else { return .unsupported }
        guard capabilities().hasDCControl else { return .unsupported }
        guard let broker, let id = peripheralID() else { return .unavailable }
        do {
            _ = try await broker.withConnection(to: id, timeout: .seconds(10)) { context in
                try await context.session.perform(.setDC(false))
            }
        } catch is DeviceOperationBroker.BrokerError { return .unavailable }
          catch { return .unavailable }

        let deadline = ContinuousClock.now + telemetryTimeout
        while ContinuousClock.now < deadline {
            if snapshot()?.dc?.enabled == false { return .success }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return .timedOut
    }
}
