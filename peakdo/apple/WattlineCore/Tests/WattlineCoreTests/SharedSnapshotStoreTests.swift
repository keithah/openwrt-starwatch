import Foundation
import XCTest
@testable import WattlineCore

final class SharedSnapshotStoreTests: XCTestCase {
    func testRoundTripAndSpecialPowerValues() async throws {
        let backend = SpyStore()
        let store = SharedSnapshotStore(backend: backend)
        let battery = SharedBatterySnapshot(enabled: true, status: .discharging, isFull: false, maxCapacity: .infinity, capacity: 42, level: 42, voltage: 12, current: -.infinity, power: .nan, remainingMinutes: 90)
        let dc = SharedPortSnapshot(enabled: false, status: .idle, voltage: 0, current: .infinity, power: -.infinity, bypassOn: true, mode: nil, isDCInput: false)
        let typeC = SharedPortSnapshot(enabled: true, status: .charging, voltage: 20, current: 3, power: 60, bypassOn: nil, mode: .output, isDCInput: nil)
        let date = Date(timeIntervalSince1970: 123.456)
        let id = UUID()
        let snapshot = SharedDeviceSnapshot(peripheralID: id, featuresRawValue: 0xA5A5, battery: battery, dc: dc, typeC: typeC, connection: .reconnecting, observedAt: date)
        try await store.write(snapshot)
        let read = await store.read()
        XCTAssertEqual(read?.peripheralID, id)
        XCTAssertEqual(read?.featuresRawValue, 0xA5A5)
        XCTAssertEqual(read?.connection, .reconnecting)
        XCTAssertEqual(read?.observedAt, date)
        XCTAssertEqual(read?.battery?.enabled, true)
        XCTAssertEqual(read?.battery?.status, .discharging)
        XCTAssertEqual(read?.battery?.isFull, false)
        XCTAssertTrue(read?.battery?.maxCapacity.isInfinite == true && read?.battery?.maxCapacity.sign == .plus)
        XCTAssertEqual(read?.battery?.capacity, 42)
        XCTAssertEqual(read?.battery?.level, 42)
        XCTAssertEqual(read?.battery?.voltage, 12)
        XCTAssertTrue(read?.battery?.current.isInfinite == true && read?.battery?.current.sign == .minus)
        XCTAssertTrue(read?.battery?.power.isNaN == true)
        XCTAssertEqual(read?.battery?.remainingMinutes, 90)
        XCTAssertEqual(read?.dc?.enabled, false)
        XCTAssertEqual(read?.dc?.bypassOn, true)
        XCTAssertEqual(read?.dc?.isDCInput, false)
        XCTAssertTrue(read?.dc?.current.isInfinite == true && read?.dc?.current.sign == .plus)
        XCTAssertTrue(read?.dc?.power.isInfinite == true && read?.dc?.power.sign == .minus)
        XCTAssertEqual(read?.typeC?.mode, .output)
        XCTAssertEqual(read?.typeC?.power, 60)
        XCTAssertEqual(backend.setCount, 1)
    }

    func testAbsentCorruptAndUnknownSchemaReturnNil() async throws {
        let backend = SpyStore()
        let store = SharedSnapshotStore(backend: backend)
        let absent = await store.read()
        XCTAssertNil(absent)
        backend.bytes = Data([0x01, 0x02])
        let corrupt = await store.read()
        XCTAssertNil(corrupt)
        let valid = SharedSnapshotEnvelope(snapshot: makeSnapshot())
        let encoded = try JSONEncoder().encode(valid)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["schemaVersion"] = 99
        backend.bytes = try JSONSerialization.data(withJSONObject: object)
        let unknown = await store.read()
        XCTAssertNil(unknown)
    }

    func testClearAtomicallyRemovesKey() async throws {
        let backend = SpyStore()
        let store = SharedSnapshotStore(backend: backend)
        try await store.write(makeSnapshot())
        let beforeClear = await store.read()
        XCTAssertNotNil(beforeClear)
        await store.clear()
        let afterClear = await store.read()
        XCTAssertNil(afterClear)
        XCTAssertEqual(backend.removeCount, 1)
    }

    private func makeSnapshot() -> SharedDeviceSnapshot {
        SharedDeviceSnapshot(peripheralID: UUID(), featuresRawValue: 1, battery: nil, dc: nil, typeC: nil, connection: .live, observedAt: Date(timeIntervalSince1970: 1))
    }
}

private final class SpyStore: SnapshotKeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    var bytes: Data? { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
    private var value: Data?
    var setCount = 0
    var removeCount = 0
    func data(forKey key: String) -> Data? { bytes }
    func set(_ data: Data, forKey key: String) { lock.withLock { value = data; setCount += 1 } }
    func removeValue(forKey key: String) { lock.withLock { value = nil; removeCount += 1 } }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() }
}
