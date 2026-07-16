import Foundation
import XCTest
import WattlineCore
@testable import Wattline

@MainActor
final class WattlineWidgetProviderTests: XCTestCase {
    func testPlaceholderUsesDeterministicSampleWithoutReadingStore() {
        let source = RecordingWidgetSnapshotSource(snapshot: nil)
        let provider = WattlineWidgetProvider(source: source)
        let entry = provider.placeholderEntry()
        XCTAssertEqual(entry.snapshot?.battery?.level, 84)
        XCTAssertEqual(source.readCount, 0)
    }

    func testSnapshotReadsStoreExactlyOnce() async {
        let snapshot = WidgetTestFixtures.snapshot(level: 62)
        let source = RecordingWidgetSnapshotSource(snapshot: snapshot)
        let provider = WattlineWidgetProvider(source: source)
        let entry = await provider.snapshotEntry()
        XCTAssertEqual(entry.snapshot, snapshot)
        XCTAssertEqual(source.readCount, 1)
    }

    func testTimelineReadsStoreExactlyOnceAndUnavailableIsRepresented() async {
        let source = RecordingWidgetSnapshotSource(snapshot: nil)
        let provider = WattlineWidgetProvider(source: source)
        let timeline = await provider.timelineEntry()
        XCTAssertNil(timeline.snapshot)
        XCTAssertEqual(source.readCount, 1)
    }

    func testPlaceholderNeverReadsBlockingSource() {
        let source = BlockingWidgetSnapshotSource()
        let provider = WattlineWidgetProvider(source: source)
        _ = provider.placeholderEntry()
        XCTAssertEqual(source.readCount, 0)
    }

    func testBatteryMissingSnapshotIsUnavailable() async {
        let source = RecordingWidgetSnapshotSource(snapshot: WidgetTestFixtures.snapshot(level: 50, battery: false))
        let entry = await WattlineWidgetProvider(source: source).snapshotEntry()
        XCTAssertNil(entry.snapshot)
    }
}

private final class RecordingWidgetSnapshotSource: @unchecked Sendable, WattlineWidgetSnapshotSource {
    let snapshot: SharedDeviceSnapshot?
    private(set) var readCount = 0
    init(snapshot: SharedDeviceSnapshot?) { self.snapshot = snapshot }
    func read() async -> SharedDeviceSnapshot? {
        readCount += 1
        return snapshot
    }
}

private final class BlockingWidgetSnapshotSource: @unchecked Sendable, WattlineWidgetSnapshotSource {
    private(set) var readCount = 0
    func read() async -> SharedDeviceSnapshot? { readCount += 1; fatalError("placeholder must not read") }
}

private enum WidgetTestFixtures {
    static func snapshot(level: UInt8, battery: Bool = true) -> SharedDeviceSnapshot {
        SharedDeviceSnapshot(
            peripheralID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            featuresRawValue: 0,
            battery: battery ? SharedBatterySnapshot(enabled: true, status: .idle, isFull: false, maxCapacity: 100, capacity: Double(level), level: level, voltage: 12, current: 0, power: 0, remainingMinutes: 90) : nil,
            dc: SharedPortSnapshot(enabled: true, status: .discharging, voltage: 12, current: 2, power: 24),
            typeC: SharedPortSnapshot(enabled: true, status: .idle, voltage: 9, current: 1, power: 9, mode: .output),
            connection: .live,
            observedAt: Date(timeIntervalSince1970: 100)
        )
    }
}
