import XCTest
@testable import WattlineCore

final class SnapshotPolicyTests: XCTestCase {
    private let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func snapshot(level: UInt8 = 50, status: PowerFlow = .idle, connection: SharedConnectionState = .live, dcEnabled: Bool = true, power: Double = 10) -> SharedDeviceSnapshot {
        SharedDeviceSnapshot(peripheralID: id, featuresRawValue: 1,
            battery: SharedBatterySnapshot(enabled: true, status: status, isFull: false, maxCapacity: 100, capacity: 50, level: level, voltage: 12, current: 1, power: power, remainingMinutes: 10),
            dc: SharedPortSnapshot(enabled: dcEnabled, status: .idle, voltage: 12, current: 1, power: power), typeC: nil,
            connection: connection, observedAt: t0)
    }

    func testMaterialChangesAndNoise() {
        let base = snapshot()
        XCTAssertEqual(SnapshotMaterialChangePolicy.evaluate(previous: base, next: snapshot(level: 51), lastWidgetReloadAt: nil, now: t0), SnapshotFanOutDecision(persist: true, updateActivity: true, reloadWidgets: true))
        XCTAssertTrue(SnapshotMaterialChangePolicy.evaluate(previous: base, next: snapshot(status: .charging), lastWidgetReloadAt: t0, now: t0.addingTimeInterval(1)).persist)
        XCTAssertTrue(SnapshotMaterialChangePolicy.evaluate(previous: base, next: snapshot(connection: .disconnected), lastWidgetReloadAt: t0, now: t0.addingTimeInterval(1)).persist)
        XCTAssertTrue(SnapshotMaterialChangePolicy.evaluate(previous: base, next: snapshot(dcEnabled: false), lastWidgetReloadAt: t0, now: t0.addingTimeInterval(1)).persist)
        XCTAssertTrue(SnapshotMaterialChangePolicy.evaluate(previous: base, next: snapshot(power: 12), lastWidgetReloadAt: t0, now: t0.addingTimeInterval(1)).persist)
        let noise = snapshot(power: 10.5)
        XCTAssertEqual(SnapshotMaterialChangePolicy.evaluate(previous: base, next: noise, lastWidgetReloadAt: t0, now: t0.addingTimeInterval(1)), SnapshotFanOutDecision(persist: false, updateActivity: false, reloadWidgets: false))
    }

    func testWidgetReloadThrottledAndStatusImmediate() {
        let base = snapshot()
        let steady = snapshot(level: 52)
        XCTAssertFalse(SnapshotMaterialChangePolicy.evaluate(previous: base, next: steady, lastWidgetReloadAt: t0, now: t0.addingTimeInterval(60)).reloadWidgets)
        XCTAssertTrue(SnapshotMaterialChangePolicy.evaluate(previous: base, next: steady, lastWidgetReloadAt: t0, now: t0.addingTimeInterval(901)).reloadWidgets)
        XCTAssertTrue(SnapshotMaterialChangePolicy.evaluate(previous: base, next: snapshot(status: .charging), lastWidgetReloadAt: t0, now: t0.addingTimeInterval(1)).reloadWidgets)
    }

    func testAgeUsesWallClockDate() {
        XCTAssertEqual(snapshot().age(now: t0.addingTimeInterval(42)), 42, accuracy: 0.001)
        XCTAssertEqual(snapshot().age(now: t0.addingTimeInterval(-1)), 0, accuracy: 0.001)
    }
}
