import Foundation
import WattlineCore
@testable import WattlineNetwork
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import Wattline

@MainActor
final class RouterAppWiringTests: XCTestCase {
    func testTransportLabelsAreExplicitAndStable() {
        XCTAssertEqual(AppTransportKind.bluetooth.label, "BT")
        XCTAssertEqual(AppTransportKind.router.label, "Router")
        XCTAssertEqual(AppTransportKind.demo.label, "Demo")
    }

    func testRouterAndBluetoothRecordsWithTheSameMACAreOneBluetoothPreferredDevice() async throws {
        let fixture = makeFixture()
        let sharedHost = try host(name: "Kitchen router", address: "192.168.8.1:8377", mac: "dc-04-5a-eb-72-2b")
        let otherHost = try host(name: "Cabin router", address: "router.tailnet.ts.net:8377", reachability: .vpn, mac: "AA:BB:CC:DD:EE:FF")
        try await fixture.hostStore.save(sharedHost)
        try await fixture.hostStore.save(otherHost)
        await fixture.model.reloadSavedHosts()

        let records = fixture.model.records(bluetooth: [identity(mac: "DC:04:5A:EB:72:2B", cid: 0x0302)])

        XCTAssertEqual(records.count, 2)
        let merged = try XCTUnwrap(records.first { $0.transportOptions == [.bluetooth, .router] })
        XCTAssertEqual(merged.preferredTransport, .bluetooth)
        XCTAssertEqual(merged.routerHost?.id, sharedHost.id)
        XCTAssertEqual(records.first { $0.routerHost?.id == otherHost.id }?.transportOptions, [.router])
    }

