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
            XCTAssertEqual(state, .requiresLogin)
            XCTAssertEqual(logoutCount, 1)
            XCTAssertFalse(String(describing: state).contains("secret"))
        }
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
    private(set) var loginArguments: LoginArguments?
    private(set) var devicesCount = 0
    private(set) var logoutCount = 0

    init(
        tokenPresent: Bool,
        devices: [GoodCloudDeviceSummary] = [],
        error: (any Error)? = nil
    ) {
        self.tokenPresent = tokenPresent
        self.returnedDevices = devices
        self.error = error
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

    func logout() { logoutCount += 1 }
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
