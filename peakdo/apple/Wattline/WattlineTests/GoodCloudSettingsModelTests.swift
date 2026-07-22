import Foundation
import WattlineCore
@testable import WattlineNetwork
import XCTest
@testable import Wattline

@MainActor
final class GoodCloudSettingsModelTests: XCTestCase {
    func testLoginForwardsPasswordWithoutRetainingItAndRefreshesRemoteAccess() async throws {
        let fixture = try await makeFixture()
        var password = "secret-password"

        await fixture.model.login(email: "owner@example.com", password: password)
        password = ""

        XCTAssertEqual(password, "")
        XCTAssertEqual(fixture.model.state, .authenticated)
        XCTAssertEqual(fixture.model.devices, [fixture.device])
        let loginInputs = await fixture.account.recordedLoginInputs()
        let validationCount = await fixture.account.recordedValidationCount()
        XCTAssertEqual(loginInputs, [
            .init(email: "owner@example.com", password: "secret-password"),
        ])
        XCTAssertEqual(validationCount, 0)
        XCTAssertFalse(String(describing: fixture.model).contains("secret-password"))
    }

    func testSuggestedDeviceDoesNotAssociateUntilExplicitSelection() async throws {
        let fixture = try await makeFixture()
        await fixture.model.load()

        XCTAssertEqual(fixture.model.suggestedDevice?.id, fixture.device.id)
        XCTAssertNil(fixture.model.association)

        try await fixture.model.associate(deviceID: fixture.device.id)

        XCTAssertEqual(fixture.model.association?.goodCloudDeviceID, fixture.device.id)
        let savedAssociation = await fixture.associations.association(forHostID: fixture.host.id)
        XCTAssertEqual(savedAssociation, fixture.model.association)
    }

    func testRemovingAssociationLeavesSavedHostAndBearerCredentialsAlone() async throws {
        let fixture = try await makeFixture()
        await fixture.model.load()
        try await fixture.model.associate(deviceID: fixture.device.id)
        let validationsBeforeRemoval = await fixture.account.recordedValidationCount()

        try await fixture.model.removeAssociation()

        XCTAssertNil(fixture.model.association)
        XCTAssertEqual(fixture.connections.savedHosts, [fixture.host])
        let validationsAfterRemoval = await fixture.account.recordedValidationCount()
        XCTAssertEqual(validationsAfterRemoval, validationsBeforeRemoval)
    }

    func testOfflineDeviceCannotBeAssociated() async throws {
        let offline = GoodCloudDeviceSummary(
            id: "99",
            name: "Offline router",
            mac: "AA:BB:CC:DD:EE:FF",
            ddns: nil,
            model: "GL-X3000",
            isOnline: false
        )
        let fixture = try await makeFixture(devices: [offline])
        await fixture.model.load()

        do {
            try await fixture.model.associate(deviceID: offline.id)
            XCTFail("expected offline association to be rejected")
        } catch {
            XCTAssertEqual(error as? GoodCloudSettingsError, .deviceOffline)
        }
        let savedAssociation = await fixture.associations.association(forHostID: fixture.host.id)
        XCTAssertNil(savedAssociation)
    }

    func testLogoutRefreshesRemoteAccessAndKeepsNonSecretAssociation() async throws {
        let fixture = try await makeFixture()
        await fixture.model.load()
        try await fixture.model.associate(deviceID: fixture.device.id)
        let association = try XCTUnwrap(fixture.model.association)
        let validationsBeforeLogout = await fixture.account.recordedValidationCount()

        await fixture.model.logout()

        XCTAssertEqual(fixture.model.state, .loggedOut)
        XCTAssertEqual(fixture.model.devices, [])
        XCTAssertEqual(fixture.model.association, association)
        let logoutCount = await fixture.account.recordedLogoutCount()
        let validationsAfterLogout = await fixture.account.recordedValidationCount()
        XCTAssertEqual(logoutCount, 1)
        XCTAssertEqual(validationsAfterLogout, validationsBeforeLogout)
    }

    func testLogoutDoesNotClaimLoggedOutWhenCredentialRemovalDidNotClearSession() async throws {
        let fixture = try await makeFixture(clearsSessionOnLogout: false)
        await fixture.model.load()

        await fixture.model.logout()

        XCTAssertEqual(fixture.model.state, .authenticated)
        XCTAssertEqual(fixture.model.devices, [fixture.device])
    }