    func testKnownRouterIdentityDoesNotMergeIntoIdentitylessSavedHostRecord() async throws {
        let fixture = makeFixture()
        let firstHost = try host(
            name: "First router",
            address: "192.168.8.1:8377",
            mac: "DC:04:5A:EB:72:2B"
        )
        let secondHost = try host(
            name: "Second router",
            address: "192.168.9.1:8377",
            mac: "AA:BB:CC:DD:EE:FF"
        )
        try await fixture.hostStore.save(firstHost)
        try await fixture.hostStore.save(secondHost)
        await fixture.model.reloadSavedHosts()
        fixture.model.record(identity: identity(
            id: secondHost.endpoint.peripheralID,
            mac: "AA:BB:CC:DD:EE:FF",
            cid: 0x0305
        ))

        let records = fixture.model.records(bluetooth: [])

        XCTAssertEqual(records.count, 2)
        let first = try XCTUnwrap(records.first { $0.routerHost?.id == firstHost.id })
        XCTAssertNil(first.identity)
        XCTAssertEqual(first.transportOptions, [.router])
        let second = try XCTUnwrap(records.first { $0.routerHost?.id == secondHost.id })
        XCTAssertEqual(second.identity?.macAddress, "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(second.transportOptions, [.router])
    }

    func testRouterEndpointCapabilitiesRemoveUnsupportedSurfacesStructurally() {
        XCTAssertEqual(RouterConnectionModel.canonicalClientEndpoints, [.controls, .usbCLimit])

        let resolved = RouterConnectionModel.capabilities(
            for: identity(mac: "DC:04:5A:EB:72:2B", cid: 0x0302),
            endpoints: RouterConnectionModel.canonicalClientEndpoints
        )

        XCTAssertTrue(resolved.hasDCControl)
        XCTAssertTrue(resolved.hasUSBOutputControl)
        XCTAssertTrue(resolved.hasPowerLimits)
        XCTAssertFalse(resolved.hasScheduler)
    }

    func testManualHostPersistsMetadataAndStoresBearerTokenOnlyInCredentialStore() async throws {
        let fixture = makeFixture()

        let saved = try await fixture.model.saveManualHost(
            address: "router.tailnet.ts.net:8377",
            displayName: "Travel router",
            reachability: .vpn,
            allowsInsecureWAN: false,
            deviceID: "DC:04:5A:EB:72:2B",
            certificateFingerprint: nil,
            token: "secret-bearer"
        )

        XCTAssertEqual(fixture.model.savedHosts, [saved])
        XCTAssertFalse(String(data: try XCTUnwrap(fixture.hostBackend.storedData), encoding: .utf8)?.contains("secret-bearer") == true)
        let savedToken = await fixture.credentialBackend.savedToken
        XCTAssertEqual(savedToken, "secret-bearer")
    }

    func testPairingPayloadEnrollmentPersistsOnlyMetadataAndStoresBearerInCredentialStore() async throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "http://router.local:8377/api/v1/pair")!,
            statusCode: 201,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ))
        let fingerprint = String(repeating: "ab", count: 32)
        let body = Data("""
        {"token":"one-time-secret","device_id":"DC:04:5A:EB:72:2B","base_urls":{"https":"https://router.local:8378/api/v1","http":"http://router.local:8377/api/v1"},"tls_sha256":"\(fingerprint)","magic_dns_name":"router.tailnet.ts.net"}
        """.utf8)
        let enrollmentHTTP = RouterEnrollmentHTTPRecorder(result: .success((body, response)))
        let fixture = makeFixture(enrollmentClientFactory: { _ in
            RouterEnrollmentClient(httpClient: enrollmentHTTP)
        })
        let payload = try RouterPairingPayload.parse(URL(string:
            "wattline://pair?v=1&id=DC045AEB722B&host=router.local&http=8377&https=8378&pin=123456&tls=\(fingerprint)"
        )!)

        let saved = try await fixture.model.enroll(
            payload: payload,
            displayName: "Kitchen router",
            reachability: .lan,
            label: "Keith's iPhone"
        )

        XCTAssertEqual(saved.deviceID, "DC045AEB722B")
        XCTAssertEqual(saved.endpoint.scheme, "https")
        XCTAssertEqual(saved.certificateFingerprint, fingerprint.uppercased())
        XCTAssertEqual(fixture.model.savedHosts, [saved])
        XCTAssertFalse(String(data: try XCTUnwrap(fixture.hostBackend.storedData), encoding: .utf8)?.contains("one-time-secret") == true)
        let savedToken = await fixture.credentialBackend.savedToken
        XCTAssertEqual(savedToken, "one-time-secret")
        let requests = await enrollmentHTTP.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v1/pair")
    }

    func testDiscoveredRouterPINEnrollmentPersistsThenConnects() async throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "http://router.local:8377/api/v1/pair")!,
            statusCode: 201,
            httpVersion: nil,
            headerFields: nil
        ))
        let body = Data(#"{"token":"managed-secret","device_id":"DC:04:5A:EB:72:2B","base_urls":{"https":null,"http":"http://router.local:8377/api/v1"},"tls_sha256":"","magic_dns_name":""}"#.utf8)
        let enrollmentHTTP = RouterEnrollmentHTTPRecorder(result: .success((body, response)))
        let fixture = makeFixture(enrollmentClientFactory: { _ in
            RouterEnrollmentClient(httpClient: enrollmentHTTP)
        })
        let router = DiscoveredRouter(
            deviceID: "DC045AEB722B",
            serviceName: "Kitchen router",
            domain: "local.",
            model: "BP4SL3V2",
            cid: 0x0305,
            features: 0x0000_0fff,
            certificateFingerprint: nil,
            endpoint: RouterEndpoint(
                scheme: "http", host: "router.local", port: 8377,
                certificateFingerprint: nil, allowsInsecureWAN: false
            )
        )
        var connectedHost: RouterHostMetadata?
        let coordinator = RouterEnrollmentCoordinator(
            connections: fixture.model,
            connect: { connectedHost = $0 }
        )

        let saved = try await coordinator.submit(
            pin: "123456",
            label: "Keith iPhone",
            router: router
        )

        XCTAssertEqual(saved.deviceID, "DC045AEB722B")
        XCTAssertEqual(connectedHost, saved)
        let savedToken = await fixture.credentialBackend.savedToken
        XCTAssertEqual(savedToken, "managed-secret")
        let requests = await enrollmentHTTP.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v1/pair")
        let requestJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.body)) as? [String: String]
        )
        XCTAssertEqual(requestJSON, ["pin": "123456", "label": "Keith iPhone"])
    }

    func testEnrollmentDeletesTokenWhenHostMetadataPersistenceFails() async throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "http://router.local:8377/api/v1/pair")!,
            statusCode: 201,
            httpVersion: nil,
            headerFields: nil
        ))
        let body = Data("""
        {"token":"must-be-rolled-back","device_id":"DC:04:5A:EB:72:2B","base_urls":{"https":null,"http":"http://router.local:8377/api/v1"},"tls_sha256":"","magic_dns_name":""}
        """.utf8)
        let enrollmentHTTP = RouterEnrollmentHTTPRecorder(result: .success((body, response)))
        let fixture = makeFixture(
            hostBackend: RouterHostMemoryBackend(setError: RouterHostBackendError.writeFailed),
            enrollmentClientFactory: { _ in RouterEnrollmentClient(httpClient: enrollmentHTTP) }
        )
        let payload = try RouterPairingPayload.parse(URL(string:
            "wattline://pair?v=1&id=DC045AEB722B&host=router.local&http=8377&pin=123456"
        )!)

        do {
            _ = try await fixture.model.enroll(
                payload: payload,
                displayName: "Kitchen router",
                reachability: .lan,
                label: "Keith's iPhone"
            )
            XCTFail("expected host persistence to fail")
        } catch {
            XCTAssertEqual(error as? RouterHostBackendError, .writeFailed)
        }

        let savedToken = await fixture.credentialBackend.savedToken
        XCTAssertNil(savedToken, "failed metadata persistence must roll back the bearer token")
    }

    func testRouterSelectionCreatesNoBluetoothOwnerAndUsesOnlyTheSelectedRouterTransport() async throws {
        let transport = RouterSelectionTransport(identity: identity(mac: "DC:04:5A:EB:72:2B", cid: 0x0302))
        var routerFactoryCount = 0
        var bluetoothFactoryCount = 0
        let fixture = makeFixture(transportFactory: { _, _ in
            routerFactoryCount += 1
            return transport
        })
        let persistence = testPersistence()
        let model = AppModel(
            persistence: persistence,
            transportFactory: {
                bluetoothFactoryCount += 1
                return RouterSelectionTransport(identity: self.identity(mac: nil, cid: nil))
            },
            snapshotCoordinator: nil,
            widgetReloadAdapter: nil,
            liveActivityAdapter: RouterNoopLiveActivityAdapter(),
            routerConnections: fixture.model
        )
        let saved = try await fixture.model.saveManualHost(
            address: "192.168.8.1:8377",
            displayName: "Router",
            reachability: .lan,
            allowsInsecureWAN: false,
            deviceID: "DC:04:5A:EB:72:2B",
            certificateFingerprint: nil,
            token: "token"
        )

        model.connectViaRouter(saved)
        try await waitUntil { await transport.connectCount == 1 }

        XCTAssertEqual(model.activeTransportKind, .router)
        XCTAssertEqual(model.goodCloudSettings.activeHostID, saved.id)
        XCTAssertFalse(model.supportsManualClockControls)
        XCTAssertEqual(routerFactoryCount, 1)
        XCTAssertEqual(bluetoothFactoryCount, 0, "manual router selection must not instantiate CBCentralManager/BLETransport")
        let connectCount = await transport.connectCount
        XCTAssertEqual(connectCount, 1)
    }

    func testBluetoothPreferredRecordSelectsItsMatchingGoodCloudRouterWithoutCreatingAnotherBluetoothOwner() async throws {
        var routerFactoryCount = 0
        let fixture = makeFixture(transportFactory: { _, _ in
            routerFactoryCount += 1
            return RouterSelectionTransport(identity: self.identity(mac: nil, cid: nil))
        })
        let selectedHost = try host(
            name: "Kitchen router",
            address: "192.168.8.1:8377",
            mac: "DC:04:5A:EB:72:2B"
        )
        let otherHost = try host(
            name: "Cabin router",
            address: "192.168.9.1:8377",
            mac: "AA:BB:CC:DD:EE:FF"
        )
        try await fixture.hostStore.save(selectedHost)
        try await fixture.hostStore.save(otherHost)
        await fixture.model.reloadSavedHosts()

        let bluetoothTransport = RouterSelectionTransport(
            identity: identity(mac: selectedHost.deviceID, cid: 0x0302)
        )
        var bluetoothFactoryCount = 0
        let model = AppModel(
            persistence: testPersistence(),
            transportFactory: {
                bluetoothFactoryCount += 1
                return bluetoothTransport
            },
            snapshotCoordinator: nil,
            widgetReloadAdapter: nil,
            liveActivityAdapter: RouterNoopLiveActivityAdapter(),
            routerConnections: fixture.model
        )
        model.requestBluetoothAfterPriming()

        let bluetoothDevice = DiscoveredDevice(
            id: UUID(),
            localName: "Link-Power",
            rssi: -40,
            mode: .application
        )
        let cachedIdentity = AppModel.CachedIdentity(
            advertisedName: bluetoothDevice.localName,
            deviceInformationName: "Link-Power 2",
            macAddress: selectedHost.deviceID
        )
        let record = try XCTUnwrap(fixture.model.scanRecords(
            bluetooth: [bluetoothDevice],
            identities: [bluetoothDevice.id: cachedIdentity]
        ).first { $0.bluetoothDevice?.id == bluetoothDevice.id })
        XCTAssertEqual(record.preferredTransport, .bluetooth)
        XCTAssertEqual(record.routerHost?.id, selectedHost.id)

        model.choose(record)
        try await waitUntil { await bluetoothTransport.connectCount == 1 }

        XCTAssertEqual(model.goodCloudSettings.activeHostID, selectedHost.id)
        XCTAssertEqual(model.activeTransportKind, .bluetooth)
        XCTAssertEqual(routerFactoryCount, 0)
        XCTAssertEqual(bluetoothFactoryCount, 1, "record selection must keep the existing single BLE owner")

        let unmatchedDevice = DiscoveredDevice(
            id: UUID(),
            localName: "Unmatched Link-Power",
            rssi: -45,
            mode: .application
        )
        let unmatchedRecord = try XCTUnwrap(fixture.model.scanRecords(
            bluetooth: [unmatchedDevice],
            identities: [
                unmatchedDevice.id: AppModel.CachedIdentity(
                    advertisedName: unmatchedDevice.localName,
                    deviceInformationName: "Link-Power 2",
                    macAddress: "77:88:99:AA:BB:CC"
                ),
            ]
        ).first { $0.bluetoothDevice?.id == unmatchedDevice.id })
        XCTAssertNil(unmatchedRecord.routerHost)

        model.choose(unmatchedRecord)
        try await waitUntil { await bluetoothTransport.connectCount == 2 }

        XCTAssertNil(model.goodCloudSettings.activeHostID)
        XCTAssertEqual(bluetoothFactoryCount, 1, "switching BLE devices must retain exactly one BLE owner")
    }

    func testBluetoothRecordWithDuplicateMACHostsKeepsGoodCloudSelectionAmbiguous() async throws {
        let discoverySource = RouterWiringDiscoverySource()
        var routerFactoryCount = 0
        let fixture = makeFixture(
            discovery: RouterDiscovery(source: discoverySource),
            transportFactory: { _, _ in
                routerFactoryCount += 1
                return RouterSelectionTransport(identity: self.identity(mac: nil, cid: nil))
            }
        )
        let firstHost = try host(
            name: "Kitchen LAN",
            address: "192.168.8.1:8377",
            mac: "DC:04:5A:EB:72:2B"
        )
        let secondHost = try host(
            name: "Kitchen VPN",
            address: "kitchen.tailnet.ts.net:8377",
            reachability: .vpn,
            mac: "dc-04-5a-eb-72-2b"
        )
        try await fixture.hostStore.save(firstHost)
        try await fixture.hostStore.save(secondHost)
        await fixture.model.reloadSavedHosts()

        let associationStore = GoodCloudAssociationStore(
            backend: RouterWiringAssociationBackend()
        )
        for (host, deviceID) in [(firstHost, "first"), (secondHost, "second")] {
            try await associationStore.save(GoodCloudAssociation(
                hostID: host.id,
                routerMAC: try XCTUnwrap(host.deviceID),
                device: GoodCloudDeviceSummary(
                    id: deviceID,
                    name: host.displayName,
                    mac: try XCTUnwrap(host.deviceID),
                    ddns: nil,
                    model: "GL-X3000",
                    isOnline: true
                )
            ))
        }
        let settings = GoodCloudSettingsModel(
            account: nil,
            associations: associationStore,
            connections: fixture.model
        )

        let bluetoothTransport = RouterSelectionTransport(
            identity: identity(mac: "DC045AEB722B", cid: 0x0302)
        )
        var bluetoothFactoryCount = 0
        let model = AppModel(
            persistence: testPersistence(),
            transportFactory: {
                bluetoothFactoryCount += 1
                return bluetoothTransport
            },
            snapshotCoordinator: nil,
            widgetReloadAdapter: nil,
            liveActivityAdapter: RouterNoopLiveActivityAdapter(),
            routerConnections: fixture.model,
            goodCloudSettings: settings
        )
        model.requestBluetoothAfterPriming()

        fixture.model.startDiscovery()
        try await waitUntil { discoverySource.startCount == 1 }
        discoverySource.yield([
            RouterServiceRecord(
                serviceName: "Kitchen router",
                domain: "local.",
                host: "kitchen.local.",
                port: 8377,
                txt: [
                    "api": Data("1".utf8),
                    "auth": Data("pin".utf8),
                    "id": Data("DC:04:5A:EB:72:2B".utf8),
                    "model": Data("BP4SL3V2".utf8),
                    "cid": Data("0302".utf8),
                    "features": Data("00000fff".utf8),
                    "tls": Data("none".utf8),
                ]
            ),
        ])
        try await waitUntil { await fixture.model.discoveredRouters.count == 1 }

        let bluetoothDevice = DiscoveredDevice(
            id: UUID(),
            localName: "Link-Power",
            rssi: -40,
            mode: .application
        )
        let record = try XCTUnwrap(fixture.model.scanRecords(
            bluetooth: [bluetoothDevice],
            identities: [
                bluetoothDevice.id: AppModel.CachedIdentity(
                    advertisedName: bluetoothDevice.localName,
                    deviceInformationName: "Link-Power 2",
                    macAddress: "DC045AEB722B"
                ),
            ]
        ).first { $0.bluetoothDevice?.id == bluetoothDevice.id })

        XCTAssertNotNil(record.discoveredRouter)
        XCTAssertNil(record.routerHost)
        XCTAssertEqual(record.transportOptions, [.bluetooth, .router])

        model.choose(record)
        try await waitUntil { await bluetoothTransport.connectCount == 1 }
        await settings.load()

        XCTAssertNil(settings.activeHostID)
        XCTAssertNil(settings.association)
        XCTAssertEqual(routerFactoryCount, 0)
        XCTAssertEqual(bluetoothFactoryCount, 1, "ambiguous routing must retain exactly one BLE owner")
    }

    func testReturningBluetoothSessionSelectsMatchingGoodCloudRouterWithTwoSavedHosts() async throws {
        var routerFactoryCount = 0
        let fixture = makeFixture(transportFactory: { _, _ in
            routerFactoryCount += 1
            return RouterSelectionTransport(identity: self.identity(mac: nil, cid: nil))
        })
        let selectedHost = try host(
            name: "Kitchen router",
            address: "192.168.8.1:8377",
            mac: "DC:04:5A:EB:72:2B"
        )
        let otherHost = try host(
            name: "Cabin router",
            address: "192.168.9.1:8377",
            mac: "AA:BB:CC:DD:EE:FF"
        )
        try await fixture.hostStore.save(selectedHost)
        try await fixture.hostStore.save(otherHost)

        let peripheralID = UUID()
        let persistence = testPersistence()
        persistence.onboardingComplete = true
        persistence.lastSuccessfulPeripheralID = peripheralID
        persistence.saveKnownDevices([
            peripheralID: AppModel.CachedIdentity(
                advertisedName: "Link-Power",
                deviceInformationName: "Link-Power 2",
                macAddress: selectedHost.deviceID
            ),
        ])
        let bluetoothTransport = RouterSelectionTransport(
            identity: identity(id: peripheralID, mac: selectedHost.deviceID, cid: 0x0302)
        )
        var bluetoothFactoryCount = 0

        let model = AppModel(
            persistence: persistence,
            transportFactory: {
                bluetoothFactoryCount += 1
                return bluetoothTransport
            },
            snapshotCoordinator: nil,
            widgetReloadAdapter: nil,
            liveActivityAdapter: RouterNoopLiveActivityAdapter(),
            routerConnections: fixture.model
        )
        try await waitUntil { await model.goodCloudSettings.activeHostID != nil }

        XCTAssertEqual(model.goodCloudSettings.activeHostID, selectedHost.id)
        XCTAssertEqual(model.activeTransportKind, .bluetooth)
        XCTAssertEqual(routerFactoryCount, 0)
        XCTAssertEqual(bluetoothFactoryCount, 1, "returning session must retain exactly one BLE owner")
    }

    func testReturningHostLookupRejectsDuplicateMACAmbiguity() async throws {
        let fixture = makeFixture()
        let first = try host(
            name: "Kitchen LAN",
            address: "192.168.8.1:8377",
            mac: "DC:04:5A:EB:72:2B"
        )
        let second = try host(
            name: "Kitchen VPN",
            address: "kitchen.tailnet.ts.net:8377",
            reachability: .vpn,
            mac: "dc-04-5a-eb-72-2b"
        )
        try await fixture.hostStore.save(first)
        try await fixture.hostStore.save(second)

        let match = await fixture.model.savedHost(matchingDeviceMAC: "DC045AEB722B")

        XCTAssertNil(match)
    }

    func testProductionUsesOneGoodCloudServiceForAssociatedRouterWithoutCreatingBLEOwner() async throws {
        let suite = "RouterAppWiringTests.GoodCloud.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let device = GoodCloudDeviceSummary(
            id: "42",
            name: "Wattline X3000",
            mac: "DC:04:5A:EB:72:2B",
            ddns: "wattline.glddns.com",
            model: "GL-X3000",
            isOnline: true
        )
        let account = GoodCloudAccountService.accountOnly(
            client: RouterWiringGoodCloudClient(devices: [device])
        )
        let associationStore = GoodCloudAssociationStore(
            backend: RouterWiringAssociationBackend()
        )
        var accountFactoryCount = 0
        var associationFactoryCount = 0
        var directFactoryCount = 0
        var preferredFactoryDeviceIDs: [String] = []
        let preferredTransport = RouterSelectionTransport(
            identity: identity(mac: "DC:04:5A:EB:72:2B", cid: 0x0302)
        )
        let connections = RouterConnectionModel.production(
            defaults: defaults,
            goodCloudAccountFactory: {
                accountFactoryCount += 1
                return RouterConnectionModel.GoodCloudAccountDependencies(
                    account: account,
                    provisioner: account
                )
            },
            goodCloudAssociationStoreFactory: {
                associationFactoryCount += 1
                return associationStore
            },
            directTransportFactory: { _, _ in
                directFactoryCount += 1
                return RouterSelectionTransport(identity: self.identity(mac: nil, cid: nil))
            },
            preferredTransportFactory: { _, _, association, _ in
                preferredFactoryDeviceIDs.append(association.goodCloudDeviceID)
                return preferredTransport
            }
        )
        let saved = try host(
            name: "Router",
            address: "192.168.8.1:8377",
            mac: "DC:04:5A:EB:72:2B"
        )
        try await connections.hostStore.save(saved)
        try await associationStore.save(
            GoodCloudAssociation(
                hostID: saved.id,
                routerMAC: "DC045AEB722B",
                device: device
            )
        )
        await connections.reloadSavedHosts()

        var bluetoothFactoryCount = 0
        let model = AppModel(
            persistence: testPersistence(),
            transportFactory: {
                bluetoothFactoryCount += 1
                return RouterSelectionTransport(identity: self.identity(mac: nil, cid: nil))
            },
            snapshotCoordinator: nil,
            widgetReloadAdapter: nil,
            liveActivityAdapter: RouterNoopLiveActivityAdapter(),
            routerConnections: connections
        )
        model.connectViaRouter(saved)
        try await waitUntil { await preferredTransport.connectCount == 1 }

        XCTAssertEqual(accountFactoryCount, 1)
        XCTAssertEqual(associationFactoryCount, 1)
        XCTAssertEqual(preferredFactoryDeviceIDs, ["42"])
        XCTAssertEqual(directFactoryCount, 0)
        XCTAssertEqual(bluetoothFactoryCount, 0)
    }

    func testAdministrationUsesRouterConnectionHTTPRouteFactory() async throws {
        let recorder = RouterAdministrationHTTPFactoryRecorder()
        let connections = RouterConnectionModel(
            hostStore: RouterHostStore(backend: RouterHostMemoryBackend()),
            credentialStore: RouterCredentialStore(backend: RouterCredentialMemoryBackend()),
            enrollmentClientFactory: { _ in
                throw NetworkError.unsupported("not used")
            },
            transportFactory: { _, _ in
                RouterSelectionTransport(identity: self.identity(mac: nil, cid: nil))
            },
            administrationHTTPFactory: { endpoint in
                recorder.makeClient(endpoint: endpoint)
            }
        )
        let administration = RouterAdministrationModel.production(connections: connections)
        let saved = try host(
            name: "Router",
            address: "192.168.8.1:8377",
            mac: "DC:04:5A:EB:72:2B"
        )

        await administration.begin(host: saved)

        XCTAssertEqual(recorder.endpoints, [saved.endpoint, saved.endpoint])
    }

    func testRealAccountExpiryRevokesRemoteRouteBeforeRequestReturnsWithoutSettingsListener() async throws {
        let saved = try host(
            name: "Router",
            address: "192.168.8.1:8377",
            mac: "DC:04:5A:EB:72:2B"
        )
        let device = GoodCloudDeviceSummary(
            id: "42",
            name: "Wattline X3000",
            mac: "DC:04:5A:EB:72:2B",
            ddns: nil,
            model: "GL-X3000",
            isOnline: true
        )
        let account = GoodCloudAccountService.accountOnly(
            client: RouterWiringGoodCloudClient(devices: [device]),
            injectedRemoteAccessFailure: .sessionExpired
        )
        let hostStore = RouterHostStore(backend: RouterHostMemoryBackend())
        try await hostStore.save(saved)
        var directTransportCount = 0
        var preferredTransportCount = 0
        let model = RouterConnectionModel(
            hostStore: hostStore,
            credentialStore: RouterCredentialStore(backend: RouterCredentialMemoryBackend()),
            enrollmentClientFactory: { _ in throw NetworkError.unsupported("not used") },
            transportFactory: { _, _ in
                directTransportCount += 1
                return RouterSelectionTransport(identity: self.identity(mac: nil, cid: nil))
            },
            goodCloudAccount: .init(account: account, provisioner: account),
            goodCloudAssociationLoader: {
                [GoodCloudAssociation(
                    hostID: saved.id,
                    routerMAC: "DC045AEB722B",
                    device: device
                )]
            },
            preferredTransportFactory: { _, _, _, _ in
                preferredTransportCount += 1
                return RouterSelectionTransport(identity: self.identity(mac: nil, cid: nil))
            }
        )
        await model.reloadSavedHosts()
        _ = try model.makeTransport(for: saved)
        XCTAssertEqual(preferredTransportCount, 1)

        let coordinator = GoodCloudRelayCoordinator.production(
            deviceID: device.id,
            provisioner: account
        )
        do {
            _ = try await coordinator.request(
                method: "GET",
                path: "/api/v1/status",
                headers: [:],
                body: nil
            )
            XCTFail("Expected the expired GoodCloud session to reject the request")
        } catch {
            XCTAssertEqual(error as? NetworkError, .goodCloudSessionExpired)
        }

        _ = try model.makeTransport(for: saved)
        XCTAssertEqual(directTransportCount, 1)
        XCTAssertEqual(preferredTransportCount, 1)
    }

    func testOlderAuthenticatedRefreshCannotRepublishRemoteAccessAfterLogoutRefresh() async throws {
        let saved = try host(
            name: "Router",
            address: "192.168.8.1:8377",
            mac: "DC:04:5A:EB:72:2B"
        )
        let device = GoodCloudDeviceSummary(
            id: "42",
            name: "Wattline X3000",
            mac: "DC:04:5A:EB:72:2B",
            ddns: "wattline.glddns.com",
            model: "GL-X3000",
            isOnline: true
        )
        let account = SequencedGoodCloudAccount(states: [
            .authenticated([device]),
            .authenticated([device]),
            .loggedOut,
        ])
        let provisioner = GoodCloudAccountService.accountOnly(
            client: RouterWiringGoodCloudClient(devices: [])
        )
        let associationLoader = ControllableGoodCloudAssociationLoader(
            associations: [
                GoodCloudAssociation(
                    hostID: saved.id,
                    routerMAC: "DC045AEB722B",
                    device: device
                ),
            ]
        )

        let hostStore = RouterHostStore(backend: RouterHostMemoryBackend())
        try await hostStore.save(saved)
        let administrationRecorder = RouteFactoryRecorder()
        let administrationRegistry = GoodCloudAdministrationHTTPRegistry(
            directFactory: { endpoint in
                administrationRecorder.makeDirectClient(endpoint: endpoint)
            },
            preferredFactory: { endpoint, _, _ in
                administrationRecorder.makePreferredClient(endpoint: endpoint)
            }
        )
        var directTransportCount = 0
        var preferredTransportCount = 0
        let model = RouterConnectionModel(
            hostStore: hostStore,
            credentialStore: RouterCredentialStore(backend: RouterCredentialMemoryBackend()),
            enrollmentClientFactory: { _ in
                throw NetworkError.unsupported("not used")
            },
            transportFactory: { _, _ in
                directTransportCount += 1
                return RouterSelectionTransport(identity: self.identity(mac: nil, cid: nil))
            },
            goodCloudAccount: .init(account: account, provisioner: provisioner),
            goodCloudAssociationLoader: { await associationLoader.load() },
            preferredTransportFactory: { _, _, _, _ in
                preferredTransportCount += 1
                return RouterSelectionTransport(identity: self.identity(mac: nil, cid: nil))
            },
            administrationHTTPFactory: { endpoint in
                try administrationRegistry.client(for: endpoint)
            },
            goodCloudAdministrationHTTPRegistry: administrationRegistry
        )

        await model.reloadSavedHosts()
        _ = try model.makeTransport(for: saved)
        _ = try model.administrationHTTPFactory(saved.endpoint)
        await associationLoader.holdNext()

        let olderRefresh = Task {
            await model.reloadSavedHosts()
        }
        do {
            try await waitUntil(timeout: .seconds(2)) {
                await associationLoader.isBlocked
            }
        } catch {
            olderRefresh.cancel()
            await associationLoader.disarm()
            await olderRefresh.value
            throw error
        }
        await model.refreshGoodCloudRemoteAccess()
        await associationLoader.release()
        olderRefresh.cancel()
        await olderRefresh.value

        _ = try model.makeTransport(for: saved)
        _ = try model.administrationHTTPFactory(saved.endpoint)

        XCTAssertEqual(directTransportCount, 1)
        XCTAssertEqual(preferredTransportCount, 1)
        XCTAssertEqual(administrationRecorder.directCount, 1)
        XCTAssertEqual(administrationRecorder.preferredCount, 1)
    }

    private func makeFixture(
        hostBackend: RouterHostMemoryBackend = RouterHostMemoryBackend(),
        discovery: RouterDiscovery? = nil,
        enrollmentClientFactory: @escaping RouterConnectionModel.EnrollmentClientFactory = { _ in
            throw NetworkError.unsupported("Enrollment client not configured")
        },
        transportFactory: @escaping RouterConnectionModel.TransportFactory = { _, _ in
            RouterSelectionTransport(identity: RouterAppWiringTests.identity(mac: nil, cid: nil))
        }
    ) -> RouterFixture {
        let credentialBackend = RouterCredentialMemoryBackend()
        let hostStore = RouterHostStore(backend: hostBackend)
        let credentialStore = RouterCredentialStore(backend: credentialBackend)
        return RouterFixture(
            model: RouterConnectionModel(
                hostStore: hostStore,
                credentialStore: credentialStore,
                discovery: discovery,
                enrollmentClientFactory: enrollmentClientFactory,
                transportFactory: transportFactory
            ),
            hostStore: hostStore,
            hostBackend: hostBackend,
            credentialBackend: credentialBackend
        )
    }

    private func host(
        name: String,
        address: String,
        reachability: RouterHostReachability = .lan,
        mac: String
    ) throws -> RouterHostMetadata {
        try RouterHostValidator.validate(
            address,
            displayName: name,
            reachability: reachability,
            allowsInsecureWAN: false,
            deviceID: mac,
            certificateFingerprint: nil
        )
    }

    nonisolated private static func identity(
        id: UUID = UUID(),
        mac: String?,
        cid: UInt16?
    ) -> DeviceIdentitySnapshot {
        let features: FeatureFlags = [
            .batteryCapacity, .dcPort, .dcControl, .dcScheduler,
            .usbPort, .usbPowerLimit, .usbOutputControl, .shutdown,
        ]
        return DeviceIdentitySnapshot(
            peripheralID: id,
            advertisedName: "Link-Power",
            mode: .application,
            modelNumber: "BP4SL3V2",
            hardwareRevision: "2.1",
            otaFirmwareRevision: nil,
            appFirmwareRevision: "1.4.9",
            cid: cid,
            rawFeatures: features.rawValue,
            macAddress: mac,
            capabilities: DeviceCapabilities(features: features)
        )
    }

    private func identity(
        id: UUID = UUID(),
        mac: String?,
        cid: UInt16?
    ) -> DeviceIdentitySnapshot {
        Self.identity(id: id, mac: mac, cid: cid)
    }

    private func testPersistence() -> AppPersistence {
        let suite = "RouterAppWiringTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppPersistence(defaults: defaults)
    }
}

