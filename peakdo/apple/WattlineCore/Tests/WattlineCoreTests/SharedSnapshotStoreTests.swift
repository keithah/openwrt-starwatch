import Foundation
import XCTest
@testable import WattlineCore

final class SharedSnapshotStoreTests: XCTestCase {
    func testRoundTripAndSpecialPowerValues() async throws {
        let backend = SpyStore()
        let store = SharedSnapshotStore(backend: backend)
        let battery = SharedBatterySnapshot(enabled: true, status: .discharging, isFull: false, maxCapacity: 100, capacity: 42, level: 42, voltage: 12, current: 2, power: .nan, remainingMinutes: 90)
        let snapshot = SharedDeviceSnapshot(peripheralID: UUID(), featuresRawValue: 7, battery: battery, dc: nil, typeC: nil, connection: .live, observedAt: Date(timeIntervalSince1970: 123))
        try await store.write(snapshot)
        let read = await store.read()
        XCTAssertEqual(read?.peripheralID, snapshot.peripheralID)
        XCTAssertTrue(read?.battery?.power.isNaN == true)
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
        backend.bytes = Data("{\"schemaVersion\":99,\"snapshot\":{}}".utf8)
        let unknown = await store.read()
        XCTAssertNil(unknown)
    }

    func testClearAtomicallyRemovesKey() async {
        let backend = SpyStore()
        let store = SharedSnapshotStore(backend: backend)
        await store.clear()
        XCTAssertEqual(backend.removeCount, 1)
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