    func testChangingAssociationRefreshesRouteSnapshotEachTime() async throws {
        let second = GoodCloudDeviceSummary(
            id: "43",
            name: "Second router",
            mac: "11:22:33:44:55:66",
            ddns: "second.glddns.com",
            model: "GL-X3000",
            isOnline: true
        )
        let fixture = try await makeFixture(devices: [Self.defaultDevice, second])
        await fixture.model.load()
        let validationsBeforeSelection = await fixture.account.recordedValidationCount()

        try await fixture.model.associate(deviceID: Self.defaultDevice.id)
        try await fixture.model.associate(deviceID: second.id)

        XCTAssertEqual(fixture.model.association?.goodCloudDeviceID, second.id)
        let validationsAfterSelection = await fixture.account.recordedValidationCount()
        XCTAssertEqual(validationsAfterSelection, validationsBeforeSelection)
    }

    func testLoginPublishesTheSameAccountResultWithoutASecondValidation() async throws {
        let fixture = try await makeFixture()
        let validationsBeforeLogin = await fixture.account.recordedValidationCount()

        await fixture.model.login(email: "owner@example.com", password: "secret")

        XCTAssertEqual(fixture.model.state, .authenticated)
        let loginCount = await fixture.account.recordedLoginCount()
        let validationsAfterLogin = await fixture.account.recordedValidationCount()
        XCTAssertEqual(loginCount, 1)
        XCTAssertEqual(validationsAfterLogin, validationsBeforeLogin)
    }

    func testRequiresLoginLoadClearsPreviouslyEnabledPreferredTransportAndAdministrationRoute() async throws {
        let recorder = SettingsRouteRecorder()
        let fixture = try await makeFixture(routeRecorder: recorder)
        await fixture.model.load()
        try await fixture.model.associate(deviceID: fixture.device.id)

        _ = try fixture.connections.makeTransport(for: fixture.host)
        _ = try fixture.connections.administrationHTTPFactory(fixture.host.endpoint)
        await fixture.account.setState(.requiresLogin)
        let validationsBeforeLoad = await fixture.account.recordedValidationCount()

        await fixture.model.load()
        _ = try fixture.connections.makeTransport(for: fixture.host)
        _ = try fixture.connections.administrationHTTPFactory(fixture.host.endpoint)

        XCTAssertEqual(fixture.model.state, .requiresLogin)
        let validationsAfterLoad = await fixture.account.recordedValidationCount()
        XCTAssertEqual(validationsAfterLoad, validationsBeforeLoad + 1)
        XCTAssertEqual(recorder.preferredTransportCount, 1)
        XCTAssertEqual(recorder.directTransportCount, 1)
        XCTAssertEqual(recorder.preferredHTTPCount, 1)
        XCTAssertEqual(recorder.directHTTPCount, 1)
    }

    func testRetryClearsOldFixedErrorBeforeLoginCompletes() async throws {
        let fixture = try await makeFixture()
        await fixture.account.setState(.failed("detail that must stay hidden"))
        await fixture.model.load()
        XCTAssertNotNil(fixture.model.errorMessage)
        await fixture.account.setState(.authenticated([fixture.device]))
        await fixture.account.holdNextLogin()

        let login = Task {
            await fixture.model.login(email: "owner@example.com", password: "secret")
        }
        try await waitUntil { await fixture.account.loginIsHeld }

        XCTAssertNil(fixture.model.errorMessage)
        await fixture.account.releaseLogin()
        await login.value
    }

    func testMultipleSavedHostsRequireExplicitActiveHostBeforeAssociationOrRemoval() async throws {
        let fixture = try await makeFixture(additionalHost: true)
        await fixture.model.load()

        XCTAssertNil(fixture.model.activeHostID)
        XCTAssertNil(fixture.model.savedHost)
        do {
            try await fixture.model.associate(deviceID: fixture.device.id)
            XCTFail("expected an explicit active host")
        } catch {
            XCTAssertEqual(error as? GoodCloudSettingsError, .noSavedRouter)
        }
        do {
            try await fixture.model.removeAssociation()
            XCTFail("expected removal to require an explicit active host")
        } catch {
            XCTAssertEqual(error as? GoodCloudSettingsError, .noSavedRouter)
        }
        let allAssociations = await fixture.associations.allAssociations()
        XCTAssertEqual(allAssociations, [])

        fixture.model.selectHost(fixture.host.id)
        try await fixture.model.associate(deviceID: fixture.device.id)
        XCTAssertEqual(fixture.model.association?.hostID, fixture.host.id)
    }

    func testLoadReloadsSavedHostsBeforeResolvingExplicitActiveHost() async throws {
        let fixture = try await makeFixture(reloadConnections: false, hostID: nil)
        XCTAssertEqual(fixture.connections.savedHosts, [])

        fixture.model.selectHost(fixture.host.id)
        await fixture.model.load()

        XCTAssertEqual(fixture.model.savedHost, fixture.host)
    }