private struct RouterFixture {
    let model: RouterConnectionModel
    let hostStore: RouterHostStore
    let hostBackend: RouterHostMemoryBackend
    let credentialBackend: RouterCredentialMemoryBackend
}

private final class RouterHostMemoryBackend: RouterHostKeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private let setError: (any Error)?

    init(setError: (any Error)? = nil) {
        self.setError = setError
    }

    var storedData: Data? { lock.withLock { data } }
    func data(forKey key: String) -> Data? { storedData }
    func set(_ data: Data, forKey key: String) throws {
        if let setError { throw setError }
        lock.withLock { self.data = data }
    }
    func removeValue(forKey key: String) { lock.withLock { data = nil } }
}

private enum RouterHostBackendError: Error, Equatable {
    case writeFailed
}

private actor RouterWiringGoodCloudClient: GoodCloudAccountClient {
    private let storedDevices: [GoodCloudDeviceSummary]

    init(devices: [GoodCloudDeviceSummary]) {
        storedDevices = devices
    }

    func hasStoredToken() async -> Bool { true }
    func login(email: String, password: String) async throws {}
    func devices() async throws -> [GoodCloudDeviceSummary] { storedDevices }
    func logout() async throws {}
}

private final class RouterWiringAssociationBackend: GoodCloudAssociationKeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(forKey key: String) -> Data? {
        lock.withLock { values[key] }
    }

    func set(_ data: Data?, forKey key: String) {
        lock.withLock { values[key] = data }
    }
}

