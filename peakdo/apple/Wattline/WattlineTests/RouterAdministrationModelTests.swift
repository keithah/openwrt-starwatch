import Foundation
import WattlineCore
import WattlineNetwork
import XCTest
@testable import Wattline

@MainActor
final class RouterAdministrationModelTests: XCTestCase {
    func testProductionFactorySharesSuppliedConnectionCredentialsAcrossRoles() async throws {
        let fixture = try await makeFixture(results: [])
        let http = AdminScriptedHTTP(
            results: [AdminScriptedHTTP.ok("[]"), AdminScriptedHTTP.ok("{}")],
            gateRequests: false
        )
        let model = RouterAdministrationModel.production(
            connections: fixture.connections,
            httpFactory: { _ in http }
        )

        await model.open(host: fixture.host)
        await model.unlock(token: "boot-admin")

        XCTAssertEqual(http.calls, [
            AdminScriptedHTTP.Call(
                method: "GET", path: "/api/v1/history", token: "wlt_client"
            ),
            AdminScriptedHTTP.Call(
                method: "GET", path: "/api/v1/settings", token: "boot-admin"
            ),
        ])
        let storedAdmin = try await fixture.credentialStore.readToken(
            for: fixture.host.endpoint,
            role: .administrator
        )
        XCTAssertEqual(storedAdmin, "boot-admin")
    }

    func testOpenEstablishesHostThenFetchesHistoryExactlyOnce() async throws {
        let fixture = try await makeFixture(
            results: [],
            historyResults: [AdminScriptedHTTP.ok("[]")]
        )

        await fixture.model.open(host: fixture.host)

        XCTAssertEqual(fixture.model.host, fixture.host)
        XCTAssertEqual(fixture.model.historyLoadState, .loaded)
        XCTAssertEqual(fixture.historyHTTP.calls, [AdminScriptedHTTP.Call(
            method: "GET",
            path: "/api/v1/history",
            token: "wlt_client"
        )])
    }

    func testInitialHistoryFailureTransitionsThroughLoadingWithoutFabricatingEmptySuccess() async throws {
        let fixture = try await makeFixture(
            results: [],
            historyResults: [.failure(NetworkError.timeout)],
            historyGateRequests: true
        )
        await fixture.model.begin(host: fixture.host)
        XCTAssertEqual(fixture.model.historyLoadState, .neverLoaded)

        let reload = Task { await fixture.model.reloadHistory() }
        await fixture.historyHTTP.waitForGateRegistration()

        XCTAssertEqual(fixture.model.historyLoadState, .initialLoading)
        XCTAssertEqual(fixture.model.history, [])
        XCTAssertNil(fixture.model.historyError)

        fixture.historyHTTP.releaseGates()
        await reload.value

        XCTAssertEqual(fixture.model.historyLoadState, .failed)
        XCTAssertEqual(fixture.model.history, [])
        XCTAssertEqual(fixture.model.historyError, "Could not load router history.")
    }

    func testSuccessfulEmptyHistoryIsLoadedRatherThanNeverLoaded() async throws {
        let fixture = try await makeFixture(
            results: [],
            historyResults: [AdminScriptedHTTP.ok("[]")]
        )
        await fixture.model.begin(host: fixture.host)

        await fixture.model.reloadHistory()

        XCTAssertEqual(fixture.model.historyLoadState, .loaded)
        XCTAssertEqual(fixture.model.history, [])
        XCTAssertNotNil(fixture.model.historyFetchedAt)
        XCTAssertNil(fixture.model.historyError)
    }

    func testRefreshingExistingHistoryClearsErrorAndPreservesSamplesWhileLoading() async throws {
        let existing = #"[{"at":"2026-07-17T19:58:00Z","level":41,"status":-1}]"#
        let refreshed = #"[{"at":"2026-07-17T20:00:00Z","level":89,"status":1}]"#
        let fixture = try await makeFixture(
            results: [],
            historyResults: [
                AdminScriptedHTTP.ok(existing),
                .failure(NetworkError.timeout),
                AdminScriptedHTTP.ok(refreshed),
            ],
            historyGatedCallNumbers: [3]
        )
        await fixture.model.begin(host: fixture.host)
        await fixture.model.reloadHistory()
        await fixture.model.reloadHistory()
        XCTAssertEqual(fixture.model.history.first?.level, 41)
        XCTAssertEqual(fixture.model.historyLoadState, .failed)
        XCTAssertNotNil(fixture.model.historyError)

        let reload = Task { await fixture.model.reloadHistory() }
        await fixture.historyHTTP.waitForGateRegistration()

        XCTAssertEqual(fixture.model.historyLoadState, .refreshing)
        XCTAssertEqual(fixture.model.history.first?.level, 41)
        XCTAssertNil(fixture.model.historyError)

        fixture.historyHTTP.releaseGates()
        await reload.value

        XCTAssertEqual(fixture.model.historyLoadState, .loaded)
        XCTAssertEqual(fixture.model.history.first?.level, 89)
        XCTAssertNil(fixture.model.historyError)
    }

    func testLockDoesNotInvalidateInFlightHistorySuccess() async throws {
        let existing = #"[{"at":"2026-07-17T19:59:00Z","level":41,"status":-1}]"#
        let refreshed = #"[{"at":"2026-07-17T20:00:00Z","level":73,"status":1}]"#
        let fixture = try await makeFixture(
            results: [],
            historyResults: [AdminScriptedHTTP.ok(existing), AdminScriptedHTTP.ok(refreshed)],
            historyGatedCallNumbers: [2]
        )
        await fixture.model.begin(host: fixture.host)
        await fixture.model.reloadHistory()
        XCTAssertEqual(fixture.model.history.first?.level, 41)

        let reload = Task { await fixture.model.reloadHistory() }
        await fixture.historyHTTP.waitForGateRegistration()
        await fixture.model.lock()
        XCTAssertEqual(fixture.model.access, .locked)
        XCTAssertEqual(fixture.model.history.first?.level, 41)
        XCTAssertEqual(fixture.model.historyLoadState, .refreshing)

        fixture.historyHTTP.releaseGates()
        await reload.value

        XCTAssertEqual(fixture.model.history.first?.level, 73)
        XCTAssertEqual(fixture.model.historyLoadState, .loaded)
        XCTAssertNotNil(fixture.model.historyFetchedAt)
        XCTAssertNil(fixture.model.historyError)
    }

    func testLockDoesNotStrandInFlightHistoryError() async throws {
        let existing = #"[{"at":"2026-07-17T19:59:00Z","level":41,"status":-1}]"#
        let fixture = try await makeFixture(
            results: [],
            historyResults: [AdminScriptedHTTP.ok(existing), .failure(NetworkError.timeout)],
            historyGatedCallNumbers: [2]
        )
        await fixture.model.begin(host: fixture.host)
        await fixture.model.reloadHistory()
        XCTAssertEqual(fixture.model.history.first?.level, 41)

        let reload = Task { await fixture.model.reloadHistory() }
        await fixture.historyHTTP.waitForGateRegistration()
        await fixture.model.lock()
        XCTAssertEqual(fixture.model.access, .locked)
        XCTAssertEqual(fixture.model.history.first?.level, 41)
        XCTAssertEqual(fixture.model.historyLoadState, .refreshing)

        fixture.historyHTTP.releaseGates()
        await reload.value

        XCTAssertEqual(fixture.model.history.first?.level, 41)
        XCTAssertEqual(fixture.model.historyLoadState, .failed)
        XCTAssertNotNil(fixture.model.historyFetchedAt)
        XCTAssertEqual(fixture.model.historyError, "Could not load router history.")
    }

    func testOlderSameSessionHistorySuccessCannotOverwriteNewerSuccess() async throws {
        let older = #"[{"at":"2026-07-17T19:58:00Z","level":41,"status":-1}]"#
        let newer = #"[{"at":"2026-07-17T20:00:00Z","level":89,"status":1}]"#
        let newerFetchedAt = Date(timeIntervalSince1970: 1_800_000_100)
        let staleFetchedAt = Date(timeIntervalSince1970: 1_800_000_200)
        var clockValues = [newerFetchedAt, staleFetchedAt]
        let fixture = try await makeFixture(
            results: [],
            historyResults: [AdminScriptedHTTP.ok(older), AdminScriptedHTTP.ok(newer)],
            now: { clockValues.removeFirst() },
            historyGateRequests: true
        )
        await fixture.model.begin(host: fixture.host)

        let olderReload = Task { await fixture.model.reloadHistory() }
        await fixture.historyHTTP.waitForGateRegistration()
        let newerReload = Task { await fixture.model.reloadHistory() }
        await fixture.historyHTTP.waitForCallCount(2)
        fixture.historyHTTP.releaseNewestGate()
        await newerReload.value
        XCTAssertEqual(fixture.model.history.first?.level, 89)
        XCTAssertEqual(fixture.model.historyFetchedAt, newerFetchedAt)

        fixture.historyHTTP.releaseGates()
        await olderReload.value

        XCTAssertEqual(fixture.model.history.first?.level, 89)
        XCTAssertEqual(fixture.model.historyFetchedAt, newerFetchedAt)
        XCTAssertEqual(clockValues, [staleFetchedAt])
    }

    func testOlderSameSessionHistoryErrorCannotOverwriteNewerSuccess() async throws {
        let newer = #"[{"at":"2026-07-17T20:00:00Z","level":89,"status":1}]"#
        let fixture = try await makeFixture(
            results: [],
            historyResults: [.failure(NetworkError.timeout), AdminScriptedHTTP.ok(newer)],
            historyGateRequests: true
        )
        await fixture.model.begin(host: fixture.host)

        let olderReload = Task { await fixture.model.reloadHistory() }
        await fixture.historyHTTP.waitForGateRegistration()
        let newerReload = Task { await fixture.model.reloadHistory() }
        await fixture.historyHTTP.waitForCallCount(2)
        fixture.historyHTTP.releaseNewestGate()
        await newerReload.value
        XCTAssertEqual(fixture.model.history.first?.level, 89)
        XCTAssertNil(fixture.model.historyError)

        fixture.historyHTTP.releaseGates()
        await olderReload.value

        XCTAssertEqual(fixture.model.history.first?.level, 89)
        XCTAssertNil(fixture.model.historyError)
    }

    func testReloadHistoryIsLazyStampsFetchTimeAndQuarantinesStaleSessions() async throws {
        let sample = #"[{"at":"2026-07-17T19:59:00Z","level":77,"status":1,"dc_w":12.0,"typec_w":20.0}]"#
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try await makeFixture(
            results: [AdminScriptedHTTP.ok("{}")],
            historyResults: [AdminScriptedHTTP.ok(sample)],
            now: { fixedNow }
        )
        await fixture.model.begin(host: fixture.host)
        XCTAssertEqual(fixture.model.history, [])
        XCTAssertNil(fixture.model.historyFetchedAt)

        await fixture.model.reloadHistory()

        XCTAssertEqual(fixture.model.history.count, 1)
        XCTAssertEqual(fixture.model.history.first?.level, 77)
        XCTAssertEqual(fixture.model.historyFetchedAt, fixedNow)

        await fixture.model.end()
        XCTAssertEqual(fixture.model.history, [])
    }

    func testHistoryResultFromEndedSessionDoesNotPublish() async throws {
        let sample = #"[{"at":"2026-07-17T19:59:00Z","level":77,"status":1}]"#
        let fixture = try await makeFixture(
            results: [],
            historyResults: [AdminScriptedHTTP.ok(sample)],
            historyGateRequests: true
        )
        await fixture.model.begin(host: fixture.host)

        let reload = Task { await fixture.model.reloadHistory() }
        await fixture.historyHTTP.waitForGateRegistration()
        await fixture.model.end()
        fixture.historyHTTP.releaseGates()
        await reload.value

        XCTAssertEqual(fixture.model.history, [])
        XCTAssertNil(fixture.model.historyFetchedAt)
        XCTAssertNil(fixture.model.historyError)
        XCTAssertEqual(fixture.model.historyLoadState, .neverLoaded)
    }

    func testHistoryErrorFromEndedSessionDoesNotPublish() async throws {
        let fixture = try await makeFixture(
            results: [],
            historyResults: [.failure(NetworkError.timeout)],
            historyGateRequests: true
        )
        await fixture.model.begin(host: fixture.host)

        let reload = Task { await fixture.model.reloadHistory() }
        await fixture.historyHTTP.waitForGateRegistration()
        await fixture.model.end()
        fixture.historyHTTP.releaseGates()
        await reload.value

        XCTAssertNil(fixture.model.historyError)
        XCTAssertEqual(fixture.model.historyLoadState, .neverLoaded)
    }