    func testAssociatedDeviceAvailabilityUsesFreshDeviceResultInsteadOfPersistedAssociation() async throws {
        let fixture = try await makeFixture()
        await fixture.model.load()
        try await fixture.model.associate(deviceID: fixture.device.id)
        XCTAssertEqual(fixture.model.associatedDevice?.isOnline, true)

        let offline = GoodCloudDeviceSummary(
            id: fixture.device.id,
            name: "Fresh offline name",
            mac: fixture.device.mac,
            ddns: "fresh-offline.glddns.com",
            model: fixture.device.model,
            isOnline: false
        )
        await fixture.account.setState(.authenticated([offline]))
        await fixture.model.load()

        XCTAssertEqual(fixture.model.associatedDevice, offline)
        XCTAssertEqual(fixture.model.remoteAvailability, .offline)
        XCTAssertEqual(fixture.model.association?.isOnline, true, "persisted snapshot proves presentation is using fresh device state")
    }

    private func makeFixture(
        devices: [GoodCloudDeviceSummary] = [defaultDevice],
        clearsSessionOnLogout: Bool = true,
        additionalHost: Bool = false,
        reloadConnections: Bool = true,
        hostID: UUID? = nil,
        routeRecorder: SettingsRouteRecorder? = nil
    ) async throws -> SettingsFixture {
        let host = try RouterHostValidator.validate(
            "192.168.8.1:8377",
            displayName: "Wattline router",
            reachability: .lan,
            allowsInsecureWAN: false,
            deviceID: "dc-04-5a-eb-72-2b",
            certificateFingerprint: nil
        )
        let hostStore = RouterHostStore(backend: SettingsHostBackend())
        try await hostStore.save(host)
        if additionalHost {
            let second = try RouterHostValidator.validate(
                "192.168.9.1:8377",
                displayName: "Second Wattline router",
                reachability: .lan,
                allowsInsecureWAN: false,
                deviceID: "11:22:33:44:55:66",
                certificateFingerprint: nil
            )
            try await hostStore.save(second)
        }
        let account = SettingsAccountService(
            state: .authenticated(devices),
            clearsSessionOnLogout: clearsSessionOnLogout
        )
        let associations = GoodCloudAssociationStore(backend: SettingsAssociationBackend())
        let provisioner = GoodCloudAccountService.accountOnly(client: SettingsAccountClient())
        let connections = RouterConnectionModel(
            hostStore: hostStore,
            credentialStore: RouterCredentialStore(backend: SettingsCredentialBackend()),
            enrollmentClientFactory: { _ in throw NetworkError.unsupported("not used") },
            transportFactory: { _, _ in
                if let routeRecorder { return routeRecorder.makeDirectTransport() }
                throw NetworkError.unsupported("not used")
            },
            goodCloudAccount: .init(account: account, provisioner: provisioner),
            goodCloudAssociations: associations,
            preferredTransportFactory: { _, _, _, _ in
                if let routeRecorder { return routeRecorder.makePreferredTransport() }
                throw NetworkError.unsupported("not used")
            },
            administrationHTTPFactory: { endpoint in
                if let routeRecorder { return try routeRecorder.registry.client(for: endpoint) }
                throw NetworkError.unsupported("not used")
            },
            goodCloudAdministrationHTTPRegistry: routeRecorder?.registry
        )
        if reloadConnections {
            await connections.reloadSavedHosts(refreshGoodCloudRemoteAccess: false)
        }
        let model = GoodCloudSettingsModel(
            account: account,
            associations: associations,
            connections: connections,
            hostID: hostID ?? (additionalHost ? nil : host.id)
        )
        return SettingsFixture(
            model: model,
            account: account,
            associations: associations,
            connections: connections,
            host: host,
            device: devices[0]
        )
    }

    private static let defaultDevice = GoodCloudDeviceSummary(
        id: "42",
        name: "Wattline X3000",
        mac: "DC:04:5A:EB:72:2B",
        ddns: "wattline.glddns.com",
        model: "GL-X3000",
        isOnline: true
    )
}

private struct SettingsFixture {
    let model: GoodCloudSettingsModel
    let account: SettingsAccountService
    let associations: GoodCloudAssociationStore
    let connections: RouterConnectionModel
    let host: RouterHostMetadata
    let device: GoodCloudDeviceSummary
}

