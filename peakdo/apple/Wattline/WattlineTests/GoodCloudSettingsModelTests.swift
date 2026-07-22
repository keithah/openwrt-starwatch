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
        XCTAssertEqual(validationCount, 2)
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
        XCTAssertEqual(validationsAfterRemoval, validationsBeforeRemoval + 1)
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
        XCTAssertEqual(validationsAfterLogout, validationsBeforeLogout + 2)
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
        XCTAssertEqual(validationsAfterSelection, validationsBeforeSelection + 2)
    }

    private func makeFixture(
        devices: [GoodCloudDeviceSummary] = [defaultDevice],
        clearsSessionOnLogout: Bool = true
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
            transportFactory: { _, _ in throw NetworkError.unsupported("not used") },
            goodCloudAccount: .init(account: account, provisioner: provisioner),
            goodCloudAssociations: associations
        )
        await connections.reloadSavedHosts()
        let model = GoodCloudSettingsModel(
            account: account,
            associations: associations,
            connections: connections,
            hostID: host.id
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
    private let clearsSessionOnLogout: Bool

    init(state: GoodCloudSessionState, clearsSessionOnLogout: Bool) {
        currentState = state
        self.clearsSessionOnLogout = clearsSessionOnLogout
    }

    func validateStoredSession() async -> GoodCloudSessionState {
        validationCount += 1
        return currentState
    }

    func login(email: String, password: String) async -> GoodCloudSessionState {
        loginInputs.append(.init(email: email, password: password))
        return currentState
    }

    func refreshDevices() async -> GoodCloudSessionState { currentState }

    func logout() async {
        logoutCount += 1
        if clearsSessionOnLogout {
            currentState = .loggedOut
        }
    }

    func recordedLoginInputs() -> [LoginInput] { loginInputs }
    func recordedValidationCount() -> Int { validationCount }
    func recordedLogoutCount() -> Int { logoutCount }
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
