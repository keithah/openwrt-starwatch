import Foundation
import GoodCloudKit
import XCTest
@testable import WattlineNetwork

final class GoodCloudAccountServiceTests: XCTestCase {
    func test_validateStoredSessionWithoutTokenStaysLoggedOut() async {
        let client = FakeGoodCloudAccountClient(tokenPresent: false)
        let service = GoodCloudAccountService(client: client)

        let state = await service.validateStoredSession()
        let devicesCount = await client.devicesCount

        XCTAssertEqual(state, .loggedOut)
        XCTAssertEqual(devicesCount, 0)
    }

    func test_validateStoredSessionLoadsDevices() async {
        let client = FakeGoodCloudAccountClient(tokenPresent: true, devices: [.fixture])
        let service = GoodCloudAccountService(client: client)

        let state = await service.validateStoredSession()

        XCTAssertEqual(state, .authenticated([.fixture]))
    }

    func test_loginAuthenticatesThenLoadsDevices() async {
        let client = FakeGoodCloudAccountClient(tokenPresent: false, devices: [.fixture])
        let service = GoodCloudAccountService(client: client)

        let state = await service.login(email: "owner@example.com", password: "private")
        let loginArguments = await client.loginArguments

        XCTAssertEqual(state, .authenticated([.fixture]))
        XCTAssertEqual(loginArguments, .init(email: "owner@example.com", password: "private"))
    }

    func test_refreshDevicesReturnsFixedRedactedFailure() async {
        let client = FakeGoodCloudAccountClient(
            tokenPresent: true,
            error: GoodCloudError.api(code: 500, message: "token=secret server text")
        )
        let service = GoodCloudAccountService(client: client)

        let state = await service.refreshDevices()

        XCTAssertEqual(state, .failed("GoodCloud request failed."))
        XCTAssertFalse(String(describing: state).contains("secret"))
    }

    func test_minus1010ClearsSessionAndRequiresLoginWithoutServerMessage() async {
        let client = FakeGoodCloudAccountClient(
            tokenPresent: true,
            error: GoodCloudError.api(code: -1010, message: "token=secret server text")
        )
        let service = GoodCloudAccountService(client: client)

        let result = await service.refreshDevices()
        let state = await service.state
        let logoutCount = await client.logoutCount

        XCTAssertEqual(result, .requiresLogin)
        XCTAssertEqual(logoutCount, 1)
        XCTAssertFalse(String(describing: state).contains("secret"))
    }

    func test_minus1010LogoutFailureDoesNotClaimSessionWasCleared() async {
        let client = FakeGoodCloudAccountClient(
            tokenPresent: true,
            error: GoodCloudError.api(code: -1010, message: "token=secret server text"),
            logoutError: GoodCloudError.api(code: 500, message: "delete token=still-secret")
        )
        let service = GoodCloudAccountService(client: client)

        let result = await service.refreshDevices()
        let state = await service.state
        let logoutCount = await client.logoutCount

        XCTAssertEqual(result, .failed("GoodCloud request failed."))
        XCTAssertEqual(state, .failed("GoodCloud request failed."))
        XCTAssertEqual(logoutCount, 1)
        XCTAssertFalse(String(describing: state).contains("secret"))
    }

    func test_logoutClearsDevicesAndStoredSession() async {
        let client = FakeGoodCloudAccountClient(tokenPresent: true, devices: [.fixture])
        let service = GoodCloudAccountService(client: client)
        _ = await service.refreshDevices()

        await service.logout()
        let state = await service.state
        let logoutCount = await client.logoutCount

        XCTAssertEqual(state, .loggedOut)
        XCTAssertEqual(logoutCount, 1)
    }

    func test_logoutFailurePublishesFixedRedactedFailureInsteadOfLoggedOut() async {
        let client = FakeGoodCloudAccountClient(
            tokenPresent: true,
            logoutError: GoodCloudError.api(code: 500, message: "token=secret server text")
        )
        let service = GoodCloudAccountService(client: client)

        await service.logout()
        let state = await service.state
        let logoutCount = await client.logoutCount

        XCTAssertEqual(state, .failed("GoodCloud request failed."))
        XCTAssertEqual(logoutCount, 1)
        XCTAssertFalse(String(describing: state).contains("secret"))
    }