private actor SettingsAccountService: GoodCloudAccountServing {
    struct LoginInput: Equatable {
        let email: String
        let password: String
    }

    private var currentState: GoodCloudSessionState
    private(set) var loginInputs: [LoginInput] = []
    private(set) var validationCount = 0
    private(set) var logoutCount = 0
    private(set) var loginCount = 0
    private let clearsSessionOnLogout: Bool
    private var holdLogin = false
    private var loginContinuation: CheckedContinuation<Void, Never>?
    private(set) var loginIsHeld = false

    init(state: GoodCloudSessionState, clearsSessionOnLogout: Bool) {
        currentState = state
        self.clearsSessionOnLogout = clearsSessionOnLogout
    }

    func validateStoredSession() async -> GoodCloudSessionState {
        validationCount += 1
        return currentState
    }

    func login(email: String, password: String) async -> GoodCloudSessionState {
        loginCount += 1
        loginInputs.append(.init(email: email, password: password))
        if holdLogin {
            holdLogin = false
            loginIsHeld = true
            await withCheckedContinuation { loginContinuation = $0 }
            loginIsHeld = false
        }
        return currentState
    }

    func refreshDevices() async -> GoodCloudSessionState { currentState }

    func logout() async -> GoodCloudSessionState {
        logoutCount += 1
        if clearsSessionOnLogout {
            currentState = .loggedOut
        }
        return currentState
    }

    func recordedLoginInputs() -> [LoginInput] { loginInputs }
    func recordedValidationCount() -> Int { validationCount }
    func recordedLogoutCount() -> Int { logoutCount }
    func recordedLoginCount() -> Int { loginCount }
    func setState(_ state: GoodCloudSessionState) { currentState = state }
    func holdNextLogin() { holdLogin = true }
    func releaseLogin() {
        loginContinuation?.resume()
        loginContinuation = nil
    }
}

private actor SettingsAccountClient: GoodCloudAccountClient {
    func hasStoredToken() async -> Bool { false }
    func login(email: String, password: String) async throws {}
    func devices() async throws -> [GoodCloudDeviceSummary] { [] }
    func logout() async throws {}
}

private final class SettingsAssociationBackend: GoodCloudAssociationKeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(forKey key: String) -> Data? {
        lock.withLock { values[key] }
    }

    func set(_ data: Data?, forKey key: String) {
        lock.withLock { values[key] = data }
    }
}

private final class SettingsHostBackend: RouterHostKeyValueStore, @unchecked Sendable {
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

private actor SettingsCredentialBackend: RouterCredentialBackend {
    func read(account: String) async throws -> Data? { nil }
    func save(_ data: Data, account: String) async throws {}
    func delete(account: String) async throws {}
}

private final class SettingsRouteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var directTransports = 0
    private var preferredTransports = 0
    private var directHTTP = 0
    private var preferredHTTP = 0

    lazy var registry = GoodCloudAdministrationHTTPRegistry(
        directFactory: { [weak self] _ in
            self?.lock.withLock { self?.directHTTP += 1 }
            return SettingsNoopHTTPClient()
        },
        preferredFactory: { [weak self] _, _, _ in
            self?.lock.withLock { self?.preferredHTTP += 1 }
            return SettingsNoopHTTPClient()
        }
    )

    var directTransportCount: Int { lock.withLock { directTransports } }
    var preferredTransportCount: Int { lock.withLock { preferredTransports } }
    var directHTTPCount: Int { lock.withLock { directHTTP } }
    var preferredHTTPCount: Int { lock.withLock { preferredHTTP } }

    func makeDirectTransport() -> any DeviceTransport {
        lock.withLock { directTransports += 1 }
        return SettingsNoopTransport()
    }

    func makePreferredTransport() -> any DeviceTransport {
        lock.withLock { preferredTransports += 1 }
        return SettingsNoopTransport()
    }
}

private actor SettingsNoopHTTPClient: RouterHTTPClient {
    func get(_ path: String, token: String) async throws -> (Data, HTTPURLResponse) {
        throw NetworkError.unsupported("not used")
    }

    func request(
        _ method: String,
        _ path: String,
        body: Data?,
        token: String
    ) async throws -> (Data, HTTPURLResponse) {
        throw NetworkError.unsupported("not used")
    }
}

private actor SettingsNoopTransport: DeviceTransport {
    nonisolated let events: AsyncStream<DeviceEvent> = AsyncStream { _ in }
    func startScan() async throws {}
    func stopScan() async {}
    func connect(to id: UUID, scope: DeviceConnectionScope) async throws {}
    func disconnect() async {}
    func perform(_ command: DeviceCommand) async throws -> CommandOutcome { .sent }
    func refreshTelemetry() async throws {}
    func synchronizeDeviceTime() async throws {}
    func readDeviceTimeIfSupported() async throws -> Date? { nil }
}