private final class RouterWiringDiscoverySource: RouterDiscoverySource, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<[RouterServiceRecord]>.Continuation?
    private var starts = 0

    var startCount: Int { lock.withLock { starts } }

    func snapshots(serviceType: String) -> AsyncStream<[RouterServiceRecord]> {
        AsyncStream { continuation in
            lock.withLock {
                starts += 1
                self.continuation = continuation
            }
        }
    }

    func yield(_ records: [RouterServiceRecord]) {
        lock.withLock { continuation }?.yield(records)
    }
}

private actor SequencedGoodCloudAccount: GoodCloudAccountServing {
    private var states: [GoodCloudSessionState]

    init(states: [GoodCloudSessionState]) {
        self.states = states
    }

    func validateStoredSession() async -> GoodCloudSessionState {
        states.removeFirst()
    }

    func login(email: String, password: String) async -> GoodCloudSessionState { .loggedOut }
    func refreshDevices() async -> GoodCloudSessionState { .loggedOut }
    func logout() async -> GoodCloudSessionState { .loggedOut }
}

private actor ControllableGoodCloudAssociationLoader {
    private let associations: [GoodCloudAssociation]
    private var shouldHoldNext = false
    private var holdContinuation: CheckedContinuation<Void, Never>?
    private(set) var isBlocked = false

    init(associations: [GoodCloudAssociation]) {
        self.associations = associations
    }

    func holdNext() {
        shouldHoldNext = true
    }

    func load() async -> [GoodCloudAssociation] {
        guard shouldHoldNext else { return associations }
        shouldHoldNext = false
        guard !Task.isCancelled else { return associations }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    isBlocked = true
                    holdContinuation = continuation
                }
            }
        } onCancel: {
            Task { await self.release() }
        }
        return associations
    }

    func release() {
        isBlocked = false
        let continuation = holdContinuation
        holdContinuation = nil
        continuation?.resume()
    }

    func disarm() {
        shouldHoldNext = false
        release()
    }
}