    func testHistorySuccessReleasedAfterReplacementBeginDoesNotPublish() async throws {
        let stale = #"[{"at":"2026-07-17T19:59:00Z","level":12,"status":-1}]"#
        let fixture = try await makeFixture(
            results: [],
            historyResults: [AdminScriptedHTTP.ok(stale)],
            historyGateRequests: true
        )
        await fixture.model.begin(host: fixture.host)
        let staleReload = Task { await fixture.model.reloadHistory() }
        await fixture.historyHTTP.waitForGateRegistration()

        await fixture.model.begin(host: fixture.host)
        fixture.historyHTTP.releaseGates()
        await staleReload.value

        XCTAssertEqual(fixture.model.host, fixture.host)
        XCTAssertEqual(fixture.model.history, [])
        XCTAssertNil(fixture.model.historyFetchedAt)
        XCTAssertNil(fixture.model.historyError)
        XCTAssertEqual(fixture.model.historyLoadState, .neverLoaded)
    }

    func testHistoryErrorReleasedAfterReplacementBeginDoesNotPublish() async throws {
        let fixture = try await makeFixture(
            results: [],
            historyResults: [.failure(NetworkError.timeout)],
            historyGateRequests: true
        )
        await fixture.model.begin(host: fixture.host)
        let staleReload = Task { await fixture.model.reloadHistory() }
        await fixture.historyHTTP.waitForGateRegistration()

        await fixture.model.begin(host: fixture.host)
        fixture.historyHTTP.releaseGates()
        await staleReload.value

        XCTAssertEqual(fixture.model.host, fixture.host)
        XCTAssertEqual(fixture.model.history, [])
        XCTAssertNil(fixture.model.historyFetchedAt)
        XCTAssertNil(fixture.model.historyError)
        XCTAssertEqual(fixture.model.historyLoadState, .neverLoaded)
    }

    func testBeginningReplacementSessionClearsPublishedHistory() async throws {
        let sample = #"[{"at":"2026-07-17T19:59:00Z","level":77,"status":1}]"#
        let fixture = try await makeFixture(
            results: [],
            historyResults: [AdminScriptedHTTP.ok(sample)]
        )
        await fixture.model.begin(host: fixture.host)
        await fixture.model.reloadHistory()
        XCTAssertEqual(fixture.model.history.count, 1)

        await fixture.model.begin(host: fixture.host)

        XCTAssertEqual(fixture.model.history, [])
        XCTAssertNil(fixture.model.historyFetchedAt)
        XCTAssertNil(fixture.model.historyError)
    }

    func testUnlockRequiresSettings200AndGatesSectionsStructurally() async throws {
        let fixture = try await makeFixture(results: [AdminScriptedHTTP.ok("{}")])
        await fixture.model.begin(host: fixture.host)
        XCTAssertEqual(fixture.model.access, .locked)
        let locked = RouterAdministrationPresentation(access: fixture.model.access)
        XCTAssertTrue(locked.showsHistory)
        XCTAssertTrue(locked.showsClientSections)
        XCTAssertFalse(locked.showsAdministratorSections)
        XCTAssertTrue(locked.showsUnlockField)

        await fixture.model.unlock(token: "boot-admin")

        XCTAssertEqual(fixture.model.access, .unlocked)
        XCTAssertNil(fixture.model.adminError)
        let unlocked = RouterAdministrationPresentation(access: fixture.model.access)
        XCTAssertTrue(unlocked.showsHistory)
        XCTAssertTrue(unlocked.showsClientSections)
        XCTAssertTrue(unlocked.showsAdministratorSections)
        XCTAssertFalse(unlocked.showsUnlockField)
        let stored = try await fixture.credentialStore.readToken(
            for: fixture.host.endpoint, role: .administrator
        )
        XCTAssertEqual(stored, "boot-admin")
    }

    func testClientTokenIsNeverPromotedToAdministrator() async throws {
        let fixture = try await makeFixture(results: [
            .failure(NetworkError.api(
                status: 403, code: .adminRequired, message: "Administrator token required"
            )),
        ])
        await fixture.model.begin(host: fixture.host)

        await fixture.model.unlock(token: "wlt_client")

        XCTAssertEqual(fixture.model.access, .locked)
        XCTAssertNotNil(fixture.model.adminError)
        let stored = try await fixture.credentialStore.readToken(
            for: fixture.host.endpoint, role: .administrator
        )
        XCTAssertNil(stored)
    }

    func testStoredAdminTokenReverifiesOnBeginAnd401DeletesOnlyAdminCredential() async throws {
        let fixture = try await makeFixture(results: [
            .failure(NetworkError.unauthorized),
        ])
        try await fixture.credentialStore.saveToken(
            "stale-admin", for: fixture.host.endpoint, role: .administrator
        )
        try await fixture.credentialStore.saveToken(
            "wlt_client", for: fixture.host.endpoint
        )

        await fixture.model.begin(host: fixture.host)

        XCTAssertEqual(fixture.model.access, .locked)
        let admin = try await fixture.credentialStore.readToken(
            for: fixture.host.endpoint, role: .administrator
        )
        XCTAssertNil(admin)
        let client = try await fixture.credentialStore.readToken(for: fixture.host.endpoint)
        XCTAssertEqual(client, "wlt_client")
    }

    func testStoredUnauthorizedDeletionCannotEraseReplacementSessionCredential() async throws {
        let backend = FirstDeleteGatedAdministrationBackend()
        let fixture = try await makeFixture(
            results: [
                .failure(NetworkError.unauthorized),
                AdminScriptedHTTP.ok("{}"),
            ],
            credentialBackend: backend
        )
        try await fixture.credentialStore.saveToken(
            "stale-admin",
            for: fixture.host.endpoint,
            role: .administrator
        )

        let staleBegin = Task { await fixture.model.begin(host: fixture.host) }
        await backend.waitForFirstDeleteToStart()
        let replacementBegin = Task { await fixture.model.begin(host: fixture.host) }
        while fixture.model.access != .verifying { await Task.yield() }
        await backend.releaseFirstDelete()
        await staleBegin.value
        await replacementBegin.value

        XCTAssertEqual(fixture.model.access, .locked)
        let cleared = try await fixture.credentialStore.readToken(
            for: fixture.host.endpoint,
            role: .administrator
        )
        XCTAssertNil(cleared)

        await fixture.model.unlock(token: "current-admin")

        XCTAssertEqual(fixture.model.host, fixture.host)
        XCTAssertEqual(fixture.model.access, .unlocked)
        let stored = try await fixture.credentialStore.readToken(
            for: fixture.host.endpoint,
            role: .administrator
        )
        XCTAssertEqual(stored, "current-admin")
    }

    func testStoredAdministratorReverificationDoesNotRewriteCredential() async throws {
        let backend = FirstDeleteGatedAdministrationBackend()
        let fixture = try await makeFixture(
            results: [AdminScriptedHTTP.ok("{}")],
            credentialBackend: backend
        )
        try await fixture.credentialStore.saveToken(
            "stored-admin",
            for: fixture.host.endpoint,
            role: .administrator
        )

        await fixture.model.begin(host: fixture.host)

        XCTAssertEqual(fixture.model.access, .unlocked)
        let saveCount = await backend.saveCount
        XCTAssertEqual(saveCount, 1)
    }

    func testReplacementStoredVerificationWaitsForExplicitClearAndObservesNoCredential() async throws {
        let backend = FirstDeleteGatedAdministrationBackend()
        let fixture = try await makeFixture(
            results: [
                AdminScriptedHTTP.ok("{}"),
                AdminScriptedHTTP.ok("{}"),
            ],
            gateRequests: true,
            credentialBackend: backend
        )
        try await fixture.credentialStore.saveToken(
            "stored-admin",
            for: fixture.host.endpoint,
            role: .administrator
        )
        let initialBegin = Task { await fixture.model.begin(host: fixture.host) }
        await fixture.http.waitForGateRegistration()
        fixture.http.releaseGates()
        await initialBegin.value
        XCTAssertEqual(fixture.model.access, .unlocked)

        let clear = Task { await fixture.model.lock() }
        await backend.waitForFirstDeleteToStart()
        let replacementBegin = Task { await fixture.model.begin(host: fixture.host) }
        while fixture.model.access != .verifying { await Task.yield() }
        await backend.releaseFirstDelete()
        fixture.http.releaseGates()
        await clear.value
        await replacementBegin.value

        XCTAssertEqual(fixture.model.host, fixture.host)
        XCTAssertEqual(fixture.model.access, .locked)
        XCTAssertEqual(fixture.http.calls.count, 1)
        let stored = try await fixture.credentialStore.readToken(
            for: fixture.host.endpoint,
            role: .administrator
        )
        XCTAssertNil(stored)
    }

    func testLockInvalidatesInFlightUnlockSaveAndLeavesNoCredential() async throws {
        let backend = FirstSaveGatedAdministrationBackend()
        let fixture = try await makeFixture(
            results: [AdminScriptedHTTP.ok("{}")],
            credentialBackend: backend
        )
        await fixture.model.begin(host: fixture.host)

        let unlock = Task { await fixture.model.unlock(token: "current-admin") }
        await backend.waitForFirstSaveToStart()
        let lock = Task { await fixture.model.lock() }
        while fixture.model.access != .locked { await Task.yield() }
        await backend.releaseFirstSave()
        await unlock.value
        await lock.value

        XCTAssertEqual(fixture.model.access, .locked)
        let stored = try await fixture.credentialStore.readToken(
            for: fixture.host.endpoint,
            role: .administrator
        )
        XCTAssertNil(stored)
    }

    func testEndLocksAndStaleUnlockCannotPublishIntoNextSession() async throws {
        let fixture = try await makeFixture(
            results: [AdminScriptedHTTP.ok("{}")],
            gateRequests: true
        )
        await fixture.model.begin(host: fixture.host)

        let unlock = Task { await fixture.model.unlock(token: "boot-admin") }
        await fixture.http.waitForGateRegistration()
        await fixture.model.end()
        fixture.http.releaseGates()
        await unlock.value

        XCTAssertEqual(fixture.model.access, .locked)
    }

    func testAppModelOwnsInjectedAdministrationBoundToSuppliedConnections() async throws {
        let fixture = try await makeFixture(results: [AdminScriptedHTTP.ok("{}")])
        let suite = "RouterAdministrationModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let app = AppModel(
            persistence: AppPersistence(defaults: defaults),
            transportFactory: { fatalError("Bluetooth transport must remain lazy") },
            snapshotCoordinator: nil,
            widgetReloadAdapter: nil,
            routerConnections: fixture.connections,
            routerAdministration: fixture.model
        )

        XCTAssertTrue(app.routerConnections === fixture.connections)
        XCTAssertTrue(app.routerAdministration === fixture.model)
        await app.routerAdministration.begin(host: fixture.host)
        await app.routerAdministration.unlock(token: "injected-admin")