    func test_remoteAccessUsesInjectedProvisioner() async throws {
        let client = FakeGoodCloudAccountClient(tokenPresent: true)
        let recorder = RemoteAccessRecorder()
        let expected = RemoteAccessSession(
            baseURL: URL(string: "https://relay.goodcloud.xyz/device/")!,
            tokenDomain: ".goodcloud.xyz",
            sessionID: "session-id",
            issuedAtMillis: 42
        )
        let service = GoodCloudAccountService(client: client) { deviceID, port in
            await recorder.record(deviceID: deviceID, port: port)
            return expected
        }

        let session = try await service.remoteAccess(deviceID: "device-42", port: 8377)
        let call = await recorder.call

        XCTAssertEqual(session.baseURL, expected.baseURL)
        XCTAssertEqual(call, .init(deviceID: "device-42", port: 8377))
    }

    func test_remoteAccessMinus1010ClearsSessionBeforeRethrowing() async {
        let client = FakeGoodCloudAccountClient(tokenPresent: true)
        let service = GoodCloudAccountService(client: client) { _, _ in
            throw GoodCloudError.api(code: -1010, message: "token=secret server text")
        }

        do {
            _ = try await service.remoteAccess(deviceID: "device-42", port: 8377)
            XCTFail("Expected remote access to fail")
        } catch {
            let state = await service.state
            let logoutCount = await client.logoutCount
            let description = String(describing: error)
            XCTAssertEqual(error as? GoodCloudError, .sessionExpired)
            XCTAssertEqual(state, .requiresLogin)
            XCTAssertEqual(logoutCount, 1)
            XCTAssertFalse(description.contains("secret"))
            XCTAssertFalse(description.lowercased().contains("token="))
        }
    }

    func test_remoteAccessOtherAPIErrorMapsToFixedSafeError() async {
        let client = FakeGoodCloudAccountClient(tokenPresent: true)
        let service = GoodCloudAccountService(client: client) { _, _ in
            throw GoodCloudError.api(code: 500, message: "token=secret server text")
        }

        do {
            _ = try await service.remoteAccess(deviceID: "device-42", port: 8377)
            XCTFail("Expected remote access to fail")
        } catch {
            let description = String(describing: error)
            XCTAssertEqual(error as? GoodCloudError, .relayUnavailable)
            XCTAssertFalse(description.contains("secret"))
            XCTAssertFalse(description.lowercased().contains("token="))
        }
    }

    func test_logoutWinsOverOlderSuspendedRefresh() async {
        let client = SuspendedGoodCloudAccountClient()
        let service = GoodCloudAccountService(client: client)
        let olderRefresh = Task { await service.refreshDevices() }
        await client.waitUntilFirstDevicesSuspends()

        let logout = Task { await service.logout() }
        await client.resumeFirstDevices(returning: [.fixture])
        let olderResult = await olderRefresh.value
        _ = await logout.value
        let state = await service.state

        XCTAssertEqual(olderResult, .authenticated([.fixture]))
        XCTAssertEqual(state, .loggedOut)
    }

    func test_newerSessionExpiryWinsOverOlderSuccessfulRefresh() async {
        let client = SuspendedGoodCloudAccountClient(
            subsequentDevicesError: .api(code: -1010, message: "token=secret server text")
        )
        let service = GoodCloudAccountService(client: client)
        let olderRefresh = Task { await service.refreshDevices() }
        await client.waitUntilFirstDevicesSuspends()

        let newerRefresh = Task { await service.refreshDevices() }
        await client.resumeFirstDevices(returning: [.fixture])
        let olderResult = await olderRefresh.value
        let newerResult = await newerRefresh.value
        let state = await service.state

        XCTAssertEqual(newerResult, .requiresLogin)
        XCTAssertEqual(olderResult, .authenticated([.fixture]))
        XCTAssertEqual(state, .requiresLogin)
    }

    func test_logoutDuringSuspendedLoginRunsAfterLoginAndLeavesNoStoredToken() async {
        let logoutQueued = expectation(description: "logout queued behind suspended login")
        let queuedSignal = ExpectationSignal(logoutQueued)
        let client = SuspendedLoginCredentialClient()
        let service = GoodCloudAccountService(
            client: client,
            onOperationQueued: { queuedSignal.fulfill() }
        )
        let login = Task {
            await service.login(email: "owner@example.com", password: "private")
        }
        await client.waitUntilLoginSuspends()

        let logout = Task { await service.logout() }
        await fulfillment(of: [logoutQueued], timeout: 1.0)
        await client.resumeLogin()
        _ = await login.value
        _ = await logout.value
        let state = await service.state
        let hasStoredToken = await client.hasStoredToken()

        XCTAssertEqual(state, .loggedOut)
        XCTAssertFalse(hasStoredToken)
    }