private final class RouteFactoryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedDirectCount = 0
    private var recordedPreferredCount = 0

    var directCount: Int { lock.withLock { recordedDirectCount } }
    var preferredCount: Int { lock.withLock { recordedPreferredCount } }

    func makeDirectClient(endpoint: RouterEndpoint) -> any RouterHTTPClient {
        lock.withLock { recordedDirectCount += 1 }
        return RouterAdministrationNoopHTTPClient()
    }

    func makePreferredClient(endpoint: RouterEndpoint) -> any RouterHTTPClient {
        lock.withLock { recordedPreferredCount += 1 }
        return RouterAdministrationNoopHTTPClient()
    }
}

private final class RouterAdministrationHTTPFactoryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEndpoints: [RouterEndpoint] = []

    var endpoints: [RouterEndpoint] { lock.withLock { recordedEndpoints } }

    func makeClient(endpoint: RouterEndpoint) -> any RouterHTTPClient {
        lock.withLock { recordedEndpoints.append(endpoint) }
        return RouterAdministrationNoopHTTPClient()
    }
}

private actor RouterAdministrationNoopHTTPClient: RouterHTTPClient {
    func get(_ path: String, token: String) async throws -> (Data, HTTPURLResponse) {
        try await request("GET", path, body: nil, token: token)
    }

    func request(
        _ method: String,
        _ path: String,
        body: Data?,
        token: String
    ) async throws -> (Data, HTTPURLResponse) {
        throw NetworkError.unsupported("request not expected")
    }
}

