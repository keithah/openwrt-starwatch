import Foundation
import CoreBluetooth
@testable import Wattline
import WattlineCore
import XCTest

private func testScope(_ peripheralID: UUID, sessionID: UUID? = nil) -> DeviceConnectionScope {
    DeviceConnectionScope(peripheralID: peripheralID, sessionID: sessionID ?? peripheralID)
}

@MainActor
final class AppModelReconnectTests: XCTestCase {
    func testPermissionDeniedAndRestrictedFailuresUseSettingsRecoveryPath() {
        XCTAssertEqual(
            BluetoothFailurePolicy.issue(authorization: .denied, errorDescription: "scan failed"),
            .deniedOrRestricted
        )
        XCTAssertEqual(
            BluetoothFailurePolicy.issue(authorization: .restricted, errorDescription: "scan failed"),
            .deniedOrRestricted
        )
        XCTAssertEqual(
            BluetoothFailurePolicy.issue(authorization: .allowedAlways, errorDescription: "radio unavailable"),
            .unavailable("radio unavailable")
        )
    }

    func testDeviceRowPresentationShowsSignalNewDeviceAndKnownMAC() {
        let id = UUID()
        let device = DiscoveredDevice(id: id, localName: "Link-Power 2", rssi: -60, mode: .application)
        let newPresentation = DeviceRowPresentation(device: device, identity: nil)
        XCTAssertEqual(newPresentation.secondaryText, "New device")
        XCTAssertEqual(newPresentation.signalStrength, 3)
        XCTAssertFalse(newPresentation.isOTARecovery)

        let identity = AppModel.CachedIdentity(
            advertisedName: "Link-Power 2",
            deviceInformationName: "BP4SL3V2",
            macAddress: "DC:04:5A:EB:72:2B"
        )
        let knownPresentation = DeviceRowPresentation(device: device, identity: identity)
        XCTAssertEqual(knownPresentation.secondaryText, "BP4SL3V2 · DC:04:5A:EB:72:2B")

        let ota = DiscoveredDevice(id: id, localName: "PeakDo-OTA", rssi: -90, mode: .ota)
        let otaPresentation = DeviceRowPresentation(device: ota, identity: identity)
        XCTAssertTrue(otaPresentation.isOTARecovery)
        XCTAssertEqual(otaPresentation.signalStrength, 1)
    }

    func testOTAModeHandshakePreservesApplicationResolvedFeatures() async throws {
        let fixture = makeFixture(onboardingComplete: false)
        let model = AppModel(persistence: fixture.persistence, transportFactory: { fixture.transport })
        model.requestBluetoothAfterPriming()
        let id = UUID()
        model.choose(.init(id: id, localName: "Link-Power 2", rssi: -40, mode: .application))
        try await eventually { await fixture.transport.currentScope() != nil }
        let currentApplicationScope = await fixture.transport.currentScope()
        let applicationScope = try XCTUnwrap(currentApplicationScope)
        await fixture.transport.emit(.handshakeCompleted(makeIdentity(id: id, features: 0x7FFF), scope: applicationScope))
        try await eventually {
            fixture.persistence.loadPersistedDeviceState(for: id)?.resolvedFeaturesRawValue == 0x7FFF
        }

        let ota = DeviceIdentitySnapshot(
            peripheralID: id,
            advertisedName: "PeakDo-OTA",
            mode: .ota,
            capabilities: DeviceCapabilities(features: [])
        )
        model.choose(.init(id: id, localName: "PeakDo-OTA", rssi: -40, mode: .ota))
        await fixture.transport.emit(.handshakeCompleted(ota, scope: applicationScope))
        try await eventually { model.otaRecoveryDevice?.id == id }

        XCTAssertEqual(
            fixture.persistence.loadPersistedDeviceState(for: id)?.resolvedFeaturesRawValue,
            0x7FFF
        )
    }

    func testPersistenceRoundTripsNaNTelemetryAndRejectsMalformedJSON() throws {
        let suiteName = "WattlineTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let persistence = AppPersistence(defaults: defaults)
        let id = UUID()
        let identity = AppModel.CachedIdentity(
            advertisedName: "Link-Power 2",
            deviceInformationName: nil,
            macAddress: nil
        )
        persistence.saveKnownDevices([id: identity])
        var frame = Data(repeating: 0, count: 16)
        frame[8] = 0xFF
        frame[9] = 0x07
        let battery = try BatteryStatus(frame: frame)
        XCTAssertTrue(battery.voltage.isNaN)

        XCTAssertTrue(persistence.saveTelemetry(
            battery: PersistedObservation(value: battery, observedAt: Date(timeIntervalSince1970: 1)),
            dc: nil,
            typeC: nil,
            for: id
        ))
        let restored = try XCTUnwrap(persistence.loadPersistedDeviceState(for: id)?.battery?.value)
        XCTAssertTrue(restored.voltage.isNaN)

        defaults.set(Data("{not-json".utf8), forKey: AppPersistence.knownDevicesKey)
        XCTAssertTrue(AppPersistence(defaults: defaults).loadKnownDevices().isEmpty)
    }

