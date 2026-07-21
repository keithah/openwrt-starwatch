import Foundation
import XCTest
import WattlineCore
@testable import WattlineNetwork

final class RouterAdvancedControlsTests: XCTestCase {
    func testBypassUsesCanonicalGETPUTAndPublishesObservedResponse() async throws {
        let fixture = try await makeFixture(results: [
            ScriptedRouterHTTPClient.ok(#"{"volts":19.6}"#),
            ScriptedRouterHTTPClient.ok(#"{"volts":19.5}"#),
        ])

        let initial = try await fixture.client.bypassThreshold()
        let observed = try await fixture.client.setBypassThreshold(volts: 19.6)
        XCTAssertEqual(initial.volts, 19.6)
        XCTAssertEqual(observed.volts, 19.5)
        XCTAssertEqual(fixture.http.calls.map { "\($0.method) \($0.path)" }, [
            "GET /api/v1/device/dc/bypass/threshold",
            "PUT /api/v1/device/dc/bypass/threshold",
        ])
        XCTAssertNil(fixture.http.calls[0].body)
        XCTAssertEqual(try bodyObject(fixture.http.calls[1]), ["volts": 19.6])
    }

    func testBypassRejectsNonFiniteAndOutOfRangeValuesWithoutDispatch() async throws {
        let fixture = try await makeFixture(results: [])
        for value in [Double.nan, .infinity, 0, -1, 60.1] {
            await XCTAssertAdvancedThrowsError(try await fixture.client.setBypassThreshold(volts: value)) {
                XCTAssertEqual($0 as? RouterAdministrationError, .invalidResponse)
            }
        }
        XCTAssertTrue(fixture.http.calls.isEmpty)
    }

    func testClockUnavailableAvailableAndBodylessSync() async throws {
        let fixture = try await makeFixture(results: [
            ScriptedRouterHTTPClient.ok(#"{"available":false,"device_time":null,"system_time":"2026-07-17T20:00:02Z","drift_seconds":null}"#),
            ScriptedRouterHTTPClient.ok(#"{"available":true,"device_time":"2026-07-17T20:00:00Z","system_time":"2026-07-17T20:00:02Z","drift_seconds":-2}"#),
            ScriptedRouterHTTPClient.ok(#"{"synced":true,"system_time":"2026-07-17T20:00:02Z"}"#),
        ])

        let unavailable = try await fixture.client.deviceClock()
        XCTAssertFalse(unavailable.available)
        XCTAssertNil(unavailable.deviceTime)
        XCTAssertNil(unavailable.driftSeconds)
        let available = try await fixture.client.deviceClock()
        XCTAssertEqual(available.deviceTime, "2026-07-17T20:00:00Z")
        XCTAssertEqual(available.driftSeconds, -2)
        let synced = try await fixture.client.syncDeviceClock()
        XCTAssertTrue(synced.synced)
        XCTAssertEqual(synced.systemTime, "2026-07-17T20:00:02Z")
        XCTAssertEqual(fixture.http.calls.map { "\($0.method) \($0.path)" }, [
            "GET /api/v1/device/clock",
            "GET /api/v1/device/clock",
            "POST /api/v1/device/clock/sync",
        ])
        XCTAssertNil(fixture.http.calls[2].body)
    }

    func testRunningModeAcceptsOnlyDocumentedZeroAndOneWithoutDispatchingUnsupportedValues() async throws {
        let fixture = try await makeFixture(results: [
            ScriptedRouterHTTPClient.ok(#"{"mode":0}"#),
            ScriptedRouterHTTPClient.ok(#"{"mode":1}"#),
        ])

        let supportedModes = [RunningMode.user.rawValue, RunningMode.factory.rawValue]
        XCTAssertEqual(supportedModes, [0, 1])
        for mode in supportedModes {
            XCTAssertTrue(RouterRunningModeCapability.isSupported(mode))
            let result = try await fixture.client.setRunningMode(mode)
            XCTAssertEqual(result.mode, mode)
        }
        for mode: UInt8 in [2, .max] {
            XCTAssertFalse(RouterRunningModeCapability.isSupported(mode))
            await XCTAssertAdvancedThrowsError(try await fixture.client.setRunningMode(mode)) {
                XCTAssertEqual($0 as? RouterAdministrationError, .invalidResponse)
            }
        }
        XCTAssertEqual(fixture.http.calls.map { "\($0.method) \($0.path)" }, [
            "PUT /api/v1/device/advanced/running-mode",
            "PUT /api/v1/device/advanced/running-mode",
        ])
        XCTAssertEqual(try bodyObject(fixture.http.calls[0]), ["mode": 0])
        XCTAssertEqual(try bodyObject(fixture.http.calls[1]), ["mode": 1])
    }

    func testBarrierPUTPublishesObservedFalseWhenRequestedTrue() async throws {
        let fixture = try await makeFixture(results: [
            ScriptedRouterHTTPClient.ok(#"{"enabled":true}"#),
            ScriptedRouterHTTPClient.ok(#"{"enabled":false}"#),
        ])

        let initial = try await fixture.client.barrierFree()
        let observed = try await fixture.client.setBarrierFree(true)
        XCTAssertTrue(initial.enabled)
        XCTAssertFalse(observed.enabled)
        XCTAssertEqual(fixture.http.calls.map { "\($0.method) \($0.path)" }, [
            "GET /api/v1/device/advanced/barrier-free",
            "PUT /api/v1/device/advanced/barrier-free",
        ])
        XCTAssertEqual(try bodyObject(fixture.http.calls[1]), ["enabled": true])
    }

    func testUSBFirmwareDecodesRawMajorMinorPatch() async throws {
        let fixture = try await makeFixture(results: [
            ScriptedRouterHTTPClient.ok(#"{"raw":"010409","major":1,"minor":4,"patch":9}"#),
        ])

        let version = try await fixture.client.usbFirmwareVersion()
        XCTAssertEqual(version, RouterUSBFirmwareVersion(raw: "010409", major: 1, minor: 4, patch: 9))
        XCTAssertEqual(fixture.http.calls.map(\.path), ["/api/v1/device/advanced/usb-fw-version"])
    }

    func testBLEPINRequiresSixASCIIDigitsAndResultNeverEchoesPIN() async throws {
        let fixture = try await makeFixture(results: [ScriptedRouterHTTPClient.ok(#"{"updated":true}"#)])
        for invalid in ["", "12345", "1234567", "１２３４５６", "12345a"] {
            await XCTAssertAdvancedThrowsError(try await fixture.client.setBLEPIN(invalid)) {
                XCTAssertEqual($0 as? RouterAdministrationError, .invalidResponse)
                XCTAssertFalse(String(describing: $0).contains(invalid))
            }
        }
        XCTAssertTrue(fixture.http.calls.isEmpty)

        let result = try await fixture.client.setBLEPIN("020555")
        XCTAssertTrue(result.updated)
        XCTAssertEqual(fixture.http.calls.map(\.path), ["/api/v1/device/advanced/ble-pin"])
        XCTAssertEqual(try bodyObject(fixture.http.calls[0]), ["pin": "020555"])
        XCTAssertFalse(String(describing: result).contains("020555"))
        XCTAssertFalse(String(reflecting: result).contains("020555"))
        var dumped = ""
        dump(result, to: &dumped)
        XCTAssertFalse(dumped.contains("020555"))
    }

    func testBLEPINRejectsFalseOrPINBearingResponse() async throws {
        let fixture = try await makeFixture(results: [
            ScriptedRouterHTTPClient.ok(#"{"updated":false}"#),
            ScriptedRouterHTTPClient.ok(#"{"updated":true,"pin":"020555"}"#),
        ])
        await XCTAssertAdvancedThrowsError(try await fixture.client.setBLEPIN("123456")) {
            XCTAssertEqual($0 as? RouterAdministrationError, .invalidResponse)
        }
        await XCTAssertAdvancedThrowsError(try await fixture.client.setBLEPIN("123456")) {
            XCTAssertEqual($0 as? RouterAdministrationError, .invalidResponse)
        }
    }

    func testBLEPINIsRedactedFromRouterErrorsDescriptionsAndReflection() async throws {
        let fixture = try await makeFixture(results: [
            .failure(NetworkError.api(
                status: 400,
                code: .invalidRequest,
                message: "Rejected PIN 020555"
            )),
        ])

        await XCTAssertAdvancedThrowsError(try await fixture.client.setBLEPIN("020555")) { error in
            XCTAssertEqual(
                error as? NetworkError,
                .api(status: 400, code: .invalidRequest, message: "Rejected PIN [REDACTED]")
            )
            XCTAssertFalse(String(describing: error).contains("020555"))
            XCTAssertFalse(String(reflecting: error).contains("020555"))
            var dumped = ""
            dump(error, to: &dumped)
            XCTAssertFalse(dumped.contains("020555"))
        }
    }

    func testAdvancedDisabledAndCapabilityUnsupportedPropagatePrecisely() async throws {
        let fixture = try await makeFixture(results: [
            .failure(NetworkError.api(status: 403, code: .advancedDisabled, message: "Advanced operations are disabled")),
            .failure(NetworkError.api(status: 409, code: .capabilityUnsupported, message: "Operation is not supported")),
        ])

        await XCTAssertAdvancedThrowsError(try await fixture.client.barrierFree()) {
            XCTAssertEqual($0 as? NetworkError, .api(status: 403, code: .advancedDisabled, message: "Advanced operations are disabled"))
        }
        await XCTAssertAdvancedThrowsError(try await fixture.client.usbFirmwareVersion()) {
            XCTAssertEqual($0 as? NetworkError, .api(status: 409, code: .capabilityUnsupported, message: "Operation is not supported"))
        }
    }

    func testReplacementCancelsLateCompletionAndAllRequestsUseAdminToken() async throws {
        let oldHTTP = ScriptedRouterHTTPClient(results: [ScriptedRouterHTTPClient.ok(#"{"enabled":true}"#)], gateRequests: true)
        let newHTTP = ScriptedRouterHTTPClient(results: [])
        let old = endpoint(host: "old.local")
        let credentials = RouterCredentialStore(backend: AdministrationCredentialBackend())
        try await credentials.saveToken("admin-secret", for: old, role: .administrator)
        let client = RouterAdministrationClient(credentials: credentials) { endpoint in
            endpoint.host == old.host ? oldHTTP : newHTTP
        }
        try await client.attach(endpoint: old)

        let task = Task { try await client.barrierFree() }
        await oldHTTP.waitForGateRegistration()
        try await client.attach(endpoint: endpoint(host: "new.local"))
        oldHTTP.releaseGates()

        await XCTAssertAdvancedThrowsError(try await task.value) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(oldHTTP.calls.map(\.token), ["admin-secret"])
        XCTAssertTrue(newHTTP.calls.isEmpty)
    }

    func testQueuedOperationFromReplacedAttachmentNeverDispatches() async throws {
        let oldHTTP = ScriptedRouterHTTPClient(
            results: [
                ScriptedRouterHTTPClient.ok(#"{"enabled":true}"#),
                ScriptedRouterHTTPClient.ok(#"{"raw":"010409","major":1,"minor":4,"patch":9}"#),
            ],
            gateRequests: true
        )
        let newHTTP = ScriptedRouterHTTPClient(results: [])
        let old = endpoint(host: "old.local")
        let credentials = RouterCredentialStore(backend: AdministrationCredentialBackend())
        try await credentials.saveToken("admin-secret", for: old, role: .administrator)
        let client = RouterAdministrationClient(credentials: credentials) { endpoint in
            endpoint.host == old.host ? oldHTTP : newHTTP
        }
        try await client.attach(endpoint: old)

        let first = Task { try await client.barrierFree() }
        await oldHTTP.waitForGateRegistration()
        let queued = Task { try await client.usbFirmwareVersion() }
        for _ in 0..<20 { await Task.yield() }
        try await client.attach(endpoint: endpoint(host: "new.local"))
        oldHTTP.releaseGates()

        await XCTAssertAdvancedThrowsError(try await first.value) { XCTAssertTrue($0 is CancellationError) }
        await XCTAssertAdvancedThrowsError(try await queued.value) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(oldHTTP.calls.count, 1)
        XCTAssertTrue(newHTTP.calls.isEmpty)
    }

    func testAdvancedIdentityDecodesCompleteDocumentedDeviceFixture() async throws {
        let fixture = try await makeFixture(results: [ScriptedRouterHTTPClient.ok(deviceJSON)])

        let device = try await fixture.client.advancedIdentity()
        XCTAssertEqual(device.id, "DC:04:5A:EB:72:2B")
        XCTAssertEqual(device.featuresRaw, 32767)
        XCTAssertTrue(device.available.currentTime)
        XCTAssertEqual(device.mode, "app")
        XCTAssertEqual(device.magicDNSName, "wattline.example.ts.net")
        XCTAssertEqual(fixture.http.calls.map(\.path), ["/api/v1/device"])
    }

    private func makeFixture(
        results: [Result<(Data, HTTPURLResponse), Error>]
    ) async throws -> (client: RouterAdministrationClient, http: ScriptedRouterHTTPClient) {
        let http = ScriptedRouterHTTPClient(results: results)
        let endpoint = endpoint(host: "router.local")
        let credentials = RouterCredentialStore(backend: AdministrationCredentialBackend())
        try await credentials.saveToken("admin-token", for: endpoint, role: .administrator)
        let client = RouterAdministrationClient(credentials: credentials) { _ in http }
        try await client.attach(endpoint: endpoint)
        return (client, http)
    }

    private func endpoint(host: String) -> RouterEndpoint {
        RouterEndpoint(
            scheme: "https",
            host: host,
            port: 8378,
            certificateFingerprint: String(repeating: "01", count: 32),
            allowsInsecureWAN: false
        )
    }

    private func bodyObject(_ call: ScriptedRouterHTTPClient.Call) throws -> NSDictionary {
        try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(call.body)) as? NSDictionary
        )
    }
}

private let deviceJSON = #"{"id":"DC:04:5A:EB:72:2B","model":"BP4SL3V2","hardware_revision":"V2","application_firmware":"1.4.9","ota_firmware":"1.0.3","cid":773,"features_raw":32767,"features":{},"available":{"current_time":true,"ota":true,"dc":true,"usbc":true},"mode":"app","connection":{"connected":true,"phase":"ready","reconnect":"armed"},"commands":{"active":[],"recent":[]},"magic_dns_name":"wattline.example.ts.net"}"#

private func XCTAssertAdvancedThrowsError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
