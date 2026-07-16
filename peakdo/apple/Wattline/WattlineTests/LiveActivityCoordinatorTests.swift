import Foundation
import XCTest
import WattlineCore
@testable import Wattline

@MainActor
final class LiveActivityCoordinatorTests: XCTestCase {
    func testStartAndSemanticUpdate() async throws {
        let adapter = RecordingActivityAdapter()
        let coordinator = LiveActivityCoordinator(adapter: adapter)
        let first = snapshot(status: .charging, observedAt: 1)
        await coordinator.consume(first, now: Date(timeIntervalSince1970: 1), preferences: .init())
        let second = snapshot(level: 81, status: .charging, observedAt: 2)
        await coordinator.consume(second, now: Date(timeIntervalSince1970: 2), preferences: .init())
        let events = await adapter.events
        XCTAssertEqual(events.map(\.0), [.request, .update])
        XCTAssertEqual(events[1].1?.level, 81)
    }

    func testDisconnectEndAndAdapterErrorsDoNotThrow() async throws {
        let adapter = RecordingActivityAdapter(failRequests: true)
        let coordinator = LiveActivityCoordinator(adapter: adapter)
        await coordinator.consume(snapshot(status: .discharging, observedAt: 1), now: Date(timeIntervalSince1970: 1), preferences: .init())
        await coordinator.consume(snapshot(status: .discharging, connection: .disconnected, observedAt: 2), now: Date(timeIntervalSince1970: 2 + 15 * 60), preferences: .init())
        let events = await adapter.events
        XCTAssertEqual(events.map { $0.0 }, [.request, .update, .end])
    }

    private func snapshot(level: Int = 90, status: PowerFlow, connection: SharedConnectionState = .live, observedAt: TimeInterval) -> SharedDeviceSnapshot {
        SharedDeviceSnapshot(peripheralID: UUID(), featuresRawValue: 0, battery: .init(enabled: true, status: status, isFull: false, maxCapacity: 100, capacity: 90, level: UInt8(level), voltage: 12, current: 3, power: 42, remainingMinutes: 120), dc: nil, typeC: nil, connection: connection, observedAt: Date(timeIntervalSince1970: observedAt))
    }
}

private actor RecordingActivityAdapter: LiveActivityAdapter {
    enum Event: Equatable { case request, update, end }
    private(set) var events: [(Event, WattlineActivityAttributes.ContentState?)] = []
    let failRequests: Bool
    init(failRequests: Bool = false) { self.failRequests = failRequests }
    func request(state: WattlineActivityAttributes.ContentState) async throws { events.append((.request, state)); if failRequests { throw NSError(domain: "test", code: 1) } }
    func update(state: WattlineActivityAttributes.ContentState) async throws { events.append((.update, state)) }
    func end() async { events.append((.end, nil)) }
}