    func test_newerRefreshRunsAfterSuspendedExpiryCleanupAndObservesDeletedToken() async {
        let newerRefreshQueued = expectation(
            description: "newer refresh queued behind expiry cleanup"
        )
        let queuedSignal = ExpectationSignal(newerRefreshQueued)
        let client = SuspendedExpiryCleanupCredentialClient()
        let service = GoodCloudAccountService(
            client: client,
            onOperationQueued: { queuedSignal.fulfill() }
        )
        let expiredRefresh = Task { await service.refreshDevices() }
        await client.waitUntilLogoutSuspends()

        let newerRefresh = Task { await service.refreshDevices() }
        await fulfillment(of: [newerRefreshQueued], timeout: 1.0)
        await client.resumeLogout()
        _ = await expiredRefresh.value
        let newerResult = await newerRefresh.value
        let state = await service.state
        let hasStoredToken = await client.hasStoredToken()

        XCTAssertEqual(newerResult, .failed("GoodCloud request failed."))
        XCTAssertEqual(state, .failed("GoodCloud request failed."))
        XCTAssertFalse(hasStoredToken)
    }

    func test_cancelledQueuedLoginNeverEntersClientAndFollowingLogoutProgresses() async {
        let cancelledLoginQueued = expectation(description: "cancelled login queued")
        let liveLogoutQueued = expectation(description: "live logout queued")
        let queuedSignals = ExpectationSequence([cancelledLoginQueued, liveLogoutQueued])
        let client = QueueCancellationCredentialClient()
        let service = GoodCloudAccountService(
            client: client,
            onOperationQueued: { queuedSignals.fulfillNext() }
        )
        let holder = Task { await service.refreshDevices() }
        await client.waitUntilDevicesSuspends()

        let cancelledLogin = Task {
            await service.login(email: "cancelled@example.com", password: "private")
        }
        await fulfillment(of: [cancelledLoginQueued], timeout: 1.0)
        cancelledLogin.cancel()

        let liveLogout = Task { await service.logout() }
        await fulfillment(of: [liveLogoutQueued], timeout: 1.0)
        await client.resumeDevices(returning: [.fixture])
        _ = await holder.value
        _ = await cancelledLogin.value
        _ = await liveLogout.value
        let state = await service.state
        let snapshot = await client.snapshot

        XCTAssertEqual(snapshot.loginCount, 0)
        XCTAssertEqual(snapshot.logoutCount, 1)
        XCTAssertFalse(snapshot.hasStoredToken)
        XCTAssertEqual(state, .loggedOut)
    }
}

private actor FakeGoodCloudAccountClient: GoodCloudAccountClient {
    struct LoginArguments: Equatable, Sendable {
        let email: String
        let password: String
    }

    let tokenPresent: Bool
    let returnedDevices: [GoodCloudDeviceSummary]
    let error: (any Error)?
    let logoutError: (any Error)?
    private(set) var loginArguments: LoginArguments?
    private(set) var devicesCount = 0
    private(set) var logoutCount = 0

    init(
        tokenPresent: Bool,
        devices: [GoodCloudDeviceSummary] = [],
        error: (any Error)? = nil,
        logoutError: (any Error)? = nil
    ) {
        self.tokenPresent = tokenPresent
        self.returnedDevices = devices
        self.error = error
        self.logoutError = logoutError
    }

    func hasStoredToken() -> Bool { tokenPresent }

    func login(email: String, password: String) throws {
        if let error { throw error }
        loginArguments = .init(email: email, password: password)
    }

    func devices() throws -> [GoodCloudDeviceSummary] {
        devicesCount += 1
        if let error { throw error }
        return returnedDevices
    }

    func logout() throws {
        logoutCount += 1
        if let logoutError { throw logoutError }
    }
}

private actor RemoteAccessRecorder {
    struct Call: Equatable, Sendable {
        let deviceID: String
        let port: Int
    }

    private(set) var call: Call?

    func record(deviceID: String, port: Int) {
        call = .init(deviceID: deviceID, port: port)
    }
}

