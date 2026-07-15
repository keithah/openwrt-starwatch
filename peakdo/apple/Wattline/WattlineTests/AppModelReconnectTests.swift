import Foundation
@testable import Wattline
import WattlineCore
import XCTest

@MainActor
final class AppModelReconnectTests: XCTestCase {
    func testAppDeclaresGlobalDarkAppearance() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "UIUserInterfaceStyle") as? String, "Dark")
    }

    func testHandshakeAppliesAuthoritativeCapabilitiesAndPersistsFullIdentity() async throws {
        let fixture = makeFixture(onboardingComplete: true)
        let id = UUID()
        let model = AppModel(persistence: fixture.persistence, transportFactory: { fixture.transport })
        let snapshot = DeviceIdentitySnapshot(
            peripheralID: id,
            advertisedName: "Link-Power 2",
            mode: .application,
            modelNumber: "BP4SL3V2",
            hardwareRevision: "V5#0305",
            otaFirmwareRevision: "2.0.2",
            appFirmwareRevision: "1.4.9",
            cid: 0x0305,
            rawFeatures: 0,
            macAddress: "DC:04:5A:EB:72:2B",
            capabilities: DeviceCapabilities(features: [])
        )

        await fixture.transport.emit(.handshakeCompleted(snapshot))
        await fixture.transport.emit(.connected(id))

        try await eventually { model.state.identity == snapshot }
        XCTAssertEqual(model.capabilities.features.rawValue, 0, "empty FEATURES stays authoritative")
        let persisted = try XCTUnwrap(model.knownDevices[id])
        XCTAssertEqual(persisted.advertisedName, "Link-Power 2")
        XCTAssertEqual(persisted.deviceInformationName, "BP4SL3V2")
        XCTAssertEqual(persisted.modelNumber, "BP4SL3V2")
        XCTAssertEqual(persisted.hardwareRevision, "V5#0305")
        XCTAssertEqual(persisted.otaFirmwareRevision, "2.0.2")
        XCTAssertEqual(persisted.appFirmwareRevision, "1.4.9")
        XCTAssertEqual(persisted.cid, 0x0305)
        XCTAssertEqual(persisted.rawFeatures, 0)
        XCTAssertEqual(persisted.macAddress, "DC:04:5A:EB:72:2B")
        XCTAssertEqual(persisted.isOTAMode, false)
        XCTAssertEqual(model.route, .connected)
    }

    func testRestoredOTAModeHandshakeNeverRoutesConnectedDashboard() async throws {
        let fixture = makeFixture(onboardingComplete: false)
        let id = UUID()
        let model = AppModel(persistence: fixture.persistence, transportFactory: { fixture.transport })
        model.requestBluetoothAfterPriming()
        let snapshot = DeviceIdentitySnapshot(
            peripheralID: id,
            advertisedName: "PeakDo-OTA",
            mode: .ota,
            cid: 0x0305,
            capabilities: CapabilityResolver.resolve(features: nil, cid: 0x0305, model: nil)
        )

        await fixture.transport.emit(.handshakeCompleted(snapshot))
        await fixture.transport.emit(.connected(id))

        try await eventually {
            let scanCount = await fixture.transport.scanCount
            let disconnectCount = await fixture.transport.disconnectCount
            return model.state.identity == snapshot
                && model.otaRecoveryDevice?.id == id
                && disconnectCount == 1
                && scanCount >= 2
        }
        XCTAssertEqual(model.capabilities.features.rawValue, 0)
        XCTAssertEqual(model.route, .scan)
        XCTAssertNotEqual(model.connectionStatus, .connected)
        XCTAssertEqual(model.knownDevices[id]?.isOTAMode, true)
    }

    func testLegacyKnownDeviceIdentityStillDecodes() throws {
        let suiteName = "WattlineTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let id = UUID()
        let legacyJSON = """
        [{"identifier":"\(id.uuidString)","identity":{"name":"Link-Power 1"}}]
        """
        defaults.set(try XCTUnwrap(legacyJSON.data(using: .utf8)), forKey: AppPersistence.knownDevicesKey)

        let identity = try XCTUnwrap(AppPersistence(defaults: defaults).loadKnownDevices()[id])

        XCTAssertEqual(identity.advertisedName, "Link-Power 1")
        XCTAssertEqual(identity.name, "Link-Power 1")
        XCTAssertNil(identity.rawFeatures)
        XCTAssertNil(identity.isOTAMode)
    }

    func testAttachingRealTransportClearsDemoScopedPresentationState() {
        let fixture = makeFixture(onboardingComplete: false)
        let model = AppModel(persistence: fixture.persistence, transportFactory: { fixture.transport })
        model.enterDemo()
        model.limits[.global] = .watts140
        model.pendingLimits = [.global]
        model.toastMessage = "old"
        model.demoChargerConnected = true

        model.requestBluetoothAfterPriming()

        XCTAssertEqual(model.capabilities.features.rawValue, 0)
        XCTAssertNil(model.state.identity)
        XCTAssertTrue(model.limits.isEmpty)
        XCTAssertTrue(model.pendingLimits.isEmpty)
        XCTAssertFalse(model.limitsLoading)
        XCTAssertNil(model.toastMessage)
        XCTAssertFalse(model.demoChargerConnected)
    }

    func testReplacingTransportExplicitlyDisconnectsPreviousTransport() async throws {
        let first = RecordingTransport(connectResult: .success)
        let second = RecordingTransport(connectResult: .success)
        var transports: [RecordingTransport] = [first, second]
        let suiteName = "WattlineTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let model = AppModel(persistence: AppPersistence(defaults: defaults)) {
            transports.removeFirst()
        }

        model.requestBluetoothAfterPriming()
        model.requestBluetoothAfterPriming()

        try await eventually { await first.disconnectCount == 1 }
        let secondDisconnectCount = await second.disconnectCount
        XCTAssertEqual(secondDisconnectCount, 0)
    }

    func testReturningToScanExplicitlyDisconnectsCurrentTransport() async throws {
        let fixture = makeFixture(onboardingComplete: false)
        let model = AppModel(persistence: fixture.persistence, transportFactory: { fixture.transport })
        model.requestBluetoothAfterPriming()

        model.returnToScan()

        try await eventually { await fixture.transport.disconnectCount == 1 }
        XCTAssertEqual(model.route, .scan)
    }

    func testSetFailureUsesSuccessfulRecoveryGetAsConfirmedLimit() async {
        let transport = MutationTransport(steps: [
            .failure,
            .reply(Data([0x02, 0x80, 0x00, PowerLimitLevel.watts100.rawValue])),
        ])
        let model = makeMutationModel(transport: transport)
        model.limits[.global] = .watts65
        let originalRevision = model.limitsRevision

        await model.setLimit(.global, level: .watts140)

        XCTAssertEqual(model.limits[.global], .watts100)
        XCTAssertGreaterThan(model.limitsRevision, originalRevision)
        XCTAssertNotNil(model.toastMessage)
    }

    func testSetAndBothGetFailuresRestoreLastConfirmedLimit() async {
        let transport = MutationTransport(steps: [
            .reply(Data([0x02, 0x81, 0x00])),
            .failure,
            .failure,
        ])
        let model = makeMutationModel(transport: transport)
        model.limits[.global] = .watts65
        let originalRevision = model.limitsRevision

        await model.setLimit(.global, level: .watts140)

        XCTAssertEqual(model.limits[.global], .watts65)
        XCTAssertGreaterThan(model.limitsRevision, originalRevision)
        XCTAssertNotNil(model.toastMessage)
    }

    func testDeleteAndBothGetFailuresRestoreLastConfirmedLimit() async {
        let transport = MutationTransport(steps: [
            .reply(Data([0x02, 0x82, 0x00])),
            .failure,
            .failure,
        ])
        let model = makeMutationModel(transport: transport)
        model.limits[.output] = .watts45
        let originalRevision = model.limitsRevision

        await model.resetLimit(.output)

        XCTAssertEqual(model.limits[.output], .watts45)
        XCTAssertGreaterThan(model.limitsRevision, originalRevision)
        XCTAssertNotNil(model.toastMessage)
    }

    func testMalformedSetFollowUpRunsRecoveryAndRollsBackConfirmedLimit() async {
        let transport = MutationTransport(steps: [
            .reply(Data([0x02, 0x81, 0x00])),
            .reply(Data([0x02, 0x80, 0x00, 0x7F])),
            .failure,
        ])
        let model = makeMutationModel(transport: transport)
        model.limits[.global] = .watts65
        let originalRevision = model.limitsRevision

        await model.setLimit(.global, level: .watts140)

        XCTAssertEqual(model.limits[.global], .watts65)
        XCTAssertGreaterThan(model.limitsRevision, originalRevision)
        XCTAssertTrue(model.pendingLimits.isEmpty)
        XCTAssertNotNil(model.toastMessage)
    }

    func testMalformedInitialLimitGetShowsErrorAndStopsLoading() async {
        let transport = MutationTransport(steps: [
            .reply(Data([0x02, 0x80, 0x00])),
            .reply(Data([0x02, 0x80, 0x00, PowerLimitLevel.watts45.rawValue])),
            .reply(Data([0x02, 0x80, 0x00, PowerLimitLevel.watts60.rawValue])),
            .reply(Data([0x02, 0x80, 0xFF])),
        ])
        let model = makeMutationModel(transport: transport)
        model.capabilities = DeviceCapabilities(features: [.usbPowerLimit])

        await model.loadLimits()

        XCTAssertFalse(model.limitsLoading)
        XCTAssertNil(model.limits[.global])
        XCTAssertEqual(model.limits[.input], .watts45)
        XCTAssertEqual(model.limits[.output], .watts60)
        XCTAssertNil(model.limits[.runtime])
        XCTAssertTrue(model.limitReadFailures.contains(.global))
        XCTAssertFalse(model.limitReadFailures.contains(.runtime))
        XCTAssertNotNil(model.toastMessage)
    }

    func testHandshakeUsesResolvedCIDAndModelCapabilityVariants() async throws {
        let fixture = makeFixture(onboardingComplete: true)
        let model = AppModel(persistence: fixture.persistence, transportFactory: { fixture.transport })
        let lpp = DeviceIdentitySnapshot(
            peripheralID: UUID(), advertisedName: "Link-Power Plus", mode: .application,
            modelNumber: "BP4SL3", cid: 0x0201,
            capabilities: CapabilityResolver.resolve(features: nil, cid: 0x0201, model: "BP4SL3")
        )

        await fixture.transport.emit(.handshakeCompleted(lpp))
        try await eventually { model.capabilities == lpp.capabilities }
        XCTAssertTrue(model.capabilities.hasDCPort)
        XCTAssertFalse(model.capabilities.hasBattery)

        let lp2 = DeviceIdentitySnapshot(
            peripheralID: UUID(), advertisedName: "Link-Power 2", mode: .application,
            modelNumber: "BP4SL3V2",
            capabilities: CapabilityResolver.resolve(features: nil, cid: nil, model: "BP4SL3V2")
        )
        await fixture.transport.emit(.handshakeCompleted(lp2))
        try await eventually { model.capabilities == lp2.capabilities }
        XCTAssertTrue(model.capabilities.hasBattery)
        XCTAssertTrue(model.capabilities.hasUSBPort)
    }

    func testPortMutationImmediatelyPublishesPendingAndTelemetryConfirmation() async throws {
        let reply = Data([Command.dcControl.rawValue, Action.set.rawValue | 0x80, 0])
        let transport = MutationTransport(steps: [.suspendedReply(reply)])
        let model = makeMutationModel(transport: transport)
        let off = try DCPortStatus(frame: Data([0, 0, 0, 0, 0, 0, 0, 0]))
        await transport.emit(.dc(off, timestamp: .zero))
        try await eventually { model.state.dc == off }

        model.setDC(true)
        try await eventually { model.state.pendingMutations.count == 1 }
        XCTAssertEqual(model.state.dc, off)

        await transport.releaseSuspendedReply()
        let on = try DCPortStatus(frame: Data([1, 0, 0, 0, 0, 0, 0, 0]))
        await transport.emit(.dc(on, timestamp: .seconds(1)))
        try await eventually { model.state.dc == on && model.state.pendingMutations.isEmpty }
        XCTAssertNil(model.state.lastError)
    }

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

    private func makeMutationModel(transport: MutationTransport) -> AppModel {
        let suiteName = "WattlineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let persistence = AppPersistence(defaults: defaults)
        let model = AppModel(persistence: persistence, transportFactory: { transport })
        model.requestBluetoothAfterPriming()
        return model
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

private actor MutationTransport: DeviceTransport {
    enum Step: Sendable { case reply(Data), suspendedReply(Data), failure }
    enum Failure: Error { case expected }

    nonisolated let events: AsyncStream<DeviceEvent>
    private let continuation: AsyncStream<DeviceEvent>.Continuation
    private var steps: [Step]
    private var suspendedReply: (Data, CheckedContinuation<Data, Never>)?

    init(steps: [Step]) {
        let pair = AsyncStream<DeviceEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
        self.steps = steps
    }

    func startScan() async throws {}
    func stopScan() async {}
    func connect(to id: UUID) async throws { continuation.yield(.connected(id)) }
    func disconnect() async {}
    func refreshTelemetry() async throws {}
    func emit(_ event: DeviceEvent) { continuation.yield(event) }
    func releaseSuspendedReply() {
        guard let suspendedReply else { return }
        self.suspendedReply = nil
        suspendedReply.1.resume(returning: suspendedReply.0)
    }

    func perform(_ command: DeviceCommand) async throws -> CommandOutcome {
        guard !steps.isEmpty else { throw Failure.expected }
        switch steps.removeFirst() {
        case let .reply(data): return .reply(try command.validate(data))
        case let .suspendedReply(data):
            let resumed = await withCheckedContinuation { continuation in
                suspendedReply = (data, continuation)
            }
            return .reply(try command.validate(resumed))
        case .failure: throw Failure.expected
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
    private(set) var disconnectCount = 0

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

    func disconnect() async { disconnectCount += 1 }
    func perform(_ command: DeviceCommand) async throws -> CommandOutcome { .sent }
    func refreshTelemetry() async throws {}
}