        let stored = try await fixture.credentialStore.readToken(
            for: fixture.host.endpoint,
            role: .administrator
        )
        XCTAssertEqual(stored, "injected-admin")
        XCTAssertEqual(fixture.http.calls.map(\.token), ["injected-admin"])
    }

    func testScanPresentationOffersAdministrationOnlyForSavedHost() async throws {
        let fixture = try await makeFixture(results: [])
        let saved = AppDeviceConnectionRecord(
            id: "saved",
            identity: nil,
            bluetoothDevice: nil,
            discoveredRouter: nil,
            routerHost: fixture.host,
            transportOptions: [.router],
            preferredTransport: .router,
            routerClientCredentialAvailability: .available
        )
        let unsaved = AppDeviceConnectionRecord(
            id: "unsaved",
            identity: nil,
            bluetoothDevice: DiscoveredDevice(
                id: UUID(),
                localName: "Link-Power",
                rssi: -40,
                mode: .application
            ),
            discoveredRouter: nil,
            routerHost: nil,
            transportOptions: [.bluetooth],
            preferredTransport: .bluetooth
        )
        let manualNeedsEnrollment = AppDeviceConnectionRecord(
            id: "manual-needs-enrollment",
            identity: nil,
            bluetoothDevice: nil,
            discoveredRouter: nil,
            routerHost: fixture.host,
            transportOptions: [.router],
            preferredTransport: .router,
            routerClientCredentialAvailability: .enrollmentRequired
        )

        XCTAssertTrue(ScanRecordPresentation(record: saved).offersRouterAdministration)
        XCTAssertFalse(ScanRecordPresentation(record: unsaved).offersRouterAdministration)
        XCTAssertEqual(ScanRecordPresentation(record: saved).primaryAction, .connectRouter)
        XCTAssertEqual(
            ScanRecordPresentation(record: manualNeedsEnrollment).primaryAction,
            .manualRouterEnrollment
        )
    }

    func testPairingSecretsExistOnlyWhileOpenAndClearOnExpiryAndAdmin401() async throws {
        let openBody = #"{"open":true,"expires_at":"2026-07-18T00:05:00Z","pin":"123456"}"#
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var currentTime = ISO8601DateFormatter().date(from: "2026-07-18T00:00:00Z")!
        let fixture = try await makeFixture(
            results: [
                AdminScriptedHTTP.ok("{}"),
                AdminScriptedHTTP.ok(openBody),
                .success((png, AdminScriptedHTTP.pngResponse())),
                .failure(NetworkError.unauthorized),
            ],
            now: { currentTime }
        )
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")

        await fixture.model.openPairing()
        XCTAssertEqual(fixture.model.pairingStatus?.pin, "123456")

        await fixture.model.loadPairingQR()
        XCTAssertEqual(fixture.model.pairingQRPNG, png)

        currentTime = ISO8601DateFormatter().date(from: "2026-07-18T00:06:00Z")!
        fixture.model.expirePairingSecretsIfNeeded()
        XCTAssertNil(fixture.model.pairingStatus)
        XCTAssertNil(fixture.model.pairingQRPNG)

        await fixture.model.openPairing()
        XCTAssertEqual(fixture.model.access, .locked)
        XCTAssertNil(fixture.model.pairingStatus)
        XCTAssertNil(fixture.model.pairingQRPNG)
    }

    func testQRLoadIsStructurallyImpossibleWhileClosedOrLocked() async throws {
        let fixture = try await makeFixture(results: [AdminScriptedHTTP.ok("{}")])
        await fixture.model.begin(host: fixture.host)

        await fixture.model.loadPairingQR()
        XCTAssertNil(fixture.model.pairingQRPNG)

        await fixture.model.unlock(token: "boot-admin")
        await fixture.model.loadPairingQR()
        XCTAssertNil(fixture.model.pairingQRPNG)
        XCTAssertEqual(fixture.http.calls.map(\.path), ["/api/v1/settings"])
    }

    func testInitialPairingReloadTransitionsFromLoadingToActionableFailure() async throws {
        let fixture = try await makeFixture(results: [
            AdminScriptedHTTP.ok("{}"),
            .failure(NetworkError.timeout),
        ])
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")
        fixture.http.gateNextRequest()

        let reload = Task { await fixture.model.reloadPairingMode() }
        await fixture.http.waitForGateRegistration()

        XCTAssertEqual(fixture.model.pairingDisplayState, .loading)
        XCTAssertFalse(fixture.model.pairingDisplayState.canRefresh)

        fixture.http.releaseGates()
        await reload.value

        XCTAssertEqual(fixture.model.pairingDisplayState, .failed)
        XCTAssertTrue(fixture.model.pairingDisplayState.canRefresh)
        XCTAssertNil(fixture.model.pairingStatus)
        XCTAssertNil(fixture.model.pairingQRPNG)
        XCTAssertEqual(fixture.model.pairingError, "The request failed. Try again.")
    }

    func testPairingReloadWhileLockedDoesNotClaimAnActiveLoad() async throws {
        let fixture = try await makeFixture(results: [])
        await fixture.model.begin(host: fixture.host)

        await fixture.model.reloadPairingMode()

        XCTAssertEqual(fixture.model.pairingDisplayState, .unknown)
        XCTAssertEqual(fixture.http.calls, [])
    }

    func testLockAndSessionEndClearPairingSecrets() async throws {
        let openBody = #"{"open":true,"expires_at":"2099-07-18T00:05:00Z","pin":"123456"}"#
        let fixture = try await makeFixture(results: [
            AdminScriptedHTTP.ok("{}"),
            AdminScriptedHTTP.ok(openBody),
            AdminScriptedHTTP.ok("{}"),
            AdminScriptedHTTP.ok(openBody),
        ])
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")
        await fixture.model.openPairing()

        await fixture.model.lock()

        XCTAssertEqual(fixture.model.access, .locked)
        XCTAssertNil(fixture.model.pairingStatus)
        XCTAssertNil(fixture.model.pairingQRPNG)

        await fixture.model.unlock(token: "boot-admin")
        await fixture.model.openPairing()
        XCTAssertNotNil(fixture.model.pairingStatus?.pin)

        await fixture.model.end()

        XCTAssertNil(fixture.model.pairingStatus)
        XCTAssertNil(fixture.model.pairingQRPNG)
        XCTAssertNil(fixture.model.pairingError)
    }

    func testClearingSecretsWhilePairingRequestIsInFlightPreventsLatePINResurrection() async throws {
        let openBody = #"{"open":true,"expires_at":"2099-07-18T00:05:00Z","pin":"123456"}"#
        let fixture = try await makeFixture(results: [
            AdminScriptedHTTP.ok("{}"),
            AdminScriptedHTTP.ok(openBody),
        ])
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")
        fixture.http.gateNextRequest()

        let opening = Task { await fixture.model.openPairing() }
        await fixture.http.waitForGateRegistration()
        fixture.model.clearPairingSecrets()
        fixture.http.releaseGates()
        await opening.value

        XCTAssertNil(fixture.model.pairingStatus)
        XCTAssertNil(fixture.model.pairingQRPNG)
    }

    func testClearingSecretsWhileQRRequestIsInFlightPreventsLateQRResurrection() async throws {
        let openBody = #"{"open":true,"expires_at":"2099-07-18T00:05:00Z","pin":"123456"}"#
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let fixture = try await makeFixture(results: [
            AdminScriptedHTTP.ok("{}"),
            AdminScriptedHTTP.ok(openBody),
            .success((png, AdminScriptedHTTP.pngResponse())),
        ])
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")
        await fixture.model.openPairing()
        fixture.http.gateNextRequest()

        let loading = Task { await fixture.model.loadPairingQR() }
        await fixture.http.waitForGateRegistration()
        fixture.model.clearPairingSecrets()
        fixture.http.releaseGates()
        await loading.value

        XCTAssertNil(fixture.model.pairingStatus)
        XCTAssertNil(fixture.model.pairingQRPNG)
    }

    func testNewerQRSuccessWinsOverOlderErrorAndOwnsLoadingState() async throws {
        let openBody = #"{"open":true,"expires_at":"2099-07-18T00:05:00Z","pin":"123456"}"#
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let fixture = try await makeFixture(results: [
            AdminScriptedHTTP.ok("{}"),
            AdminScriptedHTTP.ok(openBody),
            .failure(NetworkError.timeout),
            .success((png, AdminScriptedHTTP.pngResponse())),
        ])
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")
        await fixture.model.openPairing()
        fixture.http.gateNextRequest()

        let olderLoad = Task { await fixture.model.loadPairingQR() }
        await fixture.http.waitForGateRegistration()
        XCTAssertTrue(fixture.model.isPairingQRLoading)

        await fixture.model.loadPairingQR()
        XCTAssertEqual(fixture.model.pairingQRPNG, png)
        XCTAssertNil(fixture.model.pairingError)
        XCTAssertFalse(fixture.model.isPairingQRLoading)

        fixture.http.releaseGates()
        await olderLoad.value

        XCTAssertEqual(fixture.model.pairingQRPNG, png)
        XCTAssertNil(fixture.model.pairingError)
        XCTAssertFalse(fixture.model.isPairingQRLoading)
    }

    func testStalePairing401AfterLockAndReunlockCannotRelockOrDeleteNewToken() async throws {
        let fixture = try await makeFixture(results: [
            AdminScriptedHTTP.ok("{}"),
            .failure(NetworkError.unauthorized),
            AdminScriptedHTTP.ok("{}"),
        ])
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "old-admin")
        fixture.http.gateNextRequest()

        let stale = Task { await fixture.model.openPairing() }
        await fixture.http.waitForGateRegistration()
        await fixture.model.lock()
        await fixture.model.unlock(token: "new-admin")
        fixture.http.releaseGates()
        await stale.value

        XCTAssertEqual(fixture.model.access, .unlocked)
        XCTAssertNil(fixture.model.adminError)
        let stored = try await fixture.credentialStore.readToken(
            for: fixture.host.endpoint,
            role: .administrator
        )
        XCTAssertEqual(stored, "new-admin")
    }

    func testPairingResponseFromOlderAdminOperationCannotPublishAfterReunlock() async throws {
        let openBody = #"{"open":true,"expires_at":"2099-07-18T00:05:00Z","pin":"123456"}"#
        let fixture = try await makeFixture(results: [
            AdminScriptedHTTP.ok("{}"),
            AdminScriptedHTTP.ok(openBody),
            AdminScriptedHTTP.ok("{}"),
        ])
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "old-admin")
        fixture.http.gateNextRequest()

        let stale = Task { await fixture.model.openPairing() }
        await fixture.http.waitForGateRegistration()
        await fixture.model.unlock(token: "new-admin")
        fixture.http.releaseGates()
        await stale.value

        XCTAssertEqual(fixture.model.access, .unlocked)
        XCTAssertNil(fixture.model.pairingStatus)
    }

    func testNewerOpenReadbackWinsOverOlderClosedReload() async throws {
        let closedBody = #"{"open":false,"expires_at":"0001-01-01T00:00:00Z"}"#
        let openBody = #"{"open":true,"expires_at":"2099-07-18T00:05:00Z","pin":"654321"}"#
        let fixture = try await makeFixture(results: [
            AdminScriptedHTTP.ok("{}"),
            AdminScriptedHTTP.ok(closedBody),
            AdminScriptedHTTP.ok(openBody),
        ])
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")
        fixture.http.gateNextRequest()

        let olderReload = Task { await fixture.model.reloadPairingMode() }
        await fixture.http.waitForGateRegistration()
        await fixture.model.openPairing()
        XCTAssertEqual(fixture.model.pairingStatus?.pin, "654321")
        fixture.http.releaseGates()
        await olderReload.value

        XCTAssertEqual(fixture.model.pairingStatus?.pin, "654321")
        XCTAssertNil(fixture.model.pairingError)
    }

    func testNewerClosedReadbackPreventsOlderOpenPINResurrection() async throws {
        let openBody = #"{"open":true,"expires_at":"2099-07-18T00:05:00Z","pin":"123456"}"#
        let closedBody = #"{"open":false,"expires_at":"0001-01-01T00:00:00Z"}"#
        let fixture = try await makeFixture(results: [
            AdminScriptedHTTP.ok("{}"),
            AdminScriptedHTTP.ok(openBody),
            AdminScriptedHTTP.ok(closedBody),
        ])
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")
        fixture.http.gateNextRequest()

        let olderOpen = Task { await fixture.model.openPairing() }
        await fixture.http.waitForGateRegistration()
        await fixture.model.reloadPairingMode()
        XCTAssertEqual(fixture.model.pairingStatus?.open, false)
        fixture.http.releaseGates()
        await olderOpen.value

        XCTAssertEqual(fixture.model.pairingStatus?.open, false)
        XCTAssertNil(fixture.model.pairingStatus?.pin)
    }

    func testOlderPairingErrorCannotOverwriteNewerOpenSuccess() async throws {
        let openBody = #"{"open":true,"expires_at":"2099-07-18T00:05:00Z","pin":"654321"}"#
        let fixture = try await makeFixture(results: [
            AdminScriptedHTTP.ok("{}"),
            .failure(NetworkError.timeout),
            AdminScriptedHTTP.ok(openBody),
        ])
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")
        fixture.http.gateNextRequest()

        let olderReload = Task { await fixture.model.reloadPairingMode() }
        await fixture.http.waitForGateRegistration()
        await fixture.model.openPairing()
        fixture.http.releaseGates()
        await olderReload.value

        XCTAssertEqual(fixture.model.pairingStatus?.pin, "654321")
        XCTAssertNil(fixture.model.pairingError)
        XCTAssertEqual(fixture.model.pairingDisplayState, .open)
    }

    func testClosedReadbackInvalidatesInFlightQRAndPreservesConfirmedClosedTruth() async throws {
        let openBody = #"{"open":true,"expires_at":"2099-07-18T00:05:00Z","pin":"123456"}"#
        let closedBody = #"{"open":false,"expires_at":"0001-01-01T00:00:00Z"}"#
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let fixture = try await makeFixture(results: [
            AdminScriptedHTTP.ok("{}"),
            AdminScriptedHTTP.ok(openBody),
            .success((png, AdminScriptedHTTP.pngResponse())),
            AdminScriptedHTTP.ok(closedBody),
        ])
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")
        await fixture.model.openPairing()
        fixture.http.gateNextRequest()

        let loadingQR = Task { await fixture.model.loadPairingQR() }
        await fixture.http.waitForGateRegistration()
        await fixture.model.reloadPairingMode()
        fixture.http.releaseGates()
        await loadingQR.value

        XCTAssertEqual(fixture.model.pairingStatus?.open, false)
        XCTAssertNil(fixture.model.pairingStatus?.pin)
        XCTAssertNil(fixture.model.pairingQRPNG)
    }

    func testAlreadyExpiredOpenReadbackClearsSecretsAndOffersRecoveryActions() async throws {
        let openBody = #"{"open":true,"expires_at":"2026-07-18T00:05:00Z","pin":"123456"}"#
        let currentTime = ISO8601DateFormatter().date(from: "2026-07-18T00:06:00Z")!
        let fixture = try await makeFixture(
            results: [
                AdminScriptedHTTP.ok("{}"),
                AdminScriptedHTTP.ok(openBody),
            ],
            now: { currentTime }
        )
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")

        await fixture.model.openPairing()

        XCTAssertNil(fixture.model.pairingStatus)
        XCTAssertNil(fixture.model.pairingQRPNG)
        XCTAssertEqual(fixture.model.pairingDisplayState, .expired)
        XCTAssertTrue(fixture.model.pairingDisplayState.canOpenPairing)
        XCTAssertTrue(fixture.model.pairingDisplayState.canRefresh)
    }

    func testSuccessfulClosePublishesConfirmedClosedInsteadOfUnknown() async throws {
        let openBody = #"{"open":true,"expires_at":"2099-07-18T00:05:00Z","pin":"123456"}"#
        let fixture = try await makeFixture(results: [
            AdminScriptedHTTP.ok("{}"),
            AdminScriptedHTTP.ok(openBody),
            AdminScriptedHTTP.ok(#"{"open":false}"#),
        ])
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")
        await fixture.model.openPairing()

        await fixture.model.closePairing()

        XCTAssertEqual(fixture.model.pairingStatus?.open, false)
        XCTAssertNil(fixture.model.pairingStatus?.pin)
        XCTAssertNil(fixture.model.pairingQRPNG)
    }

    func testBackgroundClearsToUnknownAndForegroundReloadsConfirmedTruth() async throws {
        let openBody = #"{"open":true,"expires_at":"2099-07-18T00:05:00Z","pin":"123456"}"#
        let closedBody = #"{"open":false,"expires_at":"0001-01-01T00:00:00Z"}"#
        let fixture = try await makeFixture(results: [
            AdminScriptedHTTP.ok("{}"),
            AdminScriptedHTTP.ok(openBody),
            AdminScriptedHTTP.ok(closedBody),
        ])
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")
        await fixture.model.openPairing()
        XCTAssertEqual(fixture.model.pairingStatus?.open, true)

        fixture.model.pairingDidEnterBackground()

        XCTAssertNil(fixture.model.pairingStatus)
        XCTAssertNil(fixture.model.pairingQRPNG)
        XCTAssertEqual(fixture.model.pairingDisplayState, .unknown)

        await fixture.model.pairingDidBecomeActive()

        XCTAssertEqual(fixture.model.pairingStatus?.open, false)
        XCTAssertEqual(
            fixture.http.calls.map(\.path),
            ["/api/v1/settings", "/api/v1/pairing-mode", "/api/v1/pairing-mode"]
        )
    }

    func testBackgroundThenForegroundFailureTransitionsUnknownToLoadingToRetryableFailure() async throws {
        let openBody = #"{"open":true,"expires_at":"2099-07-18T00:05:00Z","pin":"123456"}"#
        let fixture = try await makeFixture(results: [
            AdminScriptedHTTP.ok("{}"),
            AdminScriptedHTTP.ok(openBody),
            .failure(NetworkError.timeout),
        ])
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")
        await fixture.model.openPairing()
        fixture.model.pairingDidEnterBackground()
        XCTAssertEqual(fixture.model.pairingDisplayState, .unknown)
        fixture.http.gateNextRequest()

        let foreground = Task { await fixture.model.pairingDidBecomeActive() }
        await fixture.http.waitForGateRegistration()
        XCTAssertEqual(fixture.model.pairingDisplayState, .loading)

        fixture.http.releaseGates()
        await foreground.value

        XCTAssertEqual(fixture.model.pairingDisplayState, .failed)
        XCTAssertTrue(fixture.model.pairingDisplayState.canRefresh)
        XCTAssertNil(fixture.model.pairingStatus)
        XCTAssertNil(fixture.model.pairingQRPNG)
    }

    func testScheduledExpiryClearsSecretsAndOffersRecoveryActionsAtExactDeadline() async throws {
        let openBody = #"{"open":true,"expires_at":"2026-07-18T00:05:00Z","pin":"123456"}"#
        let start = ISO8601DateFormatter().date(from: "2026-07-18T00:00:00Z")!
        let expiry = ISO8601DateFormatter().date(from: "2026-07-18T00:05:00Z")!
        var currentTime = start
        let sleeper = PairingExpirySleepFixture()
        let fixture = try await makeFixture(
            results: [
                AdminScriptedHTTP.ok("{}"),
                AdminScriptedHTTP.ok(openBody),
            ],
            now: { currentTime },
            pairingExpirySleep: { deadline in
                try await sleeper.sleep(until: deadline)
            }
        )
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")

        await fixture.model.openPairing()
        await sleeper.waitForDeadlineCount(1)

        XCTAssertEqual(sleeper.deadlineHistory, [expiry])
        XCTAssertEqual(fixture.model.pairingStatus?.pin, "123456")

        currentTime = expiry
        sleeper.resumeFirst()
        for _ in 0..<1_000 where fixture.model.pairingStatus != nil {
            await Task.yield()
        }

        XCTAssertNil(fixture.model.pairingStatus)
        XCTAssertNil(fixture.model.pairingQRPNG)
        XCTAssertEqual(fixture.model.pairingDisplayState, .expired)
        XCTAssertTrue(fixture.model.pairingDisplayState.canOpenPairing)
        XCTAssertTrue(fixture.model.pairingDisplayState.canRefresh)
    }

    func testExpiryClearsObsoletePairingErrorSoExpiredStateOwnsMessaging() async throws {
        let openBody = #"{"open":true,"expires_at":"2026-07-18T00:05:00Z","pin":"123456"}"#
        var currentTime = ISO8601DateFormatter().date(from: "2026-07-18T00:00:00Z")!
        let fixture = try await makeFixture(
            results: [
                AdminScriptedHTTP.ok("{}"),
                AdminScriptedHTTP.ok(openBody),
                .failure(NetworkError.timeout),
            ],
            now: { currentTime }
        )
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")
        await fixture.model.openPairing()
        await fixture.model.loadPairingQR()
        XCTAssertEqual(fixture.model.pairingError, "The request failed. Try again.")

        currentTime = ISO8601DateFormatter().date(from: "2026-07-18T00:06:00Z")!
        fixture.model.expirePairingSecretsIfNeeded()

        XCTAssertEqual(fixture.model.pairingDisplayState, .expired)
        XCTAssertNil(fixture.model.pairingStatus)
        XCTAssertNil(fixture.model.pairingQRPNG)
        XCTAssertNil(fixture.model.pairingError)
    }

    func testNewStatusReplacesExpiryTaskAndEndCancelsReplacement() async throws {
        let firstBody = #"{"open":true,"expires_at":"2026-07-18T00:05:00Z","pin":"123456"}"#
        let secondBody = #"{"open":true,"expires_at":"2026-07-18T00:10:00Z","pin":"654321"}"#
        let start = ISO8601DateFormatter().date(from: "2026-07-18T00:00:00Z")!
        let firstExpiry = ISO8601DateFormatter().date(from: "2026-07-18T00:05:00Z")!
        let secondExpiry = ISO8601DateFormatter().date(from: "2026-07-18T00:10:00Z")!
        let sleeper = PairingExpirySleepFixture()
        let fixture = try await makeFixture(
            results: [
                AdminScriptedHTTP.ok("{}"),
                AdminScriptedHTTP.ok(firstBody),
                AdminScriptedHTTP.ok(secondBody),
            ],
            now: { start },
            pairingExpirySleep: { deadline in
                try await sleeper.sleep(until: deadline)
            }
        )
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")
        await fixture.model.openPairing()
        await sleeper.waitForDeadlineCount(1)

        await fixture.model.reloadPairingMode()
        await sleeper.waitForDeadlineCount(2)
        await sleeper.waitForCancellationCount(1)

        XCTAssertEqual(sleeper.deadlineHistory, [firstExpiry, secondExpiry])
        XCTAssertEqual(fixture.model.pairingStatus?.pin, "654321")

        await fixture.model.end()
        await sleeper.waitForCancellationCount(2)

        XCTAssertEqual(sleeper.cancellationCount, 2)
        XCTAssertNil(fixture.model.pairingStatus)
    }

    func testRevokingCurrentClientDeletesOnlyClientCredentialPreservesHostAndRelists() async throws {
        let listBefore = #"[{"id":"7dd64d22b0c14e7b","label":"This iPhone","created_at":"2026-07-17T20:00:00Z","last_seen_at":null,"bootstrap":false}]"#
        let fixture = try await makeFixture(
            results: [
                AdminScriptedHTTP.ok("{}"),
                AdminScriptedHTTP.ok(listBefore),
                AdminScriptedHTTP.ok(#"{"revoked":"7dd64d22b0c14e7b"}"#),
                AdminScriptedHTTP.ok("[]"),
            ],
            hostTokenID: "7dd64d22b0c14e7b"
        )
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")
        await fixture.model.reloadTokens()
        XCTAssertEqual(fixture.model.tokens.count, 1)
        XCTAssertTrue(fixture.model.isCurrentClient(fixture.model.tokens[0]))
        let unrelatedEndpoint = RouterEndpoint(
            scheme: "https",
            host: "unrelated.local",
            port: 8378,
            certificateFingerprint: String(repeating: "2", count: 64),
            allowsInsecureWAN: false
        )
        try await fixture.credentialStore.saveToken(
            "unrelated-client", for: unrelatedEndpoint
        )

        await fixture.model.revoke(fixture.model.tokens[0])

        XCTAssertEqual(fixture.model.tokens, [])
        XCTAssertNil(fixture.model.tokensError)
        XCTAssertEqual(
            fixture.http.calls.map { "\($0.method) \($0.path)" },
            [
                "GET /api/v1/settings",
                "GET /api/v1/tokens",
                "DELETE /api/v1/tokens/7dd64d22b0c14e7b",
                "GET /api/v1/tokens",
            ]
        )
        let client = try await fixture.credentialStore.readToken(for: fixture.host.endpoint)
        XCTAssertNil(client)
        let admin = try await fixture.credentialStore.readToken(
            for: fixture.host.endpoint, role: .administrator
        )
        XCTAssertEqual(admin, "boot-admin")
        let unrelatedClient = try await fixture.credentialStore.readToken(
            for: unrelatedEndpoint
        )
        XCTAssertEqual(unrelatedClient, "unrelated-client")
        XCTAssertEqual(fixture.connections.savedHosts, [fixture.host])
        XCTAssertEqual(fixture.model.host, fixture.host)
        let record = try XCTUnwrap(
            fixture.connections.scanRecords(bluetooth: [], identities: [:]).first
        )
        XCTAssertEqual(
            record.routerClientCredentialAvailability,
            .enrollmentRequired
        )
        XCTAssertEqual(
            ScanRecordPresentation(record: record).primaryAction,
            .manualRouterEnrollment
        )
    }

    func testOlderBulkCredentialRefreshCannotOverwriteSelfRevokeEnrollmentState() async throws {
        let listBefore = #"[{"id":"self-id","label":"This iPhone","created_at":"2026-07-17T20:00:00Z","last_seen_at":null,"bootstrap":false}]"#
        let backend = SpecificClientReadGatedAdministrationBackend()
        let fixture = try await makeFixture(
            results: [
                AdminScriptedHTTP.ok("{}"),
                AdminScriptedHTTP.ok(listBefore),
                AdminScriptedHTTP.ok(#"{"revoked":"self-id"}"#),
                AdminScriptedHTTP.ok("[]"),
            ],
            hostTokenID: "self-id",
            credentialBackend: backend
        )
        let otherHost = try await fixture.connections.saveManualHost(
            address: "https://other.local:8378",
            displayName: "Zulu router",
            reachability: .lan,
            allowsInsecureWAN: false,
            deviceID: "AA:BB:CC:DD:EE:FF",
            certificateFingerprint: String(repeating: "2", count: 64),
            token: "other-client"
        )
        try await fixture.credentialStore.saveToken(
            "other-admin", for: otherHost.endpoint, role: .administrator
        )
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")
        await fixture.model.reloadTokens()
        let selfToken = try XCTUnwrap(fixture.model.tokens.first)
        await backend.gateNextClientRead(
            account: otherHost.endpoint.peripheralID.uuidString
        )

        let olderBulkRefresh = Task { await fixture.connections.reloadSavedHosts() }
        await backend.waitForClientReadToStart()
        await fixture.model.revoke(selfToken)

        var record = try XCTUnwrap(
            fixture.connections.scanRecords(bluetooth: [], identities: [:])
                .first { $0.routerHost?.id == fixture.host.id }
        )
        XCTAssertEqual(record.routerClientCredentialAvailability, .enrollmentRequired)

        await backend.releaseClientRead()
        await olderBulkRefresh.value

        record = try XCTUnwrap(
            fixture.connections.scanRecords(bluetooth: [], identities: [:])
                .first { $0.routerHost?.id == fixture.host.id }
        )
        XCTAssertEqual(record.routerClientCredentialAvailability, .enrollmentRequired)
        XCTAssertEqual(
            ScanRecordPresentation(record: record).primaryAction,
            .manualRouterEnrollment
        )
        XCTAssertEqual(fixture.connections.savedHosts, [fixture.host, otherHost])
        let primaryClient = try await fixture.credentialStore.readToken(
            for: fixture.host.endpoint
        )
        let primaryAdmin = try await fixture.credentialStore.readToken(
            for: fixture.host.endpoint, role: .administrator
        )
        let otherClient = try await fixture.credentialStore.readToken(
            for: otherHost.endpoint
        )
        let otherAdmin = try await fixture.credentialStore.readToken(
            for: otherHost.endpoint, role: .administrator
        )
        XCTAssertNil(primaryClient)
        XCTAssertEqual(primaryAdmin, "boot-admin")
        XCTAssertEqual(otherClient, "other-client")
        XCTAssertEqual(otherAdmin, "other-admin")
    }

    func testRevokingAnotherClientPreservesThisEndpointsCredential() async throws {
        let list = #"[{"id":"other-token-id","label":"Other phone","created_at":"2026-07-17T20:00:00Z","last_seen_at":null,"bootstrap":false}]"#
        let fixture = try await makeFixture(
            results: [
                AdminScriptedHTTP.ok("{}"),
                AdminScriptedHTTP.ok(list),
                AdminScriptedHTTP.ok(#"{"revoked":"other-token-id"}"#),
                AdminScriptedHTTP.ok("[]"),
            ],
            hostTokenID: "7dd64d22b0c14e7b"
        )
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")
        await fixture.model.reloadTokens()
        XCTAssertFalse(fixture.model.isCurrentClient(fixture.model.tokens[0]))

        await fixture.model.revoke(fixture.model.tokens[0])

        let client = try await fixture.credentialStore.readToken(for: fixture.host.endpoint)
        XCTAssertEqual(client, "wlt_client")
    }

    func testConcurrentModelRevocationsUseAtomicFIFOReadbacksAndPublishFinalList() async throws {
        let initial = #"[{"id":"first","label":"First","created_at":"2026-07-17T19:00:00Z","last_seen_at":null,"bootstrap":false},{"id":"second","label":"Second","created_at":"2026-07-17T20:00:00Z","last_seen_at":null,"bootstrap":false}]"#
        let afterFirst = #"[{"id":"second","label":"Second","created_at":"2026-07-17T20:00:00Z","last_seen_at":null,"bootstrap":false}]"#
        let fixture = try await makeFixture(results: [
            AdminScriptedHTTP.ok("{}"),
            AdminScriptedHTTP.ok(initial),
            AdminScriptedHTTP.ok(#"{"revoked":"first"}"#),
            AdminScriptedHTTP.ok(afterFirst),
            AdminScriptedHTTP.ok(#"{"revoked":"second"}"#),
            AdminScriptedHTTP.ok("[]"),
        ])
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")
        await fixture.model.reloadTokens()
        let firstToken = try XCTUnwrap(fixture.model.tokens.first { $0.id == "first" })
        let secondToken = try XCTUnwrap(fixture.model.tokens.first { $0.id == "second" })
        fixture.http.gateNextRequest()

        let first = Task { await fixture.model.revoke(firstToken) }
        await fixture.http.waitForGateRegistration()
        let second = Task { await fixture.model.revoke(secondToken) }
        for _ in 0..<100 { await Task.yield() }
        fixture.http.releaseGates()
        await first.value
        await second.value

        XCTAssertEqual(fixture.model.tokens, [])
        XCTAssertNil(fixture.model.tokensError)
        XCTAssertEqual(
            fixture.http.calls.map { "\($0.method) \($0.path)" },
            [
                "GET /api/v1/settings",
                "GET /api/v1/tokens",
                "DELETE /api/v1/tokens/first",
                "GET /api/v1/tokens",
                "DELETE /api/v1/tokens/second",
                "GET /api/v1/tokens",
            ]
        )
    }

    func testBootstrapRowIsNeverRevocableFromTheModel() async throws {
        let list = #"[{"id":"bootstrap","label":"Bootstrap administrator","created_at":"2026-07-17T19:00:00Z","last_seen_at":null,"bootstrap":true}]"#
        let fixture = try await makeFixture(results: [
            AdminScriptedHTTP.ok("{}"),
            AdminScriptedHTTP.ok(list),
        ])
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")
        await fixture.model.reloadTokens()

        await fixture.model.revoke(fixture.model.tokens[0])

        XCTAssertEqual(fixture.http.calls.map(\.method), ["GET", "GET"])
        XCTAssertEqual(fixture.model.tokens.count, 1)
    }

    func testConcurrentSameSessionTokenReloadsPublishFIFOLists() async throws {
        let older = #"[{"id":"older","label":"Older","created_at":"2026-07-17T19:00:00Z","last_seen_at":null,"bootstrap":false}]"#
        let newer = #"[{"id":"newer","label":"Newer","created_at":"2026-07-17T20:00:00Z","last_seen_at":null,"bootstrap":false}]"#
        let fixture = try await makeFixture(results: [
            AdminScriptedHTTP.ok("{}"),
            AdminScriptedHTTP.ok(older),
            AdminScriptedHTTP.ok(newer),
        ])
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")
        fixture.http.gateNextRequest()

        let olderReload = Task { await fixture.model.reloadTokens() }
        await fixture.http.waitForGateRegistration()
        let newerReload = Task { await fixture.model.reloadTokens() }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(fixture.http.calls.map(\.path), [
            "/api/v1/settings", "/api/v1/tokens",
        ])

        fixture.http.releaseGates()
        await olderReload.value
        await newerReload.value

        XCTAssertEqual(fixture.model.tokens.map(\.id), ["newer"])
        XCTAssertNil(fixture.model.tokensError)
    }

    func testConcurrentSameSessionTokenReloadRecoversAfterFIFOError() async throws {
        let newer = #"[{"id":"newer","label":"Newer","created_at":"2026-07-17T20:00:00Z","last_seen_at":null,"bootstrap":false}]"#
        let fixture = try await makeFixture(results: [
            AdminScriptedHTTP.ok("{}"),
            .failure(NetworkError.timeout),
            AdminScriptedHTTP.ok(newer),
        ])
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")
        fixture.http.gateNextRequest()

        let olderReload = Task { await fixture.model.reloadTokens() }
        await fixture.http.waitForGateRegistration()
        let newerReload = Task { await fixture.model.reloadTokens() }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(fixture.http.calls.map(\.path), [
            "/api/v1/settings", "/api/v1/tokens",
        ])
        fixture.http.releaseGates()
        await olderReload.value
        await newerReload.value

        XCTAssertEqual(fixture.model.tokens.map(\.id), ["newer"])
        XCTAssertNil(fixture.model.tokensError)
    }

    func testTokenReloadWaitsForInFlightRevokeWorkflowAndPublishesPostRevokeList() async throws {
        let initial = #"[{"id":"other-token-id","label":"Other","created_at":"2026-07-17T19:00:00Z","last_seen_at":null,"bootstrap":false}]"#
        let fixture = try await makeFixture(results: [
            AdminScriptedHTTP.ok("{}"),
            AdminScriptedHTTP.ok(initial),
            AdminScriptedHTTP.ok(#"{"revoked":"other-token-id"}"#),
            AdminScriptedHTTP.ok("[]"),
            AdminScriptedHTTP.ok("[]"),
        ])
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")
        await fixture.model.reloadTokens()
        let token = try XCTUnwrap(fixture.model.tokens.first)
        fixture.http.gateNextRequest()

        let revoke = Task { await fixture.model.revoke(token) }
        await fixture.http.waitForGateRegistration()
        let reloadStarted = expectation(description: "token reload submitted")
        let reload = Task {
            reloadStarted.fulfill()
            await fixture.model.reloadTokens()
        }
        await fulfillment(of: [reloadStarted], timeout: 1)
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(fixture.http.calls.map(\.path), [
            "/api/v1/settings",
            "/api/v1/tokens",
            "/api/v1/tokens/other-token-id",
        ])

        fixture.http.releaseGates()
        await revoke.value
        await reload.value

        XCTAssertEqual(fixture.model.tokens, [])
        XCTAssertNil(fixture.model.tokensError)
        XCTAssertEqual(fixture.http.calls.map(\.path), [
            "/api/v1/settings",
            "/api/v1/tokens",
            "/api/v1/tokens/other-token-id",
            "/api/v1/tokens",
            "/api/v1/tokens",
        ])
    }

    func testStaleTokenAuthFailureAfterReunlockCannotRelockOrDeleteNewAdmin() async throws {
        let current = #"[{"id":"current","label":"Current","created_at":"2026-07-17T20:00:00Z","last_seen_at":null,"bootstrap":false}]"#
        let fixture = try await makeFixture(results: [
            AdminScriptedHTTP.ok("{}"),
            .failure(NetworkError.unauthorized),
            AdminScriptedHTTP.ok("{}"),
            AdminScriptedHTTP.ok(current),
        ])
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "old-admin")
        fixture.http.gateNextRequest()

        let staleReload = Task { await fixture.model.reloadTokens() }
        await fixture.http.waitForGateRegistration()
        await fixture.model.lock()
        await fixture.model.unlock(token: "new-admin")
        let currentReload = Task { await fixture.model.reloadTokens() }
        for _ in 0..<100 { await Task.yield() }
        fixture.http.releaseGates()
        await staleReload.value
        await currentReload.value

        XCTAssertEqual(fixture.model.access, .unlocked)
        XCTAssertEqual(fixture.model.tokens.map(\.id), ["current"])
        XCTAssertNil(fixture.model.adminError)
        let admin = try await fixture.credentialStore.readToken(
            for: fixture.host.endpoint, role: .administrator
        )
        XCTAssertEqual(admin, "new-admin")
    }

    func testDurableSelfRevokeCompletesCapturedHostCleanupAfterSessionEnd() async throws {
        let list = #"[{"id":"self-id","label":"This iPhone","created_at":"2026-07-17T20:00:00Z","last_seen_at":null,"bootstrap":false}]"#
        let fixture = try await makeFixture(
            results: [
                AdminScriptedHTTP.ok("{}"),
                AdminScriptedHTTP.ok(list),
                AdminScriptedHTTP.ok(#"{"revoked":"self-id"}"#),
            ],
            hostTokenID: "self-id"
        )
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")
        await fixture.model.reloadTokens()
        let token = try XCTUnwrap(fixture.model.tokens.first)
        fixture.http.gateNextRequest()

        let revoke = Task { await fixture.model.revoke(token) }
        await fixture.http.waitForGateRegistration()
        await fixture.model.end()
        fixture.http.releaseGates()
        await revoke.value

        let client = try await fixture.credentialStore.readToken(for: fixture.host.endpoint)
        XCTAssertNil(client)
        let admin = try await fixture.credentialStore.readToken(
            for: fixture.host.endpoint, role: .administrator
        )
        XCTAssertEqual(admin, "boot-admin")
        XCTAssertEqual(fixture.connections.savedHosts, [fixture.host])
        XCTAssertNil(fixture.model.host)
        XCTAssertEqual(fixture.model.tokens, [])
        XCTAssertNil(fixture.model.tokensError)
        XCTAssertEqual(fixture.http.calls.map(\.path), [
            "/api/v1/settings", "/api/v1/tokens", "/api/v1/tokens/self-id",
        ])
    }

    func testSameEndpointReenrollmentBeforeSelfRevokeCleanupPreservesSuccessorCredential() async throws {
        let list = #"[{"id":"self-id","label":"This iPhone","created_at":"2026-07-17T20:00:00Z","last_seen_at":null,"bootstrap":false}]"#
        let fixture = try await makeFixture(
            results: [
                AdminScriptedHTTP.ok("{}"),
                AdminScriptedHTTP.ok(list),
                AdminScriptedHTTP.ok(#"{"revoked":"self-id"}"#),
                AdminScriptedHTTP.ok("[]"),
            ],
            hostTokenID: "self-id"
        )
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")
        await fixture.model.reloadTokens()
        let token = try XCTUnwrap(fixture.model.tokens.first)
        fixture.http.gateNextRequest()

        let revoke = Task { await fixture.model.revoke(token) }
        await fixture.http.waitForGateRegistration()
        _ = try await fixture.connections.saveManualHost(
            address: "https://router.local:8378",
            displayName: "Garage router re-enrolled",
            reachability: .lan,
            allowsInsecureWAN: false,
            deviceID: "DC:04:5A:EB:72:2B",
            certificateFingerprint: String(repeating: "0", count: 64),
            token: "successor-client-token"
        )
        fixture.http.releaseGates()
        await revoke.value

        let client = try await fixture.credentialStore.readToken(for: fixture.host.endpoint)
        let admin = try await fixture.credentialStore.readToken(
            for: fixture.host.endpoint, role: .administrator
        )
        XCTAssertEqual(client, "successor-client-token")
        XCTAssertEqual(admin, "boot-admin")
        XCTAssertEqual(fixture.connections.savedHosts.count, 1)
        XCTAssertEqual(fixture.connections.savedHosts.first?.endpoint, fixture.host.endpoint)
        XCTAssertEqual(
            fixture.connections.savedHosts.first?.displayName,
            "Garage router re-enrolled"
        )
        XCTAssertEqual(fixture.model.tokens, [])
        XCTAssertNil(fixture.model.tokensError)
        XCTAssertEqual(fixture.http.calls.map(\.path), [
            "/api/v1/settings",
            "/api/v1/tokens",
            "/api/v1/tokens/self-id",
            "/api/v1/tokens",
        ])
    }

    func testSelfRevokeCleanupBeforeSameEndpointReenrollmentLeavesSuccessorSavedLast() async throws {
        let list = #"[{"id":"self-id","label":"This iPhone","created_at":"2026-07-17T20:00:00Z","last_seen_at":null,"bootstrap":false}]"#
        let backend = FirstDeleteGatedAdministrationBackend()
        let fixture = try await makeFixture(
            results: [
                AdminScriptedHTTP.ok("{}"),
                AdminScriptedHTTP.ok(list),
                AdminScriptedHTTP.ok(#"{"revoked":"self-id"}"#),
                AdminScriptedHTTP.ok("[]"),
            ],
            hostTokenID: "self-id",
            credentialBackend: backend
        )
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")
        await fixture.model.reloadTokens()
        let token = try XCTUnwrap(fixture.model.tokens.first)

        let revoke = Task { await fixture.model.revoke(token) }
        await backend.waitForFirstDeleteToStart()
        let reenrollment = Task {
            try await fixture.connections.saveManualHost(
                address: "https://router.local:8378",
                displayName: "Garage router re-enrolled",
                reachability: .lan,
                allowsInsecureWAN: false,
                deviceID: "DC:04:5A:EB:72:2B",
                certificateFingerprint: String(repeating: "0", count: 64),
                token: "successor-client-token"
            )
        }
        await Task.yield()
        await backend.releaseFirstDelete()
        await revoke.value
        _ = try await reenrollment.value

        let client = try await fixture.credentialStore.readToken(for: fixture.host.endpoint)
        let admin = try await fixture.credentialStore.readToken(
            for: fixture.host.endpoint, role: .administrator
        )
        XCTAssertEqual(client, "successor-client-token")
        XCTAssertEqual(admin, "boot-admin")
        XCTAssertEqual(fixture.connections.savedHosts.count, 1)
        XCTAssertEqual(fixture.connections.savedHosts.first?.endpoint, fixture.host.endpoint)
        XCTAssertEqual(
            fixture.connections.savedHosts.first?.displayName,
            "Garage router re-enrolled"
        )
        XCTAssertEqual(fixture.model.tokens, [])
        XCTAssertNil(fixture.model.tokensError)
        XCTAssertEqual(fixture.http.calls.map(\.path), [
            "/api/v1/settings",
            "/api/v1/tokens",
            "/api/v1/tokens/self-id",
            "/api/v1/tokens",
        ])
    }

    func testDurableSelfRevokeAfterReunlockDoesNotRelistThroughNewAdminSession() async throws {
        let initial = #"[{"id":"self-id","label":"This iPhone","created_at":"2026-07-17T20:00:00Z","last_seen_at":null,"bootstrap":false}]"#
        let current = #"[{"id":"newer","label":"Newer","created_at":"2026-07-17T20:01:00Z","last_seen_at":null,"bootstrap":false}]"#
        let fixture = try await makeFixture(
            results: [
                AdminScriptedHTTP.ok("{}"),
                AdminScriptedHTTP.ok(initial),
                AdminScriptedHTTP.ok(#"{"revoked":"self-id"}"#),
                AdminScriptedHTTP.ok("{}"),
                AdminScriptedHTTP.ok(current),
                AdminScriptedHTTP.ok(#"[{"id":"stale","label":"Stale","created_at":"2026-07-17T19:00:00Z","last_seen_at":null,"bootstrap":false}]"#),
            ],
            hostTokenID: "self-id"
        )
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "old-admin")
        await fixture.model.reloadTokens()
        let token = try XCTUnwrap(fixture.model.tokens.first)
        fixture.http.gateNextRequest()

        let revoke = Task { await fixture.model.revoke(token) }
        await fixture.http.waitForGateRegistration()
        await fixture.model.lock()
        await fixture.model.unlock(token: "new-admin")
        let currentReload = Task { await fixture.model.reloadTokens() }
        for _ in 0..<100 { await Task.yield() }
        fixture.http.releaseGates()
        await revoke.value
        await currentReload.value

        let client = try await fixture.credentialStore.readToken(for: fixture.host.endpoint)
        XCTAssertNil(client)
        let admin = try await fixture.credentialStore.readToken(
            for: fixture.host.endpoint, role: .administrator
        )
        XCTAssertEqual(admin, "new-admin")
        XCTAssertEqual(fixture.connections.savedHosts, [fixture.host])
        XCTAssertEqual(fixture.model.access, .unlocked)
        XCTAssertEqual(fixture.model.tokens.map(\.id), ["newer"])
        XCTAssertNil(fixture.model.tokensError)
        XCTAssertEqual(fixture.http.calls.map(\.path), [
            "/api/v1/settings",
            "/api/v1/tokens",
            "/api/v1/tokens/self-id",
            "/api/v1/settings",
            "/api/v1/tokens",
        ])
    }

    func testDurableSelfRevokeCleansOldHostWithoutPublishingIntoReplacementEndpoint() async throws {
        let initial = #"[{"id":"self-id","label":"This iPhone","created_at":"2026-07-17T20:00:00Z","last_seen_at":null,"bootstrap":false}]"#
        let fixture = try await makeFixture(
            results: [
                AdminScriptedHTTP.ok("{}"),
                AdminScriptedHTTP.ok(initial),
                AdminScriptedHTTP.ok(#"{"revoked":"self-id"}"#),
                AdminScriptedHTTP.ok("{}"),
                AdminScriptedHTTP.ok(#"[{"id":"replacement","label":"Replacement","created_at":"2026-07-17T20:02:00Z","last_seen_at":null,"bootstrap":false}]"#),
            ],
            hostTokenID: "self-id"
        )
        let replacement = try RouterHostValidator.validate(
            "https://replacement.local:8378",
            displayName: "Replacement router",
            reachability: .lan,
            allowsInsecureWAN: false,
            deviceID: "AA:BB:CC:DD:EE:FF",
            certificateFingerprint: String(repeating: "1", count: 64),
            tokenID: "replacement-id"
        )
        try await fixture.credentialStore.saveToken(
            "replacement-admin", for: replacement.endpoint, role: .administrator
        )
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "old-admin")
        await fixture.model.reloadTokens()
        let token = try XCTUnwrap(fixture.model.tokens.first)
        fixture.http.gateNextRequest()

        let revoke = Task { await fixture.model.revoke(token) }
        await fixture.http.waitForGateRegistration()
        await fixture.model.begin(host: replacement)
        fixture.http.releaseGates()
        await revoke.value

        let client = try await fixture.credentialStore.readToken(for: fixture.host.endpoint)
        XCTAssertNil(client)
        let oldAdmin = try await fixture.credentialStore.readToken(
            for: fixture.host.endpoint, role: .administrator
        )
        let replacementAdmin = try await fixture.credentialStore.readToken(
            for: replacement.endpoint, role: .administrator
        )
        XCTAssertEqual(oldAdmin, "old-admin")
        XCTAssertEqual(replacementAdmin, "replacement-admin")
        XCTAssertEqual(fixture.connections.savedHosts, [fixture.host])
        XCTAssertEqual(fixture.model.host, replacement)
        XCTAssertEqual(fixture.model.access, .unlocked)
        XCTAssertEqual(fixture.model.tokens, [])
        XCTAssertNil(fixture.model.tokensError)
        XCTAssertEqual(fixture.http.calls.map(\.path), [
            "/api/v1/settings",
            "/api/v1/tokens",
            "/api/v1/tokens/self-id",
            "/api/v1/settings",
        ])
    }

    func testEndpointReplacementDuringClientLeaseReadSendsNoRevoke() async throws {
        let initial = #"[{"id":"self-id","label":"This iPhone","created_at":"2026-07-17T20:00:00Z","last_seen_at":null,"bootstrap":false}]"#
        let backend = NextClientReadGatedAdministrationBackend()
        let fixture = try await makeFixture(
            results: [
                AdminScriptedHTTP.ok("{}"),
                AdminScriptedHTTP.ok(initial),
                AdminScriptedHTTP.ok("{}"),
                AdminScriptedHTTP.ok(#"{"revoked":"self-id"}"#),
            ],
            hostTokenID: "self-id",
            credentialBackend: backend
        )
        let replacement = try RouterHostValidator.validate(
            "https://replacement.local:8378",
            displayName: "Replacement router",
            reachability: .lan,
            allowsInsecureWAN: false,
            deviceID: "AA:BB:CC:DD:EE:FF",
            certificateFingerprint: String(repeating: "1", count: 64),
            tokenID: "replacement-id"
        )
        try await fixture.credentialStore.saveToken(
            "replacement-admin", for: replacement.endpoint, role: .administrator
        )
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "old-admin")
        await fixture.model.reloadTokens()
        let token = try XCTUnwrap(fixture.model.tokens.first)
        await backend.gateNextClientRead()

        let revoke = Task { await fixture.model.revoke(token) }
        await backend.waitForClientReadToStart()
        await fixture.model.begin(host: replacement)
        await backend.releaseClientRead()
        await revoke.value

        let oldClient = try await fixture.credentialStore.readToken(for: fixture.host.endpoint)
        let replacementAdmin = try await fixture.credentialStore.readToken(
            for: replacement.endpoint, role: .administrator
        )
        XCTAssertEqual(oldClient, "wlt_client")
        XCTAssertEqual(replacementAdmin, "replacement-admin")
        XCTAssertEqual(fixture.model.host, replacement)
        XCTAssertEqual(fixture.model.access, .unlocked)
        XCTAssertFalse(fixture.http.calls.contains { $0.method == "DELETE" })
        XCTAssertEqual(fixture.http.calls.map(\.path), [
            "/api/v1/settings",
            "/api/v1/tokens",
            "/api/v1/settings",
        ])
    }

    func testLockAndReunlockDuringClientLeaseReadSendsNoRevoke() async throws {
        let initial = #"[{"id":"self-id","label":"This iPhone","created_at":"2026-07-17T20:00:00Z","last_seen_at":null,"bootstrap":false}]"#
        let backend = NextClientReadGatedAdministrationBackend()
        let fixture = try await makeFixture(
            results: [
                AdminScriptedHTTP.ok("{}"),
                AdminScriptedHTTP.ok(initial),
                AdminScriptedHTTP.ok("{}"),
                AdminScriptedHTTP.ok(#"{"revoked":"self-id"}"#),
            ],
            hostTokenID: "self-id",
            credentialBackend: backend
        )
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "old-admin")
        await fixture.model.reloadTokens()
        let token = try XCTUnwrap(fixture.model.tokens.first)
        await backend.gateNextClientRead()

        let revoke = Task { await fixture.model.revoke(token) }
        await backend.waitForClientReadToStart()
        await fixture.model.lock()
        await fixture.model.unlock(token: "new-admin")
        await backend.releaseClientRead()
        await revoke.value

        let client = try await fixture.credentialStore.readToken(for: fixture.host.endpoint)
        let admin = try await fixture.credentialStore.readToken(
            for: fixture.host.endpoint, role: .administrator
        )
        XCTAssertEqual(client, "wlt_client")
        XCTAssertEqual(admin, "new-admin")
        XCTAssertEqual(fixture.model.host, fixture.host)
        XCTAssertEqual(fixture.model.access, .unlocked)
        XCTAssertFalse(fixture.http.calls.contains { $0.method == "DELETE" })
        XCTAssertEqual(fixture.http.calls.map(\.path), [
            "/api/v1/settings",
            "/api/v1/tokens",
            "/api/v1/settings",
        ])
    }

    func testSessionEndDuringClientLeaseReadSendsNoRevoke() async throws {
        let initial = #"[{"id":"self-id","label":"This iPhone","created_at":"2026-07-17T20:00:00Z","last_seen_at":null,"bootstrap":false}]"#
        let backend = NextClientReadGatedAdministrationBackend()
        let fixture = try await makeFixture(
            results: [
                AdminScriptedHTTP.ok("{}"),
                AdminScriptedHTTP.ok(initial),
                AdminScriptedHTTP.ok(#"{"revoked":"self-id"}"#),
            ],
            hostTokenID: "self-id",
            credentialBackend: backend
        )
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "old-admin")
        await fixture.model.reloadTokens()
        let token = try XCTUnwrap(fixture.model.tokens.first)
        await backend.gateNextClientRead()

        let revoke = Task { await fixture.model.revoke(token) }
        await backend.waitForClientReadToStart()
        await fixture.model.end()
        await backend.releaseClientRead()
        await revoke.value

        let client = try await fixture.credentialStore.readToken(for: fixture.host.endpoint)
        let admin = try await fixture.credentialStore.readToken(
            for: fixture.host.endpoint, role: .administrator
        )
        XCTAssertEqual(client, "wlt_client")
        XCTAssertEqual(admin, "old-admin")
        XCTAssertNil(fixture.model.host)
        XCTAssertEqual(fixture.model.access, .locked)
        XCTAssertFalse(fixture.http.calls.contains { $0.method == "DELETE" })
        XCTAssertEqual(fixture.http.calls.map(\.path), [
            "/api/v1/settings",
            "/api/v1/tokens",
        ])
    }

    func testSelfRevokeCleanupFailureIsVisibleWhileHostAndAdminSurviveAndRelistRuns() async throws {
        let initial = #"[{"id":"self-id","label":"This iPhone","created_at":"2026-07-17T20:00:00Z","last_seen_at":null,"bootstrap":false}]"#
        let backend = ClientDeleteFailingAdministrationBackend()
        let fixture = try await makeFixture(
            results: [
                AdminScriptedHTTP.ok("{}"),
                AdminScriptedHTTP.ok(initial),
                AdminScriptedHTTP.ok(#"{"revoked":"self-id"}"#),
                AdminScriptedHTTP.ok("[]"),
            ],
            hostTokenID: "self-id",
            credentialBackend: backend
        )
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")
        await fixture.model.reloadTokens()

        await fixture.model.revoke(try XCTUnwrap(fixture.model.tokens.first))

        XCTAssertEqual(fixture.model.tokens, [])
        XCTAssertEqual(
            fixture.model.tokensError,
            "Token was revoked, but this device's local client credential could not be removed."
        )
        XCTAssertEqual(fixture.model.access, .unlocked)
        XCTAssertEqual(fixture.model.host, fixture.host)
        XCTAssertEqual(fixture.connections.savedHosts, [fixture.host])
        let client = try await fixture.credentialStore.readToken(for: fixture.host.endpoint)
        XCTAssertEqual(client, "wlt_client")
        let admin = try await fixture.credentialStore.readToken(
            for: fixture.host.endpoint, role: .administrator
        )
        XCTAssertEqual(admin, "boot-admin")
        XCTAssertEqual(fixture.http.calls.map(\.path), [
            "/api/v1/settings",
            "/api/v1/tokens",
            "/api/v1/tokens/self-id",
            "/api/v1/tokens",
        ])
        let deleteAttempts = await backend.clientDeleteAttempts
        XCTAssertEqual(deleteAttempts, 1)
    }

    func testStaleSelfRevokeCleanupLeaseSkipsBackendFailureAndPreservesReenrollment() async throws {
        let initial = #"[{"id":"self-id","label":"This iPhone","created_at":"2026-07-17T20:00:00Z","last_seen_at":null,"bootstrap":false}]"#
        let backend = ClientDeleteFailingAdministrationBackend()
        let fixture = try await makeFixture(
            results: [
                AdminScriptedHTTP.ok("{}"),
                AdminScriptedHTTP.ok(initial),
                AdminScriptedHTTP.ok(#"{"revoked":"self-id"}"#),
                AdminScriptedHTTP.ok("[]"),
            ],
            hostTokenID: "self-id",
            credentialBackend: backend
        )
        await fixture.model.begin(host: fixture.host)
        await fixture.model.unlock(token: "boot-admin")
        await fixture.model.reloadTokens()
        let token = try XCTUnwrap(fixture.model.tokens.first)
        fixture.http.gateNextRequest()

        let revoke = Task { await fixture.model.revoke(token) }
        await fixture.http.waitForGateRegistration()
        _ = try await fixture.connections.saveManualHost(
            address: "https://router.local:8378",
            displayName: "Garage router re-enrolled",
            reachability: .lan,
            allowsInsecureWAN: false,
            deviceID: "DC:04:5A:EB:72:2B",
            certificateFingerprint: String(repeating: "0", count: 64),
            token: "successor-client-token"
        )
        fixture.http.releaseGates()
        await revoke.value

        let client = try await fixture.credentialStore.readToken(for: fixture.host.endpoint)
        let admin = try await fixture.credentialStore.readToken(
            for: fixture.host.endpoint, role: .administrator
        )
        let deleteAttempts = await backend.clientDeleteAttempts
        XCTAssertEqual(client, "successor-client-token")
        XCTAssertEqual(admin, "boot-admin")
        XCTAssertEqual(deleteAttempts, 0)
        XCTAssertEqual(fixture.connections.savedHosts.count, 1)
        XCTAssertEqual(fixture.connections.savedHosts.first?.endpoint, fixture.host.endpoint)
        XCTAssertEqual(
            fixture.connections.savedHosts.first?.displayName,
            "Garage router re-enrolled"
        )
        XCTAssertEqual(fixture.model.tokens, [])
        XCTAssertNil(fixture.model.tokensError)
    }

    func testBootstrapTokenRowHasBadgeButNoRevokeActionOrConfirmation() throws {
        let token = try tokenMetadata(
            id: "bootstrap", label: "Bootstrap administrator", bootstrap: true
        )

        let presentation = RouterTokenRowPresentation(
            token: token, isCurrentClient: true
        )

        XCTAssertTrue(presentation.showsBootstrapBadge)
        XCTAssertFalse(presentation.showsCurrentDeviceBadge)
        XCTAssertFalse(presentation.showsRevokeAction)
        XCTAssertNil(presentation.confirmation)
    }

    func testCurrentClientRowUsesExplicitSelfRevocationConfirmation() throws {
        let token = try tokenMetadata(id: "self-id", label: "This iPhone")

        let presentation = RouterTokenRowPresentation(
            token: token, isCurrentClient: true
        )

        XCTAssertFalse(presentation.showsBootstrapBadge)
        XCTAssertTrue(presentation.showsCurrentDeviceBadge)
        XCTAssertTrue(presentation.showsRevokeAction)
        XCTAssertEqual(
            presentation.confirmation,
            RouterTokenRevocationConfirmation(
                title: "Revoke this device's token?",
                actionTitle: "Revoke This iPhone",
                message: "This is this device's own token. Live updates stop immediately and this router returns to setup."
            )
        )
    }

    func testOtherClientRowUsesOtherClientRevocationConfirmation() throws {
        let token = try tokenMetadata(id: "other-id", label: "Other phone")

        let presentation = RouterTokenRowPresentation(
            token: token, isCurrentClient: false
        )

        XCTAssertTrue(presentation.showsRevokeAction)
        XCTAssertEqual(
            presentation.confirmation,
            RouterTokenRevocationConfirmation(
                title: "Revoke Other phone?",
                actionTitle: "Revoke Other phone",
                message: "Revocation is immediate and closes that client's live updates."
            )
        )
    }

    func testTokenSectionsAreStructurallyAbsentWhileLocked() async throws {
        let fixture = try await makeFixture(results: [AdminScriptedHTTP.ok("{}")])
        await fixture.model.begin(host: fixture.host)

        XCTAssertFalse(
            RouterAdministrationPresentation(access: fixture.model.access)
                .visibleSections.contains(.apiClients)
        )

        await fixture.model.unlock(token: "boot-admin")

        XCTAssertTrue(
            RouterAdministrationPresentation(access: fixture.model.access)
                .visibleSections.contains(.apiClients)
        )
    }

    func testEnrollmentPersistsTokenMetadataIDWithoutPersistingSecretInHostMetadata() async throws {
        let secret = "wlt_persistence-audit-secret"
        let body = #"{"token":"\#(secret)","token_metadata":{"id":"7dd64d22b0c14e7b"},"device_id":"DC:04:5A:EB:72:2B","base_urls":{"http":"http://wattline.lan:8377/api/v1"},"tls_sha256":"","magic_dns_name":""}"#
        let enrollmentHTTP = AdministrationEnrollmentHTTP(responseBody: body)
        let hostBackend = AdministrationHostBackend()
        let hostStore = RouterHostStore(backend: hostBackend)
        let credentials = RouterCredentialStore(backend: AdministrationMemoryBackend())
        let connections = RouterConnectionModel(
            hostStore: hostStore,
            credentialStore: credentials,
            enrollmentClientFactory: { _ in RouterEnrollmentClient(httpClient: enrollmentHTTP) },
            transportFactory: { _, _ in throw NetworkError.unsupported("unused") }
        )
        let payload = try RouterPairingPayload.parse(URL(string:
            "wattline://pair?v=1&id=DC045AEB722B&host=wattline.lan&http=8377&pin=123456"
        )!)

        let host = try await connections.enroll(
            payload: payload,
            displayName: "Garage router",
            reachability: .lan,
            label: "This iPhone"
        )

        XCTAssertEqual(host.tokenID, "7dd64d22b0c14e7b")
        XCTAssertEqual(connections.savedHosts.first?.tokenID, "7dd64d22b0c14e7b")
        let persisted = try XCTUnwrap(hostBackend.data(forKey: RouterHostStore.defaultKey))
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains(secret))
        let storedSecret = try await credentials.readToken(for: host.endpoint)
        XCTAssertEqual(storedSecret, secret)
    }
}

private func tokenMetadata(
    id: String,
    label: String,
    bootstrap: Bool = false
) throws -> RouterTokenMetadata {
    let data = try JSONSerialization.data(withJSONObject: [
        "id": id,
        "label": label,
        "created_at": "2026-07-17T20:00:00Z",
        "last_seen_at": NSNull(),
        "bootstrap": bootstrap,
    ])
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(RouterTokenMetadata.self, from: data)
}

private final class PairingExpirySleepFixture: @unchecked Sendable {
    private struct Pending {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var pending: [Pending] = []
    private var canceledBeforeRegistration: Set<UUID> = []
    private var completed: Set<UUID> = []
    private var deadlines: [Date] = []
    private var cancellations = 0

    var deadlineHistory: [Date] { lock.withLock { deadlines } }
    var cancellationCount: Int { lock.withLock { cancellations } }

    func sleep(until deadline: Date) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelImmediately = lock.withLock {
                    deadlines.append(deadline)
                    if canceledBeforeRegistration.remove(id) != nil {
                        completed.insert(id)
                        return true
                    }
                    pending.append(Pending(id: id, continuation: continuation))
                    return false
                }
                if cancelImmediately {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            self.cancel(id: id)
        }
    }

    func resumeFirst() {
        let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
            guard !pending.isEmpty else { return nil }
            let next = pending.removeFirst()
            completed.insert(next.id)
            return next.continuation
        }
        continuation?.resume()
    }

    func waitForDeadlineCount(_ count: Int) async {
        while deadlineHistory.count < count { await Task.yield() }
    }

    func waitForCancellationCount(_ count: Int) async {
        while cancellationCount < count { await Task.yield() }
    }

    private func cancel(id: UUID) {
        let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
            guard completed.contains(id) == false else { return nil }
            cancellations += 1
            guard let index = pending.firstIndex(where: { $0.id == id }) else {
                canceledBeforeRegistration.insert(id)
                return nil
            }
            let value = pending.remove(at: index)
            completed.insert(id)
            return value.continuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}

@MainActor
private struct AdministrationFixture {
    let model: RouterAdministrationModel
    let connections: RouterConnectionModel
    let host: RouterHostMetadata
    let credentialStore: RouterCredentialStore
    let http: AdminScriptedHTTP
    let historyHTTP: AdminScriptedHTTP
}

@MainActor
private func makeFixture(
    results: [Result<(Data, HTTPURLResponse), Error>],
    historyResults: [Result<(Data, HTTPURLResponse), Error>] = [],
    now: @escaping () -> Date = { Date() },
    pairingExpirySleep: (@MainActor @Sendable (Date) async throws -> Void)? = nil,
    gateRequests: Bool = false,
    historyGateRequests: Bool = false,
    historyGatedCallNumbers: Set<Int> = [],
    hostTokenID: String? = nil,
    credentialBackend: any RouterCredentialBackend = AdministrationMemoryBackend()
) async throws -> AdministrationFixture {
    let host = try RouterHostValidator.validate(
        "https://router.local:8378",
        displayName: "Garage router",
        reachability: .lan,
        allowsInsecureWAN: false,
        deviceID: "DC:04:5A:EB:72:2B",
        certificateFingerprint: String(repeating: "0", count: 64),
        tokenID: hostTokenID
    )
    let credentialStore = RouterCredentialStore(backend: credentialBackend)
    let hostStore = RouterHostStore(backend: AdministrationHostBackend())
    try await hostStore.save(host)
    let connections = RouterConnectionModel(
        hostStore: hostStore,
        credentialStore: credentialStore,
        enrollmentClientFactory: { _ in
            RouterEnrollmentClient(httpClient: AdministrationNoopEnrollmentHTTP())
        },
        transportFactory: { _, _ in throw NetworkError.unsupported("no transport in tests") }
    )
    let http = AdminScriptedHTTP(results: results, gateRequests: gateRequests)
    let historyHTTP = AdminScriptedHTTP(
        results: historyResults,
        gateRequests: historyGateRequests,
        gatedCallNumbers: historyGatedCallNumbers
    )
    let adminClient = RouterAdministrationClient(credentials: credentialStore) { _ in http }
    let historyClientFactory: (RouterEndpoint) throws -> RouterHistoryClient = { endpoint in
        RouterHistoryClient(
            httpClient: historyHTTP,
            credentials: credentialStore,
            endpoint: endpoint
        )
    }
    let model: RouterAdministrationModel
    if let pairingExpirySleep {
        model = RouterAdministrationModel(
            connections: connections,
            adminClient: adminClient,
            historyClientFactory: historyClientFactory,
            now: now,
            pairingExpirySleep: pairingExpirySleep
        )
    } else {
        model = RouterAdministrationModel(
            connections: connections,
            adminClient: adminClient,
            historyClientFactory: historyClientFactory,
            now: now
        )
    }
    try await credentialStore.saveToken("wlt_client", for: host.endpoint)
    await connections.reloadSavedHosts()
    return AdministrationFixture(
        model: model,
        connections: connections,
        host: host,
        credentialStore: credentialStore,
        http: http,
        historyHTTP: historyHTTP
    )
}

private final class AdminScriptedHTTP: RouterHTTPClient, @unchecked Sendable {
    struct Call: Equatable {
        let method: String
        let path: String
        let token: String
    }

    private let lock = NSLock()
    private var scripted: [Result<(Data, HTTPURLResponse), Error>]
    private var recorded: [Call] = []
    private var gates: [CheckedContinuation<Void, Never>] = []
    private var pendingGateReleases = 0
    private var gateRegistrationWaiters: [CheckedContinuation<Void, Never>] = []
    private var callCountWaiters: [(minimum: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private let shouldGate: Bool
    private let gatedCallNumbers: Set<Int>
    private var startedCallCount = 0
    private var gatesNextRequest = false

    init(
        results: [Result<(Data, HTTPURLResponse), Error>],
        gateRequests: Bool,
        gatedCallNumbers: Set<Int> = []
    ) {
        scripted = results
        shouldGate = gateRequests
        self.gatedCallNumbers = gatedCallNumbers
    }

    var calls: [Call] {
        lock.withLock { recorded }
    }

    static func ok(_ json: String) -> Result<(Data, HTTPURLResponse), Error> {
        .success((
            Data(json.utf8),
            HTTPURLResponse(
                url: URL(string: "https://fixture.invalid")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
        ))
    }

    static func pngResponse() -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://router.local:8378")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "image/png"]
        )!
    }

    func gateNextRequest() {
        lock.withLock { gatesNextRequest = true }
    }

    func get(_ path: String, token: String) async throws -> (Data, HTTPURLResponse) {
        try await request("GET", path, body: nil, token: token)
    }

    func request(
        _ method: String,
        _ path: String,
        body: Data?,
        token: String
    ) async throws -> (Data, HTTPURLResponse) {
        let (result, shouldGateRequest) = lock.withLock {
            startedCallCount += 1
            let result = scripted.isEmpty ? nil : scripted.removeFirst()
            let shouldGateRequest = shouldGate
                || gatedCallNumbers.contains(startedCallCount)
                || gatesNextRequest
            gatesNextRequest = false
            return (result, shouldGateRequest)
        }
        if shouldGateRequest {
            await withCheckedContinuation { gate in
                let (shouldResumeGate, gateWaiters, callWaiters) = lock.withLock {
                    recorded.append(Call(method: method, path: path, token: token))
                    let shouldResumeGate = pendingGateReleases > 0
                    if shouldResumeGate {
                        pendingGateReleases -= 1
                    } else {
                        gates.append(gate)
                    }
                    let gateWaiters = gateRegistrationWaiters
                    gateRegistrationWaiters = []
                    let callWaiters = removeSatisfiedCallCountWaiters()
                    return (shouldResumeGate, gateWaiters, callWaiters)
                }
                gateWaiters.forEach { $0.resume() }
                callWaiters.forEach { $0.resume() }
                if shouldResumeGate { gate.resume() }
            }
        } else {
            let callWaiters = lock.withLock {
                recorded.append(Call(method: method, path: path, token: token))
                return removeSatisfiedCallCountWaiters()
            }
            callWaiters.forEach { $0.resume() }
        }
        guard let result else { throw NetworkError.decode("admin HTTP fixture exhausted") }
        return try result.get()
    }

    func waitForGateRegistration() async {
        await withCheckedContinuation { continuation in
            let isAlreadyRegistered = lock.withLock {
                guard gates.isEmpty else { return true }
                gateRegistrationWaiters.append(continuation)
                return false
            }
            if isAlreadyRegistered { continuation.resume() }
        }
    }

    func waitForCallCount(_ minimum: Int) async {
        await withCheckedContinuation { continuation in
            let isAlreadySatisfied = lock.withLock {
                guard recorded.count < minimum else { return true }
                callCountWaiters.append((minimum, continuation))
                return false
            }
            if isAlreadySatisfied { continuation.resume() }
        }
    }

    func releaseGates() {
        let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard !gates.isEmpty else {
                pendingGateReleases += 1
                return []
            }
            let pending = gates
            gates.removeAll()
            return pending
        }
        pending.forEach { $0.resume() }
    }

    func releaseNewestGate() {
        let gate: CheckedContinuation<Void, Never>? = lock.withLock {
            gates.popLast()
        }
        gate?.resume()
    }

    private func removeSatisfiedCallCountWaiters() -> [CheckedContinuation<Void, Never>] {
        let satisfied = callCountWaiters.filter { recorded.count >= $0.minimum }
        callCountWaiters.removeAll { recorded.count >= $0.minimum }
        return satisfied.map(\.continuation)
    }
}

private actor AdministrationMemoryBackend: RouterCredentialBackend {
    private var values: [String: Data] = [:]
    func read(account: String) async throws -> Data? { values[account] }
    func save(_ data: Data, account: String) async throws { values[account] = data }
    func delete(account: String) async throws { values[account] = nil }
}

private actor NextClientReadGatedAdministrationBackend: RouterCredentialBackend {
    private var values: [String: Data] = [:]
    private var shouldGateClientRead = false
    private var clientReadStarted = false
    private var clientReadStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var clientReadGate: CheckedContinuation<Void, Never>?

    func read(account: String) async throws -> Data? {
        if shouldGateClientRead, !account.hasSuffix(".administrator") {
            shouldGateClientRead = false
            clientReadStarted = true
            let waiters = clientReadStartedWaiters
            clientReadStartedWaiters = []
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { clientReadGate = $0 }
        }
        return values[account]
    }

    func save(_ data: Data, account: String) async throws { values[account] = data }
    func delete(account: String) async throws { values[account] = nil }

    func gateNextClientRead() {
        shouldGateClientRead = true
        clientReadStarted = false
    }

    func waitForClientReadToStart() async {
        if clientReadStarted { return }
        await withCheckedContinuation { clientReadStartedWaiters.append($0) }
    }

    func releaseClientRead() {
        clientReadGate?.resume()
        clientReadGate = nil
    }
}

private actor SpecificClientReadGatedAdministrationBackend: RouterCredentialBackend {
    private var values: [String: Data] = [:]
    private var gatedAccount: String?
    private var clientReadStarted = false
    private var clientReadStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var clientReadGate: CheckedContinuation<Void, Never>?

    func read(account: String) async throws -> Data? {
        if account == gatedAccount {
            gatedAccount = nil
            clientReadStarted = true
            let waiters = clientReadStartedWaiters
            clientReadStartedWaiters = []
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { clientReadGate = $0 }
        }
        return values[account]
    }

    func save(_ data: Data, account: String) async throws { values[account] = data }
    func delete(account: String) async throws { values[account] = nil }

    func gateNextClientRead(account: String) {
        gatedAccount = account
        clientReadStarted = false
    }

    func waitForClientReadToStart() async {
        if clientReadStarted { return }
        await withCheckedContinuation { clientReadStartedWaiters.append($0) }
    }

    func releaseClientRead() {
        clientReadGate?.resume()
        clientReadGate = nil
    }
}

private actor ClientDeleteFailingAdministrationBackend: RouterCredentialBackend {
    private enum DeleteFailure: Error { case denied }
    private var values: [String: Data] = [:]
    private(set) var clientDeleteAttempts = 0

    func read(account: String) async throws -> Data? { values[account] }
    func save(_ data: Data, account: String) async throws { values[account] = data }

    func delete(account: String) async throws {
        guard account.hasSuffix(".administrator") else {
            clientDeleteAttempts += 1
            throw DeleteFailure.denied
        }
        values[account] = nil
    }
}

private actor FirstDeleteGatedAdministrationBackend: RouterCredentialBackend {
    private var values: [String: Data] = [:]
    private(set) var saveCount = 0
    private var deleteCount = 0
    private var firstDeleteStarted = false
    private var firstDeleteStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstDeleteGate: CheckedContinuation<Void, Never>?

    func read(account: String) async throws -> Data? { values[account] }
    func save(_ data: Data, account: String) async throws {
        values[account] = data
        if account.hasSuffix(".administrator") {
            saveCount += 1
        }
    }

    func delete(account: String) async throws {
        deleteCount += 1
        if deleteCount == 1 {
            firstDeleteStarted = true
            let waiters = firstDeleteStartedWaiters
            firstDeleteStartedWaiters = []
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { firstDeleteGate = $0 }
        }
        values[account] = nil
    }

    func waitForFirstDeleteToStart() async {
        if firstDeleteStarted { return }
        await withCheckedContinuation { firstDeleteStartedWaiters.append($0) }
    }

    func releaseFirstDelete() {
        firstDeleteGate?.resume()
        firstDeleteGate = nil
    }
}

private actor FirstSaveGatedAdministrationBackend: RouterCredentialBackend {
    private var values: [String: Data] = [:]
    private var saveCount = 0
    private var firstSaveStarted = false
    private var firstSaveStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstSaveGate: CheckedContinuation<Void, Never>?

    func read(account: String) async throws -> Data? { values[account] }

    func save(_ data: Data, account: String) async throws {
        if account.hasSuffix(".administrator") {
            saveCount += 1
        }
        if saveCount == 1, account.hasSuffix(".administrator") {
            firstSaveStarted = true
            let waiters = firstSaveStartedWaiters
            firstSaveStartedWaiters = []
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { firstSaveGate = $0 }
        }
        values[account] = data
    }

    func delete(account: String) async throws { values[account] = nil }

    func waitForFirstSaveToStart() async {
        if firstSaveStarted { return }
        await withCheckedContinuation { firstSaveStartedWaiters.append($0) }
    }

    func releaseFirstSave() {
        firstSaveGate?.resume()
        firstSaveGate = nil
    }
}

private final class AdministrationHostBackend: RouterHostKeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(forKey key: String) -> Data? {
        lock.withLock { values[key] }
    }

    func set(_ data: Data, forKey key: String) throws {
        lock.withLock { values[key] = data }
    }

    func removeValue(forKey key: String) throws {
        lock.withLock { values[key] = nil }
    }
}

private struct AdministrationNoopEnrollmentHTTP: RouterEnrollmentHTTPClient {
    func publicRequest(
        _ method: String,
        _ path: String,
        body: Data?
    ) async throws -> (Data, HTTPURLResponse) {
        throw NetworkError.unsupported("unused")
    }
}

private actor AdministrationEnrollmentHTTP: RouterEnrollmentHTTPClient {
    let responseBody: String

    init(responseBody: String) {
        self.responseBody = responseBody
    }

    func publicRequest(
        _ method: String,
        _ path: String,
        body: Data?
    ) async throws -> (Data, HTTPURLResponse) {
        (
            Data(responseBody.utf8),
            HTTPURLResponse(
                url: URL(string: "http://router.local\(path)")!,
                statusCode: 201,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }
}
