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
        let model = AppModel(persistence: fixture.persistence, transportFactory: { fixture.transport })

        try await eventually {
            await fixture.transport.connectedIDs == [id]
                && model.route == .connected
                && model.connectionStatus == .connected
                && fixture.persistence.lastSuccessfulPeripheralID == id
        }
        let scanCount = await fixture.transport.scanCount
        XCTAssertEqual(scanCount, 0)
    }

    func testReturningUserFailureFallbackWinsForBothDisconnectOrderings() async throws {
        for ordering in RecordingTransport.FailureOrdering.allCases {
            let id = UUID()
            let fixture = makeFixture(
                onboardingComplete: true,
                lastPeripheralID: id,
                connectResult: .failure(ordering)
            )
            let model = AppModel(persistence: fixture.persistence, transportFactory: { fixture.transport })

            try await eventually { await fixture.transport.scanCount == 1 }
            await fixture.transport.releasePostThrowDisconnectIfNeeded()
            if ordering == .afterThrow {
                try await eventually {
                    model.connectionStatus == .disconnected("reconnect failed")
                }
            }

            XCTAssertEqual(model.route, .scan, "ordering: \(ordering)")
            XCTAssertEqual(model.scanMessage, "Couldn’t reconnect. Scanning for nearby devices.")
            XCTAssertEqual(fixture.persistence.lastSuccessfulPeripheralID, id)

            model.retryConnection()
            let connectedIDs = await fixture.transport.connectedIDs
            let scanCount = await fixture.transport.scanCount
            XCTAssertEqual(connectedIDs, [id], "cleared attempt must not retry: \(ordering)")
            XCTAssertEqual(scanCount, 1, "fallback scan starts once: \(ordering)")
        }
    }

    func testSupersededStoredReconnectCannotMutateDemoSession() async throws {
        let storedID = UUID()
        let fixture = makeFixture(
            onboardingComplete: true,
            lastPeripheralID: storedID,
            connectResult: .suspended
        )
        let model = AppModel(persistence: fixture.persistence, transportFactory: { fixture.transport })
        try await eventually { await fixture.transport.connectedIDs == [storedID] }

        model.enterDemo()
        await fixture.transport.failSuspendedConnect(ordering: .beforeThrow)
        await model.waitForSupersededLifecycleOperation()

        XCTAssertTrue(model.isDemo)
        XCTAssertEqual(model.route, .connected)
        XCTAssertEqual(model.connectionStatus, .connected)
        XCTAssertEqual(fixture.persistence.lastSuccessfulPeripheralID, storedID)
        let scanCount = await fixture.transport.scanCount
        XCTAssertEqual(scanCount, 0)
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
        model.scanMessage = "waiting for Demo connected event"

        model.enterDemo()
        try await eventually { model.scanMessage == nil }

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
    enum FailureOrdering: CaseIterable { case beforeThrow, afterThrow }
    enum ConnectResult { case success, failure(FailureOrdering), suspended }
    enum Failure: Error { case reconnectFailed }

    nonisolated let events: AsyncStream<DeviceEvent>
    private let continuation: AsyncStream<DeviceEvent>.Continuation
    private let connectResult: ConnectResult
    private var suspendedConnect: CheckedContinuation<Void, Error>?
    private var postThrowDisconnectPending = false
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
        switch connectResult {
        case .success:
            continuation.yield(.connected(id))
        case .failure(.beforeThrow):
            continuation.yield(.disconnected(TransportFailure(message: "reconnect failed")))
            throw Failure.reconnectFailed
        case .failure(.afterThrow):
            postThrowDisconnectPending = true
            throw Failure.reconnectFailed
        case .suspended:
            try await withCheckedThrowingContinuation { suspendedConnect = $0 }
        }
    }

    func releasePostThrowDisconnectIfNeeded() {
        guard postThrowDisconnectPending else { return }
        postThrowDisconnectPending = false
        continuation.yield(.disconnected(TransportFailure(message: "reconnect failed")))
    }

    func failSuspendedConnect(ordering: FailureOrdering) {
        guard let suspendedConnect else { return }
        self.suspendedConnect = nil
        if ordering == .beforeThrow {
            continuation.yield(.disconnected(TransportFailure(message: "stale reconnect failed")))
        } else {
            postThrowDisconnectPending = true
        }
        suspendedConnect.resume(throwing: Failure.reconnectFailed)
    }

    func disconnect() async {}
    func perform(_ command: DeviceCommand) async throws -> CommandOutcome { .sent }
    func refreshTelemetry() async throws {}
}