private actor RouterEnrollmentHTTPRecorder: RouterEnrollmentHTTPClient {
    struct Request: Sendable {
        let method: String
        let path: String
        let body: Data?
    }

    private let result: Result<(Data, HTTPURLResponse), any Error>
    private(set) var requests: [Request] = []

    init(result: Result<(Data, HTTPURLResponse), any Error>) {
        self.result = result
    }

    func publicRequest(
        _ method: String,
        _ path: String,
        body: Data?
    ) async throws -> (Data, HTTPURLResponse) {
        requests.append(Request(method: method, path: path, body: body))
        return try result.get()
    }
}

private actor RouterCredentialMemoryBackend: RouterCredentialBackend {
    private var data: Data?
    var savedToken: String? { data.flatMap { String(data: $0, encoding: .utf8) } }
    func read(account: String) async throws -> Data? { data }
    func save(_ data: Data, account: String) async throws { self.data = data }
    func delete(account: String) async throws { data = nil }
}

private actor RouterSelectionTransport: DeviceTransport {
    nonisolated let events: AsyncStream<DeviceEvent>
    private let continuation: AsyncStream<DeviceEvent>.Continuation
    private let identity: DeviceIdentitySnapshot
    private(set) var connectCount = 0

    init(identity: DeviceIdentitySnapshot) {
        self.identity = identity
        let pair = AsyncStream<DeviceEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    func startScan() async throws {}
    func stopScan() async {}
    func makeConnectionScope(for id: UUID) async -> DeviceConnectionScope {
        DeviceConnectionScope(peripheralID: id, sessionID: UUID())
    }
    func connect(to id: UUID, scope: DeviceConnectionScope) async throws {
        connectCount += 1
        let snapshot = DeviceIdentitySnapshot(
            peripheralID: id,
            advertisedName: identity.advertisedName,
            mode: identity.mode,
            modelNumber: identity.modelNumber,
            hardwareRevision: identity.hardwareRevision,
            otaFirmwareRevision: identity.otaFirmwareRevision,
            appFirmwareRevision: identity.appFirmwareRevision,
            cid: identity.cid,
            rawFeatures: identity.rawFeatures,
            macAddress: identity.macAddress,
            capabilities: identity.capabilities
        )
        continuation.yield(.handshakeCompleted(snapshot, scope: scope))
        continuation.yield(.connected(scope))
    }
    func disconnect() async {}
    func perform(_ command: DeviceCommand) async throws -> CommandOutcome { .sent }
    func refreshTelemetry() async throws {}
    func synchronizeDeviceTime() async throws {}
    func readDeviceTimeIfSupported() async throws -> Date? { nil }
}

private struct RouterNoopLiveActivityAdapter: LiveActivityAdapter {
    func request(state: WattlineActivityAttributes.ContentState) async throws {}
    func update(state: WattlineActivityAttributes.ContentState) async throws {}
    func end() async {}
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