private actor SuspendedGoodCloudAccountClient: GoodCloudAccountClient {
    private let subsequentDevicesError: GoodCloudError?
    private var devicesInvocationCount = 0
    private var firstDevicesContinuation: CheckedContinuation<[GoodCloudDeviceSummary], any Error>?
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []

    init(subsequentDevicesError: GoodCloudError? = nil) {
        self.subsequentDevicesError = subsequentDevicesError
    }

    func hasStoredToken() -> Bool { true }

    func login(email: String, password: String) {}

    func devices() async throws -> [GoodCloudDeviceSummary] {
        devicesInvocationCount += 1
        if devicesInvocationCount == 1 {
            return try await withCheckedThrowingContinuation { continuation in
                firstDevicesContinuation = continuation
                let waiters = suspensionWaiters
                suspensionWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        if let subsequentDevicesError { throw subsequentDevicesError }
        return []
    }

    func logout() throws {}

    func waitUntilFirstDevicesSuspends() async {
        guard firstDevicesContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func resumeFirstDevices(returning devices: [GoodCloudDeviceSummary]) {
        let continuation = firstDevicesContinuation
        firstDevicesContinuation = nil
        continuation?.resume(returning: devices)
    }
}

private final class ExpectationSignal: @unchecked Sendable {
    private let expectation: XCTestExpectation

    init(_ expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func fulfill() {
        expectation.fulfill()
    }
}

private final class ExpectationSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var expectations: [XCTestExpectation]

    init(_ expectations: [XCTestExpectation]) {
        self.expectations = expectations
    }

    func fulfillNext() {
        let expectation = lock.withLock {
            expectations.isEmpty ? nil : expectations.removeFirst()
        }
        expectation?.fulfill()
    }
}

private actor SuspendedLoginCredentialClient: GoodCloudAccountClient {
    private var storedToken = false
    private var loginContinuation: CheckedContinuation<Void, Never>?
    private var loginWaiters: [CheckedContinuation<Void, Never>] = []

    func hasStoredToken() -> Bool { storedToken }

    func login(email: String, password: String) async {
        await withCheckedContinuation { continuation in
            loginContinuation = continuation
            let waiters = loginWaiters
            loginWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        storedToken = true
    }

    func devices() -> [GoodCloudDeviceSummary] { [.fixture] }

    func logout() {
        storedToken = false
    }

    func waitUntilLoginSuspends() async {
        guard loginContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            loginWaiters.append(continuation)
        }
    }

    func resumeLogin() {
        let continuation = loginContinuation
        loginContinuation = nil
        continuation?.resume()
    }
}

private actor SuspendedExpiryCleanupCredentialClient: GoodCloudAccountClient {
    private var storedToken = true
    private var devicesInvocationCount = 0
    private var logoutContinuation: CheckedContinuation<Void, Never>?
    private var logoutWaiters: [CheckedContinuation<Void, Never>] = []

    func hasStoredToken() -> Bool { storedToken }

    func login(email: String, password: String) {}

    func devices() throws -> [GoodCloudDeviceSummary] {
        devicesInvocationCount += 1
        if devicesInvocationCount == 1 {
            throw GoodCloudError.api(code: -1010, message: "token=secret server text")
        }
        guard storedToken else { throw GoodCloudError.authFailed }
        return [.fixture]
    }

    func logout() async {
        await withCheckedContinuation { continuation in
            logoutContinuation = continuation
            let waiters = logoutWaiters
            logoutWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        storedToken = false
    }

    func waitUntilLogoutSuspends() async {
        guard logoutContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            logoutWaiters.append(continuation)
        }
    }

    func resumeLogout() {
        let continuation = logoutContinuation
        logoutContinuation = nil
        continuation?.resume()
    }
}

private actor QueueCancellationCredentialClient: GoodCloudAccountClient {
    struct Snapshot: Equatable, Sendable {
        let loginCount: Int
        let logoutCount: Int
        let hasStoredToken: Bool
    }

    private var storedToken = true
    private var loginCount = 0
    private var logoutCount = 0
    private var devicesCount = 0
    private var devicesContinuation: CheckedContinuation<[GoodCloudDeviceSummary], Never>?
    private var devicesWaiters: [CheckedContinuation<Void, Never>] = []

    var snapshot: Snapshot {
        .init(
            loginCount: loginCount,
            logoutCount: logoutCount,
            hasStoredToken: storedToken
        )
    }

    func hasStoredToken() -> Bool { storedToken }

    func login(email: String, password: String) {
        loginCount += 1
        storedToken = true
    }

    func devices() async -> [GoodCloudDeviceSummary] {
        devicesCount += 1
        guard devicesCount == 1 else { return [.fixture] }
        return await withCheckedContinuation { continuation in
            devicesContinuation = continuation
            let waiters = devicesWaiters
            devicesWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func logout() {
        logoutCount += 1
        storedToken = false
    }

    func waitUntilDevicesSuspends() async {
        guard devicesContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            devicesWaiters.append(continuation)
        }
    }

    func resumeDevices(returning devices: [GoodCloudDeviceSummary]) {
        let continuation = devicesContinuation
        devicesContinuation = nil
        continuation?.resume(returning: devices)
    }
}

private extension GoodCloudDeviceSummary {
    static let fixture = GoodCloudDeviceSummary(
        id: "42",
        name: "X3000",
        mac: "AA-BB-CC-DD-EE-FF",
        ddns: "x3000",
        model: "GL-X3000",
        isOnline: true
    )
}
