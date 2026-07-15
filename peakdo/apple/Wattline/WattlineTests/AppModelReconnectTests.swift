import Foundation
@testable import Wattline
import WattlineCore
import XCTest

@MainActor
final class AppModelReconnectTests: XCTestCase {
    func testConnectedEventPersistsPeripheralAndAdvertisedNameWithoutInventingIdentity() async throws {
        let fixture = makeFixture(onboardingComplete: true)
        let id = UUID()
        let device = DiscoveredDevice(id: id, localName: "Link-Power 2", rssi: -45, mode: .application)
        let model = AppModel(persistence: fixture.persistence, transportFactory: { fixture.transport })

        await fixture.transport.emit(.discovered(device))
        await fixture.transport.emit(.connected(id))

        try await eventually { fixture.persistence.lastSuccessfulPeripheralID == id }
        let identity = try XCTUnwrap(model.knownDevices[id])
        XCTAssertEqual(identity.advertisedName, "Link-Power 2")
        XCTAssertNil(identity.deviceInformationName)
        XCTAssertNil(identity.macAddress)
    }

    func testReturningUserReconnectsStoredPeripheralWithoutScanningOnSuccess() async throws {
        let id = UUID()
        let fixture = makeFixture(onboardingComplete: true, lastPeripheralID: id, connectResult: .success)
        _ = AppModel(persistence: fixture.persistence, transportFactory: { fixture.transport })

        try await eventually { await fixture.transport.connectedIDs == [id] }
        let scanCount = await fixture.transport.scanCount
        XCTAssertEqual(scanCount, 0)
    }

    func testReturningUserFallsBackToScanWhenReconnectFails() async throws {
        let id = UUID()
        let fixture = makeFixture(onboardingComplete: true, lastPeripheralID: id, connectResult: .failure)
        let model = AppModel(persistence: fixture.persistence, transportFactory: { fixture.transport })

        try await eventually { await fixture.transport.scanCount == 1 }
        let connectedIDs = await fixture.transport.connectedIDs
        XCTAssertEqual(connectedIDs, [id])
        XCTAssertEqual(model.route, .scan)
        XCTAssertEqual(model.scanMessage, "Couldn’t reconnect. Scanning for nearby devices.")
    }

    func testFirstLaunchDoesNotConstructTransport() {
        let fixture = makeFixture(onboardingComplete: false)
        var constructionCount = 0

        let model = AppModel(persistence: fixture.persistence) {
            constructionCount += 1
            return fixture.transport
        }

        XCTAssertEqual(model.route, .onboarding)
        XCTAssertEqual(constructionCount, 0)
    }

    func testDemoConnectionDoesNotReplaceLastRealPeripheral() async throws {
        let realID = UUID()
        let fixture = makeFixture(onboardingComplete: false, lastPeripheralID: realID)
        let model = AppModel(persistence: fixture.persistence, transportFactory: { fixture.transport })

        model.enterDemo()
        try await eventually { model.connectionStatus == .connected }
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(fixture.persistence.lastSuccessfulPeripheralID, realID)
    }

    private func makeFixture(
        onboardingComplete: Bool,
        lastPeripheralID: UUID? = nil,
        connectResult: RecordingTransport.ConnectResult = .success
    ) -> (persistence: AppPersistence, transport: RecordingTransport) {
        let suiteName = "WattlineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let persistence = AppPersistence(defaults: defaults)
        persistence.onboardingComplete = onboardingComplete
        persistence.lastSuccessfulPeripheralID = lastPeripheralID
        return (persistence, RecordingTransport(connectResult: connectResult))
    }

    private func eventually(
        timeout: Duration = .seconds(2),
        condition: @escaping () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            if clock.now >= deadline { XCTFail("Condition was not met before timeout"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor RecordingTransport: DeviceTransport {
    enum ConnectResult { case success, failure }
    enum Failure: Error { case reconnectFailed }

    nonisolated let events: AsyncStream<DeviceEvent>
    private let continuation: AsyncStream<DeviceEvent>.Continuation
    private let connectResult: ConnectResult
    private(set) var connectedIDs: [UUID] = []
    private(set) var scanCount = 0

    init(connectResult: ConnectResult) {
        let pair = AsyncStream<DeviceEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
        self.connectResult = connectResult
    }

    func emit(_ event: DeviceEvent) { continuation.yield(event) }
    func startScan() async throws { scanCount += 1 }
    func stopScan() async {}

    func connect(to id: UUID) async throws {
        connectedIDs.append(id)
        if connectResult == .failure { throw Failure.reconnectFailed }
        continuation.yield(.connected(id))
    }

    func disconnect() async {}
    func perform(_ command: DeviceCommand) async throws -> CommandOutcome { .sent }
    func refreshTelemetry() async throws {}
}
