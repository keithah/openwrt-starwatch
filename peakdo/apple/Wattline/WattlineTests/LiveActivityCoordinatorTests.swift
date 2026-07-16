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

    func testAuthorizationDeniedDoesNotPoisonLaterActivityUpdates() async throws {
        let adapter = RecordingActivityAdapter(failRequests: true)
        let coordinator = LiveActivityCoordinator(adapter: adapter)
        await coordinator.consume(snapshot(status: .charging, observedAt: 1), now: Date(timeIntervalSince1970: 1), preferences: .init())
        await coordinator.consume(snapshot(level: 89, status: .charging, observedAt: 2), now: Date(timeIntervalSince1970: 2), preferences: .init())
        let events = await adapter.events
        XCTAssertEqual(events.map(\.0), [.request, .update])
        XCTAssertEqual(events[1].1?.level, 89)
    }

    func testContentStateMapsAllFieldsAndAggregatesPortOutput() async throws {
        let adapter = RecordingActivityAdapter()
        let coordinator = LiveActivityCoordinator(adapter: adapter)
        let observed = Date(timeIntervalSince1970: 42)
        let s = snapshot(level: 73, status: .discharging, observedAt: 42, batteryPower: 999,
                         dc: .init(enabled: true, status: .discharging, voltage: 12, current: 2, power: 30),
                         typeC: .init(enabled: true, status: .discharging, voltage: 9, current: 2, power: 18))
        await coordinator.consume(s, now: observed, preferences: .init())
        let state = await adapter.events[0].1
        XCTAssertEqual(state?.level, 73)
        XCTAssertEqual(state?.status, PowerFlow.discharging.rawValue)
        XCTAssertEqual(state?.runtimeSeconds, 7_200)
        XCTAssertEqual(state?.aggregateOutputWatts, 48)
        XCTAssertEqual(state?.observedAt, observed)
        XCTAssertEqual(state?.isConnected, true)
    }

    func testDisconnectedObservedAtStaysAtFirstDisconnectThroughHold() async throws {
        let adapter = RecordingActivityAdapter()
        let coordinator = LiveActivityCoordinator(adapter: adapter)
        await coordinator.consume(snapshot(status: .discharging, observedAt: 1), now: Date(timeIntervalSince1970: 1), preferences: .init())
        await coordinator.consume(snapshot(status: .discharging, connection: .disconnected, observedAt: 10), now: Date(timeIntervalSince1970: 10), preferences: .init())
        await coordinator.consume(snapshot(status: .discharging, connection: .disconnected, observedAt: 20), now: Date(timeIntervalSince1970: 20), preferences: .init())
        let events = await adapter.events
        let updates = events.compactMap { $0.1 }
        XCTAssertEqual(updates.dropFirst().map(\.observedAt), [Date(timeIntervalSince1970: 10), Date(timeIntervalSince1970: 10)])
    }

    func testIdleEndsAfterFiveMinutes() async throws {
        let adapter = RecordingActivityAdapter()
        let coordinator = LiveActivityCoordinator(adapter: adapter)
        await coordinator.consume(snapshot(status: .charging, observedAt: 1), now: Date(timeIntervalSince1970: 1), preferences: .init())
        await coordinator.consume(snapshot(status: .idle, observedAt: 2), now: Date(timeIntervalSince1970: 2), preferences: .init())
        await coordinator.consume(snapshot(status: .idle, observedAt: 302), now: Date(timeIntervalSince1970: 302), preferences: .init())
        let events = await adapter.events
        XCTAssertEqual(events.map(\.0), [.request, .end])
    }

    private func snapshot(level: Int = 90, status: PowerFlow, connection: SharedConnectionState = .live, observedAt: TimeInterval,
                          batteryPower: Double = 42, dc: SharedPortSnapshot? = nil, typeC: SharedPortSnapshot? = nil) -> SharedDeviceSnapshot {
        SharedDeviceSnapshot(peripheralID: UUID(), featuresRawValue: 0, battery: .init(enabled: true, status: status, isFull: false, maxCapacity: 100, capacity: 90, level: UInt8(level), voltage: 12, current: 3, power: batteryPower, remainingMinutes: 120), dc: dc, typeC: typeC, connection: connection, observedAt: Date(timeIntervalSince1970: observedAt))
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