    func testPersistenceDropsOnlyCorruptDeviceRecords() throws {
        let suiteName = "WattlineTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let validID = UUID()
        let identity = AppModel.CachedIdentity(
            advertisedName: "Link-Power 2",
            deviceInformationName: "BP4SL3V2",
            macAddress: "DC:04:5A:EB:72:2B"
        )
        let validRecord = AppModel.KnownDevice(identifier: validID, identity: identity)
        let validObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(validRecord))
        let corruptObject: [String: Any] = [
            "identifier": "not-a-uuid",
            "identity": ["advertisedName": 42],
        ]
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "devices": [validObject, corruptObject],
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: payload), forKey: AppPersistence.knownDevicesKey)

        let loaded = AppPersistence(defaults: defaults).loadKnownDevices()

        XCTAssertEqual(loaded, [validID: identity])
    }

    func testPersistenceWritesVersionedDeviceEnvelope() throws {
        let suiteName = "WattlineTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let persistence = AppPersistence(defaults: defaults)
        let id = UUID()
        let identity = AppModel.CachedIdentity(
            advertisedName: "Link-Power 2",
            deviceInformationName: nil,
            macAddress: nil
        )

        persistence.saveKnownDevices([id: identity])

        let data = try XCTUnwrap(defaults.data(forKey: AppPersistence.knownDevicesKey))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual((object["devices"] as? [Any])?.count, 1)
    }

    func testDCCardPendingPresentationFollowsRequestedTargetUntilTelemetryConfirms() async throws {
        let reply = Data([Command.dcControl.rawValue, Action.set.rawValue | 0x80, 0])
        let session = DeviceSession(transport: ReplayTransport(steps: [.reply(bytes: reply)]))

        _ = try await session.perform(.setDC(true))

        var state = await session.state
        XCTAssertTrue(DashboardPendingPresentation.isDCPending(state.pendingMutations))
        XCTAssertNil(state.dc, "Pending UI must not optimistically alter telemetry")

        let confirmed = try DCPortStatus(frame: Data([1, 0, 0, 0, 0, 0, 0, 0]))
        await session.receive(.dc(confirmed, timestamp: .zero))

        state = await session.state
        XCTAssertFalse(DashboardPendingPresentation.isDCPending(state.pendingMutations))
        XCTAssertEqual(state.dc, confirmed)
    }

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
        model.choose(.init(id: id, localName: "Link-Power 2", rssi: -40, mode: .application))
        try await eventually { await fixture.transport.currentScope() != nil }
        let currentScope = await fixture.transport.currentScope()
        let scope = try XCTUnwrap(currentScope)
        await fixture.transport.emit(.handshakeCompleted(snapshot, scope: scope))

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

        model.choose(.init(id: id, localName: "PeakDo-OTA", rssi: -40, mode: .ota))
        let scope = testScope(id)
        await fixture.transport.emit(.handshakeCompleted(snapshot, scope: scope))
        await fixture.transport.emit(.connected(scope))

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

    func testDirectConnectionPublishesBrokerReadinessBeforeConnectedPresentation() async throws {
        let transport = ControlledConnectionTransport()
        let initialPublication = AsyncGate()
        let completionPublication = AsyncGate()
        let gate = AsyncGate()
        let suiteName = "WattlineTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let persistence = AppPersistence(defaults: defaults)
        let model = AppModel(
            persistence: persistence,
            transportFactory: { transport },
            brokerPublicationBarrier: {
                if await transport.connectCount == 0 {
                    await initialPublication.open()
                    return
                }
                await completionPublication.open()
                await gate.wait()
            }
        )
        let device = DiscoveredDevice(
            id: UUID(),
            localName: "Link-Power 2",
            rssi: -40,
            mode: .application
        )

        model.requestBluetoothAfterPriming()
        await initialPublication.wait()
        model.choose(device)
        try await waitUntil { await transport.connectCount == 1 }
        await transport.succeedConnect(at: 0, deliverConnectedEvent: false)
        await completionPublication.wait()

        XCTAssertNotEqual(model.connectionStatus, .connected)
        await gate.open()
        try await waitUntil {
            await MainActor.run { model.connectionStatus == .connected }
        }
        let hasConnectedContext = await model.deviceOperationBroker.hasConnectedContext
        XCTAssertTrue(hasConnectedContext)
    }

    func testReturnToScanDuringDirectConnectedLifecycleCannotReattachOldBrokerContext() async throws {
        let transport = ControlledConnectionTransport()
        let lifecycle = BrokerPublicationBarrier()
        let suiteName = "WattlineTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let model = AppModel(
            persistence: AppPersistence(defaults: defaults),
            transportFactory: { transport },
            connectedLifecycleBarrier: { await lifecycle.waitIfHeld() }
        )
        let device = DiscoveredDevice(
            id: UUID(),
            localName: "Link-Power 2",
            rssi: -40,
            mode: .application
        )

        model.requestBluetoothAfterPriming()
        model.choose(device)
        try await waitUntil { await transport.connectCount == 1 }
        await lifecycle.holdNext()
        await transport.succeedConnect(at: 0, deliverConnectedEvent: false)
        try await waitUntil { await lifecycle.isBlocked }

        model.returnToScan()
        await model.syncClock()
        XCTAssertNil(model.lastClockSync, "returning to scan must detach the old broker context")
        await lifecycle.release()
        await model.waitForSupersededLifecycleOperation()

        await model.syncClock()
        XCTAssertNil(model.lastClockSync, "stale direct completion must not reattach the old broker context")
        XCTAssertEqual(model.route, .scan)
        XCTAssertEqual(model.connectionStatus, .disconnected(nil))
    }

    func testReturnToScanRejectsLateScopedConnectedAndHandshake() async throws {
        let transport = ControlledConnectionTransport()
        let suiteName = "WattlineTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let model = AppModel(persistence: AppPersistence(defaults: defaults), transportFactory: { transport })
        let id = UUID()
        model.requestBluetoothAfterPriming()
        model.choose(.init(id: id, localName: "Device", rssi: -40, mode: .application))
        try await eventually { await transport.connectCount == 1 }
        await transport.succeedConnect(at: 0)
        try await eventually { model.connectionStatus == .connected }
        let scope = await transport.scope(at: 0)

        model.returnToScan()
        await transport.emit(.connected(scope))
        await transport.emit(.handshakeCompleted(makeIdentity(id: id, features: 0x7FFF), scope: scope))
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(model.route, .scan)
        XCTAssertEqual(model.connectionStatus, .disconnected(nil))
        XCTAssertNil(model.state.identity)
    }

    func testReturnToScanRejectsOldBrokerContextWhileDetachPublicationIsHeld() async throws {
        let fixture = makeFixture(onboardingComplete: false)
        let publication = BrokerPublicationBarrier()
        let model = AppModel(
            persistence: fixture.persistence,
            transportFactory: { fixture.transport },
            brokerPublicationBarrier: { await publication.waitIfHeld() }
        )
        let peripheralID = UUID()
        model.requestBluetoothAfterPriming()
        model.choose(.init(
            id: peripheralID,
            localName: "Link-Power 2",
            rssi: -45,
            mode: .application
        ))
        try await eventually { model.connectionStatus == .connected }
        await publication.holdNext()

        model.returnToScan()
        await publication.waitUntilBlocked()
        let operationCount = OperationInvocationCounter()
        let result = Task {
            try await model.deviceOperationBroker.withConnection(to: peripheralID) { _ in
                await operationCount.increment()
                return true
            }
        }

        do {
            _ = try await result.value
            XCTFail("Old broker context must be rejected after scan state is visible")
        } catch let error as Wattline.DeviceOperationBroker.BrokerError {
            XCTAssertEqual(error, .unavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let invocationCount = await operationCount.value
        XCTAssertEqual(invocationCount, 0)
        await publication.release()
    }

    func testTransportReplacementRejectsOldBrokerContextWhileAttachPublicationIsHeld() async throws {
        let first = RecordingTransport(connectResult: .success)
        let second = RecordingTransport(connectResult: .success)
        var transports = [first, second]
        let suiteName = "WattlineTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let publication = BrokerPublicationBarrier()
        let model = AppModel(
            persistence: AppPersistence(defaults: defaults),
            transportFactory: { transports.removeFirst() },
            brokerPublicationBarrier: { await publication.waitIfHeld() }
        )
        let peripheralID = UUID()
        model.requestBluetoothAfterPriming()
        model.choose(.init(
            id: peripheralID,
            localName: "Link-Power 2",
            rssi: -45,
            mode: .application
        ))
        try await eventually { model.connectionStatus == .connected }
        await publication.holdNext()

        model.requestBluetoothAfterPriming()
        await publication.waitUntilBlocked()
        let operationCount = OperationInvocationCounter()

        do {
            _ = try await model.deviceOperationBroker.withConnection(to: peripheralID) { _ in
                await operationCount.increment()
                return true
            }
            XCTFail("Old broker context must be rejected after transport replacement returns")
        } catch let error as Wattline.DeviceOperationBroker.BrokerError {
            XCTAssertEqual(error, .unavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let invocationCount = await operationCount.value
        XCTAssertEqual(invocationCount, 0)
        await publication.release()
    }

    func testBrokerReconnectRoutesThroughAppModelAsSoleConnectOwner() async throws {
        let transport = RecordingTransport(connectResult: .success)
        let suiteName = "WattlineTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        var factoryCallCount = 0
        let model = AppModel(persistence: AppPersistence(defaults: defaults)) {
            factoryCallCount += 1
            return transport
        }
        let peripheralID = UUID()

        model.requestBluetoothAfterPriming()
        model.choose(.init(
            id: peripheralID,
            localName: "Link-Power 2",
            rssi: -45,
            mode: .application
        ))
        try await eventually {
            await transport.connectedIDs.count == 1 && model.connectionStatus == .connected
        }
        let currentScope = await transport.currentScope()
        let initialScope = try XCTUnwrap(currentScope)
        await transport.emit(.disconnected(initialScope, TransportFailure(message: "link lost")))
        try await eventually { model.connectionStatus == .disconnected("link lost") }

        let result = Task {
            try await model.deviceOperationBroker.withConnection(to: peripheralID) { context in
                context.generation
            }
        }

        try await eventually { await transport.connectedIDs.count == 2 }
        _ = try await result.value
        let connectedIDs = await transport.connectedIDs
        XCTAssertEqual(connectedIDs, [peripheralID, peripheralID])
        XCTAssertEqual(factoryCallCount, 1, "Broker reconnect must reuse AppModel's transport")
    }

    func testLateConnectedAndDisconnectedForA_DoNotReplaceConnectedB() async throws {
        let transport = ControlledConnectionTransport()
        let suiteName = "WattlineTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let persistence = AppPersistence(defaults: defaults)
        let model = AppModel(persistence: persistence, transportFactory: { transport })
        let a = UUID()
        let b = UUID()
        model.requestBluetoothAfterPriming()

        model.choose(.init(id: a, localName: "A", rssi: -40, mode: .application))
        try await eventually { await transport.connectCount == 1 }
        model.choose(.init(id: b, localName: "B", rssi: -40, mode: .application))
        try await eventually { await transport.connectCount == 2 }
        await transport.succeedConnect(at: 1)
        try await eventually {
            model.connectionStatus == .connected && persistence.lastSuccessfulPeripheralID == b
        }

        let staleScope = await transport.scope(at: 0)
        await transport.emit(.connected(staleScope))
        await transport.emit(.disconnected(staleScope, TransportFailure(message: "stale A")))
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(persistence.lastSuccessfulPeripheralID, b)
        XCTAssertEqual(model.connectionStatus, .connected)
        let reused = try await model.deviceOperationBroker.withConnection(to: b) { $0.peripheralID }
        XCTAssertEqual(reused, b)

        let currentScope = await transport.scope(at: 1)
        await transport.emit(.disconnected(currentScope, TransportFailure(message: "current B")))
        try await eventually { model.connectionStatus == .disconnected("current B") }
    }

    func testDirectConnectSuccessDoesNotDependOnConnectedEventDeliveryOrdering() async throws {
        let transport = ControlledConnectionTransport()
        let suiteName = "WattlineTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let model = AppModel(
            persistence: AppPersistence(defaults: defaults),
            transportFactory: { transport }
        )
        let id = UUID()
        model.requestBluetoothAfterPriming()
        model.choose(.init(id: id, localName: "Device", rssi: -40, mode: .application))
        try await eventually { await transport.connectCount == 1 }

        await transport.succeedConnect(at: 0, deliverConnectedEvent: false)

        try await eventually { model.connectionStatus == .connected }
        let reused = try await model.deviceOperationBroker.withConnection(to: id) { $0.peripheralID }
        XCTAssertEqual(reused, id)

        let scope = await transport.scope(at: 0)
        await transport.emitConnected(at: 0)
        try await eventually { model.connectionStatus == .connected }
        await transport.emit(.disconnected(scope, TransportFailure(message: "link lost")))
        try await eventually { model.connectionStatus == .disconnected("link lost") }
    }

    func testBrokerReconnectSuccessInstallsScopeBeforeResolvingWithoutConnectedEvent() async throws {
        let transport = ControlledConnectionTransport()
        let suiteName = "WattlineTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let model = AppModel(
            persistence: AppPersistence(defaults: defaults),
            transportFactory: { transport }
        )
        let id = UUID()
        model.requestBluetoothAfterPriming()
        model.choose(.init(id: id, localName: "Device", rssi: -40, mode: .application))
        try await eventually { await transport.connectCount == 1 }
        await transport.succeedConnect(at: 0)
        try await eventually { model.connectionStatus == .connected }
        let initialScope = await transport.scope(at: 0)
        await transport.emit(.disconnected(initialScope, TransportFailure(message: "link lost")))
        try await eventually { model.connectionStatus == .disconnected("link lost") }

        let reconnect = Task {
            try await model.deviceOperationBroker.withConnection(to: id) { $0.peripheralID }
        }
        try await eventually { await transport.connectCount == 2 }
        await transport.succeedConnect(at: 1, deliverConnectedEvent: false)

        let reconnectedID = try await reconnect.value
        XCTAssertEqual(reconnectedID, id)
        XCTAssertEqual(model.connectionStatus, .connected)

        let reconnectScope = await transport.scope(at: 1)
        await transport.emitConnected(at: 1)
        try await eventually { model.connectionStatus == .connected }
        await transport.emit(.disconnected(reconnectScope, TransportFailure(message: "current terminal")))
        try await eventually { model.connectionStatus == .disconnected("current terminal") }
    }

    func testBrokerReconnectTerminalDuringConnectedLifecycleDeliveryNeverStrandsWaiter() async throws {
        let transport = ControlledConnectionTransport()
        let lifecycle = BrokerPublicationBarrier()
        let invocationCount = OperationInvocationCounter()
        let suiteName = "WattlineTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let model = AppModel(
            persistence: AppPersistence(defaults: defaults),
            transportFactory: { transport },
            connectedLifecycleBarrier: { await lifecycle.waitIfHeld() }
        )
        let id = UUID()
        model.requestBluetoothAfterPriming()
        model.choose(.init(id: id, localName: "Device", rssi: -40, mode: .application))
        try await eventually { await transport.connectCount == 1 }
        await transport.succeedConnect(at: 0)
        try await eventually { model.connectionStatus == .connected }
        let initialScope = await transport.scope(at: 0)
        await transport.emit(.disconnected(initialScope, TransportFailure(message: "link lost")))
        try await eventually { model.connectionStatus == .disconnected("link lost") }

        await lifecycle.holdNext()
        let reconnect = Task { () -> Result<UUID, Error> in
            do {
                return .success(try await model.deviceOperationBroker.withConnection(
                    to: id,
                    timeout: .milliseconds(150)
                ) { context in
                    await invocationCount.increment()
                    return context.peripheralID
                })
            } catch {
                return .failure(error)
            }
        }
        try await eventually { await transport.connectCount == 2 }
        await transport.succeedConnect(at: 1, deliverConnectedEvent: false)
        await lifecycle.waitUntilBlocked()

        let reconnectScope = await transport.scope(at: 1)
        await transport.emit(.disconnected(reconnectScope, TransportFailure(message: "terminal during delivery")))
        try await eventually { model.connectionStatus == .disconnected("terminal during delivery") }
        let result = await reconnect.value

        switch result {
        case let .success(reconnectedID):
            XCTAssertEqual(reconnectedID, id)
        case let .failure(error):
            XCTFail("Reconnect waiter did not complete successfully: \(error)")
        }
        let countBeforeRelease = await invocationCount.value
        XCTAssertEqual(countBeforeRelease, 1)
        let pendingConnectionCount = await model.deviceOperationBroker.pendingConnectionCount
        XCTAssertEqual(pendingConnectionCount, 0)
        XCTAssertNil(model.brokerReconnectAttempt)

        await lifecycle.release()
        try await Task.sleep(for: .milliseconds(50))
        let countAfterRelease = await invocationCount.value
        XCTAssertEqual(countAfterRelease, 1)
        XCTAssertEqual(model.connectionStatus, .disconnected("terminal during delivery"))
    }

    func testBrokerReconnectTerminalDuringBrokerCompletionLeavesBrokerDisconnected() async throws {
        let transport = ControlledConnectionTransport()
        let completionHop = BrokerPublicationBarrier()
        let invocationCount = OperationInvocationCounter()
        let suiteName = "WattlineTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let model = AppModel(
            persistence: AppPersistence(defaults: defaults),
            transportFactory: { transport },
            brokerCompletionBarrier: { await completionHop.waitIfHeld() }
        )
        let id = UUID()
        model.requestBluetoothAfterPriming()
        model.choose(.init(id: id, localName: "Device", rssi: -40, mode: .application))
        try await eventually { await transport.connectCount == 1 }
        await transport.succeedConnect(at: 0)
        try await eventually { model.connectionStatus == .connected }
        let initialScope = await transport.scope(at: 0)
        await transport.emit(.disconnected(initialScope, TransportFailure(message: "link lost")))
        try await eventually { model.connectionStatus == .disconnected("link lost") }

        await completionHop.holdNext()
        let reconnect = Task { () -> Result<UUID, Error> in
            do {
                return .success(try await model.deviceOperationBroker.withConnection(
                    to: id,
                    timeout: .milliseconds(150)
                ) { context in
                    await invocationCount.increment()
                    return context.peripheralID
                })
            } catch {
                return .failure(error)
            }
        }
        try await eventually { await transport.connectCount == 2 }
        await transport.succeedConnect(at: 1, deliverConnectedEvent: false)
        await completionHop.waitUntilBlocked()

        let reconnectScope = await transport.scope(at: 1)
        await transport.emit(.disconnected(
            reconnectScope,
            TransportFailure(message: "terminal during broker completion")
        ))
        try await eventually {
            model.connectionStatus == .disconnected("terminal during broker completion")
        }
        await completionHop.release()

        switch await reconnect.value {
        case let .success(reconnectedID):
            XCTAssertEqual(reconnectedID, id)
        case let .failure(error):
            XCTFail("Reconnect waiter did not complete successfully: \(error)")
        }
        let countAfterCompletion = await invocationCount.value
        let pendingAfterCompletion = await model.deviceOperationBroker.pendingConnectionCount
        XCTAssertEqual(countAfterCompletion, 1)
        XCTAssertEqual(pendingAfterCompletion, 0)
        try await eventually { await !model.deviceOperationBroker.hasConnectedContext }
        let brokerHasConnectedContext = await model.deviceOperationBroker.hasConnectedContext
        XCTAssertFalse(brokerHasConnectedContext)
        XCTAssertNil(model.brokerReconnectAttempt)
        XCTAssertEqual(model.connectionStatus, .disconnected("terminal during broker completion"))
        try await Task.sleep(for: .milliseconds(50))
        let finalInvocationCount = await invocationCount.value
        let finalPendingConnectionCount = await model.deviceOperationBroker.pendingConnectionCount
        XCTAssertEqual(finalInvocationCount, 1)
        XCTAssertEqual(finalPendingConnectionCount, 0)
        XCTAssertEqual(model.connectionStatus, .disconnected("terminal during broker completion"))
    }

    func testOldSamePeripheralConnectSuccessCannotResolveCurrentBrokerAttempt() async throws {
        let transport = ControlledConnectionTransport()
        let suiteName = "WattlineTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let model = AppModel(
            persistence: AppPersistence(defaults: defaults),
            transportFactory: { transport }
        )
        let id = UUID()
        model.requestBluetoothAfterPriming()
        model.choose(.init(id: id, localName: "Device", rssi: -40, mode: .application))
        try await eventually { await transport.connectCount == 1 }
        await transport.succeedConnect(at: 0)
        try await eventually { model.connectionStatus == .connected }
        let initialScope = await transport.scope(at: 0)
        await transport.emit(.disconnected(initialScope, TransportFailure(message: "link lost")))
        try await eventually { model.connectionStatus == .disconnected("link lost") }

        let first = Task {
            try await model.deviceOperationBroker.withConnection(to: id) { _ in true }
        }
        try await eventually { await transport.connectCount == 2 }
        let second = Task {
            try await model.deviceOperationBroker.withConnection(to: id) { _ in true }
        }
        try await eventually { await transport.connectCount == 3 }

        await transport.succeedConnect(at: 1)
        try await Task.sleep(for: .milliseconds(50))
        let pendingConnectionCount = await model.deviceOperationBroker.pendingConnectionCount
        XCTAssertEqual(pendingConnectionCount, 1)

        await transport.succeedConnect(at: 2)
        _ = try await second.value
        do {
            _ = try await first.value
            XCTFail("The superseded first waiter must fail")
        } catch let error as Wattline.DeviceOperationBroker.BrokerError {
            XCTAssertEqual(error, .superseded)
        }
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
        XCTAssertFalse(model.limitReadFailures.contains(.global))
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

    func testThrownInitialLimitGetMarksTypeUnavailableStopsLoadingAndToasts() async {
        let transport = MutationTransport(steps: [
            .failure,
            .reply(Data([0x02, 0x80, 0x00, PowerLimitLevel.watts45.rawValue])),
            .reply(Data([0x02, 0x80, 0x00, PowerLimitLevel.watts60.rawValue])),
            .reply(Data([0x02, 0x80, 0xFF])),
        ])
        let model = makeMutationModel(transport: transport)
        model.capabilities = DeviceCapabilities(features: [.usbPowerLimit])

        await model.loadLimits()

        XCTAssertFalse(model.limitsLoading)
        XCTAssertNil(model.limits[.global])
        XCTAssertTrue(model.limitReadFailures.contains(.global))
        XCTAssertEqual(model.limits[.input], .watts45)
        XCTAssertEqual(model.limits[.output], .watts60)
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
        model.choose(.init(id: lpp.peripheralID, localName: "Link-Power Plus", rssi: -40, mode: .application))
        try await eventually { await fixture.transport.currentScope()?.peripheralID == lpp.peripheralID }
        let maybeLPPScope = await fixture.transport.currentScope()
        let lppScope = try XCTUnwrap(maybeLPPScope)
        await fixture.transport.emit(.handshakeCompleted(lpp, scope: lppScope))
        try await eventually { model.capabilities == lpp.capabilities }
        XCTAssertTrue(model.capabilities.hasDCPort)
        XCTAssertFalse(model.capabilities.hasBattery)

        let lp2 = DeviceIdentitySnapshot(
            peripheralID: UUID(), advertisedName: "Link-Power 2", mode: .application,
            modelNumber: "BP4SL3V2",
            capabilities: CapabilityResolver.resolve(features: nil, cid: nil, model: "BP4SL3V2")
        )
        model.choose(.init(id: lp2.peripheralID, localName: "Link-Power 2", rssi: -40, mode: .application))
        try await eventually { await fixture.transport.currentScope()?.peripheralID == lp2.peripheralID }
        let maybeLP2Scope = await fixture.transport.currentScope()
        let lp2Scope = try XCTUnwrap(maybeLP2Scope)
        await fixture.transport.emit(.handshakeCompleted(lp2, scope: lp2Scope))
        try await eventually { model.capabilities == lp2.capabilities }
        XCTAssertTrue(model.capabilities.hasBattery)
        XCTAssertTrue(model.capabilities.hasUSBPort)
    }

    func testPortMutationImmediatelyPublishesPendingAndTelemetryConfirmation() async throws {
        let reply = Data([Command.dcControl.rawValue, Action.set.rawValue | 0x80, 0])
        let transport = MutationTransport(steps: [.suspendedReply(reply)])
        let model = makeMutationModel(transport: transport)
        let peripheralID = UUID()
        model.choose(.init(
            id: peripheralID,
            localName: "Link-Power 2",
            rssi: -45,
            mode: .application
        ))
        try await eventually { model.connectionStatus == .connected }
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
        model.choose(device)

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
            try await eventually {
                model.connectionStatus == .disconnected("reconnectFailed")
            }
            await fixture.transport.releasePostThrowDisconnectIfNeeded()
            try await Task.sleep(for: .milliseconds(25))

            XCTAssertEqual(model.route, .scan, "ordering: \(ordering)")
            XCTAssertEqual(model.connectionStatus, .disconnected("reconnectFailed"), "ordering: \(ordering)")
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
        try await eventually { model.connectionStatus == .connected }

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

    func testDemoIdentityUsesAuthoritativeHandshakeWithoutPersistingDemoDevice() async throws {
        let fixture = makeFixture(onboardingComplete: false)
        let model = AppModel(persistence: fixture.persistence, transportFactory: { fixture.transport })

        model.enterDemo()

        try await eventually {
            model.state.identity?.cid == 0x0305
                && model.state.identity?.modelNumber == "BP4SL3V2"
                && model.capabilities.features.rawValue == 0x7FFF
                && model.connectionStatus == .connected
        }
        XCTAssertEqual(model.state.identity?.appFirmwareRevision, "1.4.9")
        XCTAssertTrue(model.knownDevices.isEmpty)
        XCTAssertNil(fixture.persistence.lastSuccessfulPeripheralID)
    }

    func testRealTelemetryPersistenceRoundTripsAndPartialUpdatesRetainOtherChannels() async throws {
        var observedAt = Date(timeIntervalSince1970: 1_000)
        let fixture = makeFixture(onboardingComplete: false, wallClock: { observedAt })
        let model = AppModel(persistence: fixture.persistence, transportFactory: { fixture.transport })
        model.requestBluetoothAfterPriming()
        let id = UUID()
        let identity = makeIdentity(id: id, features: 0x7FFF)
        let firstBattery = try battery(level: 62)
        let replacementBattery = try battery(level: 63)
        let dc = try DCPortStatus(frame: Data([1, 0xFF, 0, 0, 0, 0, 0, 0]))
        let typeC = try TypeCPortStatus(frame: Data(repeating: 0, count: 13))

        model.choose(.init(id: id, localName: "Link-Power 2", rssi: -40, mode: .application))
        try await eventually { await fixture.transport.currentScope()?.peripheralID == id }
        let maybeScope = await fixture.transport.currentScope()
        let scope = try XCTUnwrap(maybeScope)
        await fixture.transport.emit(.handshakeCompleted(identity, scope: scope))
        await fixture.transport.emit(.battery(firstBattery, timestamp: .seconds(1)))
        try await eventually { model.state.battery == firstBattery }
        observedAt = Date(timeIntervalSince1970: 1_001)
        await fixture.transport.emit(.dc(dc, timestamp: .seconds(2)))
        try await eventually { model.state.dc == dc }
        observedAt = Date(timeIntervalSince1970: 1_002)
        await fixture.transport.emit(.typeC(typeC, timestamp: .seconds(3)))
        try await eventually {
            fixture.persistence.loadPersistedDeviceState(for: id)?.typeC?.value == typeC
        }

        var persisted = try XCTUnwrap(fixture.persistence.loadPersistedDeviceState(for: id))
        XCTAssertEqual(persisted.resolvedFeaturesRawValue, 0x7FFF)
        XCTAssertEqual(persisted.battery?.value, firstBattery)
        XCTAssertEqual(persisted.dc?.value, dc)
        XCTAssertEqual(persisted.typeC?.value, typeC)
        XCTAssertEqual(fixture.persistence.telemetryFlushCount, 1)
        XCTAssertEqual(persisted.battery?.observedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(persisted.dc?.observedAt, Date(timeIntervalSince1970: 1_001))
        XCTAssertEqual(persisted.typeC?.observedAt, Date(timeIntervalSince1970: 1_002))

        observedAt = Date(timeIntervalSince1970: 2_000)
        await fixture.transport.emit(.battery(replacementBattery, timestamp: .seconds(4)))
        try await eventually {
            fixture.persistence.loadPersistedDeviceState(for: id)?.battery?.value == replacementBattery
        }
        persisted = try XCTUnwrap(fixture.persistence.loadPersistedDeviceState(for: id))
        XCTAssertEqual(persisted.battery?.observedAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(persisted.dc?.value, dc, "battery updates must not discard DC")
        XCTAssertEqual(persisted.typeC?.value, typeC, "battery updates must not discard Type-C")
        XCTAssertEqual(persisted.dc?.observedAt, Date(timeIntervalSince1970: 1_001))
        XCTAssertEqual(persisted.typeC?.observedAt, Date(timeIntervalSince1970: 1_002))
    }

    func testDistinctTimestampTelemetryBeforeNewDeviceHandshakeIsRetainedUntilIdentityExists() async throws {
        let fixture = makeFixture(onboardingComplete: false)
        let model = AppModel(persistence: fixture.persistence, transportFactory: { fixture.transport })
        model.requestBluetoothAfterPriming()
        let id = UUID()
        let identity = makeIdentity(id: id, features: 0x7FFF)
        let battery = try battery(level: 62)
        let dc = try DCPortStatus(frame: Data([1, 0xFF, 0, 0, 0, 0, 0, 0]))
        let typeC = try TypeCPortStatus(frame: Data(repeating: 0, count: 13))

        model.choose(.init(id: id, localName: "Link-Power 2", rssi: -40, mode: .application))
        try await eventually { await fixture.transport.currentScope()?.peripheralID == id }
        let maybeScope = await fixture.transport.currentScope()
        let scope = try XCTUnwrap(maybeScope)
        await fixture.transport.emit(.battery(battery, timestamp: .seconds(1)))
        await fixture.transport.emit(.dc(dc, timestamp: .seconds(2)))
        await fixture.transport.emit(.typeC(typeC, timestamp: .seconds(3)))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(fixture.persistence.loadPersistedDeviceState(for: id))
        await fixture.transport.emit(.handshakeCompleted(identity, scope: scope))

        try await eventually {
            fixture.persistence.loadPersistedDeviceState(for: id)?.typeC?.value == typeC
        }
        let persisted = try XCTUnwrap(fixture.persistence.loadPersistedDeviceState(for: id))
        XCTAssertEqual(persisted.battery?.value, battery)
        XCTAssertEqual(persisted.dc?.value, dc)
        XCTAssertEqual(persisted.typeC?.value, typeC)
        XCTAssertEqual(fixture.persistence.telemetryFlushCount, 1)
    }

    func testReturningRelaunchRestoresStaleSnapshotCapabilitiesAndReplacesFreshChannels() async throws {
        let id = UUID()
        let fixture = makeFixture(onboardingComplete: false)
        let initial = AppModel(persistence: fixture.persistence, transportFactory: { fixture.transport })
        initial.requestBluetoothAfterPriming()
        let identity = makeIdentity(id: id, features: 0x0310)
        let cachedBattery = try battery(level: 62)
        let freshBattery = try battery(level: 64)
        let cachedDC = try DCPortStatus(frame: Data([1, 0xFF, 0, 0, 0, 0, 0, 0]))
        let cachedTypeC = try TypeCPortStatus(frame: Data(repeating: 0, count: 13))
        initial.choose(.init(id: id, localName: "Link-Power 2", rssi: -40, mode: .application))
        try await eventually { await fixture.transport.currentScope()?.peripheralID == id }
        let maybeScope = await fixture.transport.currentScope()
        let scope = try XCTUnwrap(maybeScope)
        await fixture.transport.emit(.handshakeCompleted(identity, scope: scope))
        await fixture.transport.emit(.battery(cachedBattery, timestamp: .seconds(1)))
        await fixture.transport.emit(.dc(cachedDC, timestamp: .seconds(2)))
        await fixture.transport.emit(.typeC(cachedTypeC, timestamp: .seconds(3)))
        try await eventually {
            fixture.persistence.loadPersistedDeviceState(for: id)?.typeC?.value == cachedTypeC
        }
        fixture.persistence.onboardingComplete = true
        fixture.persistence.lastSuccessfulPeripheralID = id

        let returningTransport = RecordingTransport(connectResult: .suspended)
        let restored = AppModel(
            persistence: fixture.persistence,
            transportFactory: { returningTransport }
        )

        XCTAssertEqual(restored.connectionStatus, .reconnecting)
        XCTAssertEqual(restored.state.connection, .reconnecting)
        XCTAssertEqual(restored.state.freshness, .stale)
        XCTAssertEqual(restored.state.battery, cachedBattery)
        XCTAssertEqual(restored.state.dc, cachedDC)
        XCTAssertEqual(restored.state.typeC, cachedTypeC)
        XCTAssertNil(restored.state.lastTelemetryAt, "monotonic time must not cross launches")
        XCTAssertEqual(restored.capabilities.features.rawValue, 0x0310)

        await returningTransport.emit(.battery(freshBattery, timestamp: .seconds(1)))
        try await eventually { restored.state.battery == freshBattery }
        XCTAssertEqual(restored.state.freshness, .live)
        XCTAssertEqual(restored.state.dc, cachedDC)
        XCTAssertEqual(restored.state.typeC, cachedTypeC)
    }

    private func makeFixture(
        onboardingComplete: Bool,
        lastPeripheralID: UUID? = nil,
        connectResult: RecordingTransport.ConnectResult = .success,
        wallClock: @escaping @MainActor () -> Date = Date.init
    ) -> (persistence: AppPersistence, transport: RecordingTransport) {
        let suiteName = "WattlineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let persistence = AppPersistence(defaults: defaults, wallClock: wallClock)
        persistence.onboardingComplete = onboardingComplete
        persistence.lastSuccessfulPeripheralID = lastPeripheralID
        return (persistence, RecordingTransport(connectResult: connectResult))
    }

    private func makeIdentity(id: UUID, features: UInt32) -> DeviceIdentitySnapshot {
        DeviceIdentitySnapshot(
            peripheralID: id,
            advertisedName: "Link-Power 2",
            mode: .application,
            modelNumber: "BP4SL3V2",
            hardwareRevision: "V5#0305",
            appFirmwareRevision: "1.4.9",
            cid: 0x0305,
            rawFeatures: features,
            capabilities: DeviceCapabilities(features: FeatureFlags(rawValue: features))
        )
    }

    private func battery(level: UInt8) throws -> BatteryStatus {
        var frame = Data(repeating: 0, count: 16)
        frame[0] = 1
        frame[1] = UInt8(bitPattern: PowerFlow.discharging.rawValue)
        frame[7] = level
        return try BatteryStatus(frame: frame)
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
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            if clock.now >= deadline {
                XCTFail("Condition was not met before timeout", file: file, line: line)
                return
            }
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
    func connect(to id: UUID, scope: DeviceConnectionScope) async throws {
        continuation.yield(.connected(scope))
    }
    func disconnect() async {}
    func refreshTelemetry() async throws {}
    func synchronizeDeviceTime() async throws {}
    func readDeviceTimeIfSupported() async throws -> Date? { nil }
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

private actor BrokerPublicationBarrier {
    private var shouldHold = false
    private var blocked = false
    private var continuation: CheckedContinuation<Void, Never>?

    var isBlocked: Bool { blocked }

    func holdNext() { shouldHold = true }

    func waitIfHeld() async {
        guard shouldHold else { return }
        shouldHold = false
        blocked = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilBlocked() async {
        while !blocked { await Task.yield() }
    }

    func release() {
        blocked = false
        continuation?.resume()
        continuation = nil
    }
}

private actor OperationInvocationCounter {
    private(set) var value = 0
    func increment() { value += 1 }
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
    private var activeScope: DeviceConnectionScope?
    private var scopes: [DeviceConnectionScope] = []
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

    func connect(to id: UUID, scope: DeviceConnectionScope) async throws {
        connectedIDs.append(id)
        activeScope = scope
        scopes.append(scope)
        switch connectResult {
        case .success:
            continuation.yield(.connected(scope))
        case .failure(.beforeThrow):
            continuation.yield(.disconnected(scope, TransportFailure(message: "reconnect failed")))
            throw Failure.reconnectFailed
        case .failure(.afterThrow):
            postThrowDisconnectPending = true
            throw Failure.reconnectFailed
        case .suspended:
            try await withCheckedThrowingContinuation { suspendedConnect = $0 }
        }
    }

    func releasePostThrowDisconnectIfNeeded() {
        guard postThrowDisconnectPending, let activeScope else { return }
        postThrowDisconnectPending = false
        continuation.yield(.disconnected(activeScope, TransportFailure(message: "reconnect failed")))
    }

    func failSuspendedConnect(ordering: FailureOrdering) {
        guard let suspendedConnect else { return }
        self.suspendedConnect = nil
        if ordering == .beforeThrow {
            if let activeScope {
                continuation.yield(.disconnected(activeScope, TransportFailure(message: "stale reconnect failed")))
            }
        } else {
            postThrowDisconnectPending = true
        }
        suspendedConnect.resume(throwing: Failure.reconnectFailed)
    }

    func scope(at index: Int) -> DeviceConnectionScope { scopes[index] }
    func currentScope() -> DeviceConnectionScope? { activeScope }
    func disconnect() async {
        disconnectCount += 1
        if let activeScope {
            self.activeScope = nil
            continuation.yield(.disconnected(activeScope, nil))
        }
    }
    func perform(_ command: DeviceCommand) async throws -> CommandOutcome { .sent }
    func refreshTelemetry() async throws {}
    func synchronizeDeviceTime() async throws {}
    func readDeviceTimeIfSupported() async throws -> Date? { nil }
}

private actor ControlledConnectionTransport: DeviceTransport {
    nonisolated let events: AsyncStream<DeviceEvent>
    private let continuation: AsyncStream<DeviceEvent>.Continuation
    private var connectContinuations: [CheckedContinuation<Void, Error>] = []
    private(set) var connectedIDs: [UUID] = []
    private var scopes: [DeviceConnectionScope] = []
    var connectCount: Int { connectedIDs.count }

    init() {
        let pair = AsyncStream<DeviceEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    func emit(_ event: DeviceEvent) { continuation.yield(event) }
    func startScan() async throws {}
    func stopScan() async {}
    func connect(to id: UUID, scope: DeviceConnectionScope) async throws {
        connectedIDs.append(id)
        scopes.append(scope)
        try await withCheckedThrowingContinuation { connectContinuations.append($0) }
    }
    func succeedConnect(at index: Int, deliverConnectedEvent: Bool = true) {
        connectContinuations[index].resume()
        if deliverConnectedEvent {
            continuation.yield(.connected(scopes[index]))
        }
    }
    func emitConnected(at index: Int) { continuation.yield(.connected(scopes[index])) }
    func scope(at index: Int) -> DeviceConnectionScope { scopes[index] }
    func disconnect() async {}
    func perform(_ command: DeviceCommand) async throws -> CommandOutcome { .sent }
    func refreshTelemetry() async throws {}
    func synchronizeDeviceTime() async throws {}
    func readDeviceTimeIfSupported() async throws -> Date? { nil }
}
