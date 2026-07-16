import XCTest
@testable import WattlineCore

final class LiveActivityPolicyTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1_000_000)

    func snapshot(status: PowerFlow, connection: SharedConnectionState = .live, level: UInt8 = 50, observedAt: Date? = nil) -> SharedDeviceSnapshot {
        SharedDeviceSnapshot(peripheralID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!, featuresRawValue: 1,
            battery: SharedBatterySnapshot(enabled: true, status: status, isFull: false, maxCapacity: 100, capacity: 50, level: level, voltage: 12, current: 1, power: 12, remainingMinutes: 100),
            dc: nil, typeC: nil, connection: connection, observedAt: observedAt ?? base)
    }

    func testPreferenceGatesAndStart() {
        var p = LiveActivityPolicy()
        XCTAssertEqual(p.evaluate(snapshot: snapshot(status: .charging), now: base, preferences: .init(chargingEnabled: false)), .none)
        XCTAssertEqual(p.evaluate(snapshot: snapshot(status: .discharging), now: base, preferences: .init(dischargingEnabled: true)), .start(snapshot(status: .discharging)))
    }

    func testMaterialUpdateAndIdleBoundaries() {
        var p = LiveActivityPolicy()
        let initial = snapshot(status: .charging)
        XCTAssertEqual(p.evaluate(snapshot: initial, now: base, preferences: .init()), .start(initial))
        let changed = snapshot(status: .charging, level: 49, observedAt: base.addingTimeInterval(1))
        XCTAssertEqual(p.evaluate(snapshot: changed, now: base.addingTimeInterval(1), preferences: .init()), .update(changed))
        let idle = snapshot(status: .idle, observedAt: base.addingTimeInterval(2))
        XCTAssertEqual(p.evaluate(snapshot: idle, now: base.addingTimeInterval(2), preferences: .init()), .none)
        XCTAssertEqual(p.evaluate(snapshot: idle, now: base.addingTimeInterval(2 + 299), preferences: .init()), .none)
        XCTAssertEqual(p.evaluate(snapshot: idle, now: base.addingTimeInterval(2 + 300), preferences: .init()), .end)
    }

    func testDisconnectBoundariesAndRenewal() {
        var p = LiveActivityPolicy()
        let initial = snapshot(status: .charging)
        XCTAssertEqual(p.evaluate(snapshot: initial, now: base, preferences: .init()), .start(initial))
        let disconnected = snapshot(status: .charging, connection: .disconnected, observedAt: base.addingTimeInterval(1))
        XCTAssertEqual(p.evaluate(snapshot: disconnected, now: base.addingTimeInterval(1), preferences: .init()), .none)
        XCTAssertEqual(p.evaluate(snapshot: disconnected, now: base.addingTimeInterval(1 + 899), preferences: .init()), .none)
        XCTAssertEqual(p.evaluate(snapshot: disconnected, now: base.addingTimeInterval(1 + 900), preferences: .init()), .end)

        var r = LiveActivityPolicy()
        XCTAssertEqual(r.evaluate(snapshot: initial, now: base, preferences: .init()), .start(initial))
        let fresh = snapshot(status: .charging, level: 49, observedAt: base.addingTimeInterval(1))
        XCTAssertEqual(r.evaluate(snapshot: fresh, now: base.addingTimeInterval(7 * 3600 + 55 * 60), preferences: .init()), .renew(fresh))
    }
}
