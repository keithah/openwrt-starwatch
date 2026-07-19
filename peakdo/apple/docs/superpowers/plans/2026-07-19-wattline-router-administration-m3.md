# Wattline Router Administration Milestone 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add contract-exact typed router settings, a safe readback-driven settings editor, and authenticated staged TLS-pin rotation/promotion without compromising Wattline's package, secret, or single-transport boundaries.

**Architecture:** `WattlineNetwork` owns settings/TLS wire DTOs, privileged actor methods, host metadata, and the staged-pin promotion state machine. `WattlineUI` owns only Foundation-based form values, sparse draft comparison, validation, and confirmation presentation; the iOS app maps those values to Network DTOs and publishes only accepted, generation-current router readbacks. The ordinary endpoint keeps using the active pin until a staged-pin-only `/device` trial verifies the correlated device ID and atomically promotes metadata.

**Tech Stack:** Swift 6, Swift Package Manager, Foundation/Codable, URLSession and Security confined to `WattlineNetwork`, Observation/SwiftUI in the iOS app, XCTest, Xcode 26.

## Global Constraints

- The canonical router contract is `/Users/keith/src/openwrt-wattline/docs/api.md`; never edit that repository.
- Do not edit `peakdo/Wattline-SPEC.md`, `peakdo/API.md`, `peakdo/src/*`, `scan.py`, or `verify*.py`.
- Scope is master-plan Tasks 12–15 only. Do not add router BLE pairing, advanced device controls, rules, macOS, Demo, OTA, firmware transfer, device Timers, cloud services, analytics, or deprecated compatibility routes.
- Bluetooth remains primary. Each app process owns exactly one active `DeviceTransport`; the administration client constructs no BLE transport, `DeviceSession`, or `DeviceOperationBroker`.
- `WattlineCore` remains unchanged and free of networking, Security, SwiftUI, UIKit, AppKit, ActivityKit, WidgetKit, AppIntents, UserNotifications, and ServiceManagement.
- `WattlineUI` remains Foundation/SwiftUI-only, imports neither networking nor Security, and gains no `WattlineNetwork` dependency in source or `Package.swift`.
- Networking and Keychain APIs remain confined to `WattlineNetwork`; app code is thin mapping, lifecycle, and SwiftUI composition.
- No token, pairing PIN, BLE PIN, private-key bytes, or private-key file contents enter UserDefaults, logs, errors, descriptions, snapshots, or diagnostics. The settings `ble_pin` string may exist only in the authoritative settings model and secure editor state and is never interpolated into an error or description.
- Certificate fingerprints are SHA-256 of leaf DER bytes. Wire rotation output is exactly 64 lowercase hexadecimal characters. Existing host metadata continues storing normalized fingerprints in its current uppercase representation.
- The staged pin is separate from the active pin. Before restart, normal sessions accept only the active pin. Promotion uses HTTPS with only the staged pin, verifies the correlated device ID via `GET /api/v1/device`, then atomically replaces active with staged and clears staged. No TOFU, automatic certificate acceptance, public-CA bypass, or HTTP downgrade is permitted.
- Existing client Keychain account strings remain unchanged. `RouterTransport`'s six-argument initializer and `RouterCredentialProvider.credential(for:)` remain unchanged.
- Every production behavior begins with a non-vacuous failing test, the RED output is captured, implementation is minimal, focused and affected suites turn GREEN, and each task uses the exact requested commit message.
- Simulator commands use `WATTLINE_SIMULATOR_NAME=${WATTLINE_SIMULATOR_NAME:-Wattline-Tests-2}`.

## File and ownership map

- Create `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterSettings.swift`: complete settings DTOs, sparse writable patch DTOs, update response, and `RouterAdministrationClient` settings methods.
- Create `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterSettingsTests.swift`: normative settings fixtures, exact wire bodies, status handling, and attachment-generation tests.
- Create `peakdo/apple/WattlineUI/Sources/WattlineUI/RouterSettingsPresentation.swift`: Network-independent form values, sparse comparison, validation, replacement-candidate policy, confirmations, and restart/token-store copy.
- Create `peakdo/apple/WattlineUI/Tests/WattlineUITests/RouterSettingsPresentationTests.swift`: pure editor policy tests.
- Modify `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterAdministrationModel.swift`: generation-scoped settings load/save/rotation publication.
- Create `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterSettingsView.swift`: secure form, structural save gating, purpose-specific confirmations, readback rendering, and TLS confirmation.
- Modify `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterAdministrationView.swift`: structurally insert Router Configuration only for an unlocked administrator.
- Modify `peakdo/apple/Wattline/WattlineTests/RouterAdministrationModelTests.swift`: model readback, stale-generation, and pin-lifecycle integration tests.
- Create `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterTLSRotation.swift`: exact rotate wire contract and staged-only identity-verifying promoter.
- Modify `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterHostStore.swift`: additive staged fingerprint plus atomic stage/promote operations.
- Reuse `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterTLSPinning.swift`: ordinary session construction remains active-pin-only; no dual-pin delegate is added.
- Create `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterTLSRotationTests.swift`: strict response, persistence compatibility, active/staged trust, identity, atomicity, and downgrade tests.

## Grounded interfaces at approved base `75016b27`

```swift
public actor RouterAdministrationClient {
    public typealias HTTPFactory = @Sendable (RouterEndpoint) throws -> any RouterHTTPClient
    public func attach(endpoint: RouterEndpoint) throws
    public func detach()
    public func attachmentLease() throws -> RouterAdministrationAttachmentLease
    func validate(attachment: RouterAdministrationAttachmentLease) throws
    func send(_ method: String, _ path: String, body: Data? = nil)
        async throws -> (Data, HTTPURLResponse)
    func sendDurableMutation(
        _ method: String, _ path: String, body: Data? = nil,
        attachment: RouterAdministrationAttachmentLease
    ) async throws -> (Data, HTTPURLResponse)
    func acquirePrivilegedMutation() async
    func releasePrivilegedMutation()
}

public actor RouterCredentialStore {
    public func readToken(for endpoint: RouterEndpoint, role: RouterCredentialRole = .client)
        async throws -> String?
    public func credential(for endpoint: RouterEndpoint) async throws -> RouterCredential
}

public actor RouterHostStore {
    public func hosts() -> [RouterHostMetadata]
    public func save(_ host: RouterHostMetadata) throws
}

@MainActor @Observable final class RouterAdministrationModel {
    private var sessionGeneration: UInt64
    private var adminOperationGeneration: UInt64
    private func performAdmin<Value>(
        _ operation: (RouterAdministrationClient) async throws -> Value,
        isCurrent: () -> Bool = { true }
    ) async -> AdminResult<Value>
}
```

The app model lives in the file-synchronized `Wattline/Wattline/RouterAdministration/` group; no `WattlineShared` source directory exists at this base. New source files placed in the synchronized groups are picked up without manually editing `project.pbxproj`.

---

### Task 12: Complete settings DTO and sparse merge patch

**Files:**
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterSettings.swift`
- Create: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterSettingsTests.swift`
- Reuse: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/ScriptedRouterHTTPClient.swift`

**Interfaces:**
- Consumes: the grounded `RouterAdministrationClient.send`, attachment lease, and privileged-mutation FIFO.
- Produces: `RouterListenerSettings`, `RouterTLSSettings`, `RouterMDNSSettings`, `RouterSettings`, their writable patch counterparts, `RouterSettingsUpdateResult`, `RouterAdministrationClient.settings()`, and `updateSettings(_:)`.
- Task 13 consumes every produced value but maps it into UI-local types; `WattlineUI` never imports these DTOs.

Normative GET fixture copied exactly from `docs/api.md`:

```swift
private let completeSettingsJSON = #"{"http":{"enabled":true,"addr4":"0.0.0.0","addr6":"::","port":8377},"https":{"enabled":true,"addr4":"0.0.0.0","addr6":"::","port":8378},"tls":{"cert":"/etc/wattline/tls/server.crt","key":"/etc/wattline/tls/server.key","sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"},"token_store":"/etc/wattline/tokens.json","pairing_ttl":"5m0s","pairing_always_on":false,"advanced":false,"mdns":{"enabled":true,"interfaces":["br-lan"]},"wan_access":false,"ble_pin":"020555"}"#
```

- [ ] **Step 1: Write the complete DTO and sparse-patch tests first**

Create `RouterSettingsTests.swift` with these non-vacuous tests and local helpers:

```swift
import XCTest
@testable import WattlineNetwork

final class RouterSettingsTests: XCTestCase {
    func testGETDecodesEveryDocumentedSettingsFieldAndIgnoresAdditiveReplyField() async throws {
        let json = completeSettingsJSON.dropLast() + #",\"future_reply\":{\"kept_by_router\":true}}"#
        let (client, http) = try await attachedClient(results: [.ok(String(json))])

        let value = try await client.settings()

        XCTAssertEqual(value.http, .init(enabled: true, addr4: "0.0.0.0", addr6: "::", port: 8377))
        XCTAssertEqual(value.https, .init(enabled: true, addr4: "0.0.0.0", addr6: "::", port: 8378))
        XCTAssertEqual(value.tls.cert, "/etc/wattline/tls/server.crt")
        XCTAssertEqual(value.tls.key, "/etc/wattline/tls/server.key")
        XCTAssertEqual(value.tls.sha256, String(repeating: "0123456789abcdef", count: 4))
        XCTAssertEqual(value.tokenStore, "/etc/wattline/tokens.json")
        XCTAssertEqual(value.pairingTTL, "5m0s")
        XCTAssertFalse(value.pairingAlwaysOn)
        XCTAssertFalse(value.advanced)
        XCTAssertEqual(value.mdns, .init(enabled: true, interfaces: ["br-lan"]))
        XCTAssertFalse(value.wanAccess)
        XCTAssertEqual(value.blePIN, "020555")
        XCTAssertEqual(http.calls.map(\.method), ["GET"])
        XCTAssertEqual(http.calls.map(\.path), ["/api/v1/settings"])
        XCTAssertNil(http.calls[0].body)
    }

    func testPatchOmitsUnchangedTopLevelAndNestedMembers() throws {
        let patch = RouterSettingsPatch(
            http: .init(port: 9000),
            advanced: true,
            wanAccess: false
        )
        XCTAssertEqual(try object(patch) as NSDictionary, [
            "http": ["port": 9000],
            "advanced": true,
            "wan_access": false,
        ])
        let encoded = try JSONEncoder().encode(patch)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("sha256"))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("https"))
    }

    func testExplicitEmptyMDNSInterfacesDiffersFromOmittedInterfaces() throws {
        let omitted = try object(RouterSettingsPatch(mdns: .init(enabled: false)))
        let cleared = try object(RouterSettingsPatch(mdns: .init(interfaces: [])))
        XCTAssertEqual(omitted as NSDictionary, ["mdns": ["enabled": false]])
        XCTAssertEqual(cleared as NSDictionary, ["mdns": ["interfaces": []]])
    }

    func testPatchTypeCannotEncodeReadonlyFingerprintOrUnknownFields() throws {
        let patch = RouterSettingsPatch(tls: .init(cert: "/new.crt", key: "/new.key"))
        let keys = Set(try object(patch).keys)
        XCTAssertEqual(keys, ["tls"])
        let tls = try XCTUnwrap(try object(patch)["tls"] as? [String: Any])
        XCTAssertEqual(Set(tls.keys), ["cert", "key"])
        XCTAssertNil(tls["sha256"])
    }

    func testPUTSendsExactSparseBodyAndDecodesCompleteMergedReadback() async throws {
        let response = completeSettingsJSON.dropLast() + #",\"restart_required\":true}"#
        let (client, http) = try await attachedClient(results: [.ok(String(response))])

        let result = try await client.updateSettings(.init(
            mdns: .init(interfaces: []), advanced: true
        ))

        XCTAssertTrue(result.restartRequired)
        XCTAssertEqual(result.settings.http.port, 8377)
        XCTAssertEqual(result.settings.blePIN, "020555")
        XCTAssertEqual(http.calls.count, 1)
        XCTAssertEqual(http.calls[0].method, "PUT")
        XCTAssertEqual(http.calls[0].path, "/api/v1/settings")
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: XCTUnwrap(http.calls[0].body)) as? NSDictionary,
            ["advanced": true, "mdns": ["interfaces": []]]
        )
    }

    func testMalformedOrPartialPUTReadbackIsRejected() async throws {
        let (client, _) = try await attachedClient(results: [.ok(#"{"advanced":true,"restart_required":false}"#)])
        await XCTAssertThrowsErrorAsync(try await client.updateSettings(.init(advanced: true))) {
            XCTAssertEqual($0 as? RouterAdministrationError, .invalidResponse)
        }
    }

    func testPUTCompletionFromReplacedAttachmentPublishesNothing() async throws {
        let oldHTTP = ScriptedRouterHTTPClient(results: [.ok(completeSettingsJSON.dropLast() + #",\"restart_required\":false}"#)], gateRequests: true)
        let newHTTP = ScriptedRouterHTTPClient(results: [])
        let endpoint = endpoint(host: "router.local")
        let backend = AdministrationCredentialBackend()
        let credentials = RouterCredentialStore(backend: backend)
        try await credentials.saveToken("admin-token", for: endpoint, role: .administrator)
        let client = RouterAdministrationClient(credentials: credentials) { value in
            value.host == "router.local" ? oldHTTP : newHTTP
        }
        try await client.attach(endpoint: endpoint)
        let task = Task { try await client.updateSettings(.init(advanced: true)) }
        await oldHTTP.waitForGateRegistration()
        try await client.attach(endpoint: endpoint(host: "replacement.local"))
        oldHTTP.releaseGates()
        await XCTAssertThrowsErrorAsync(try await task.value) { XCTAssertTrue($0 is CancellationError) }
    }

    private func attachedClient(
        results: [Result<(Data, HTTPURLResponse), Error>]
    ) async throws -> (RouterAdministrationClient, ScriptedRouterHTTPClient) {
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
            scheme: "https", host: host, port: 8378,
            certificateFingerprint: String(repeating: "01", count: 32),
            allowsInsecureWAN: false
        )
    }

    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
}
```

Use the existing `AdministrationCredentialBackend` and async-throws assertion helper from the administration test support; if Swift file-private visibility prevents reuse, move those unchanged helpers into a test-support file rather than weakening assertions or adding a production test seam.

- [ ] **Step 2: Run Task 12 RED and capture the expected missing-type failure**

Run:

```bash
swift test --package-path peakdo/apple/WattlineNetwork --filter RouterSettingsTests 2>&1 | tee /tmp/wattline-m3-task12-red.log
```

Expected RED: compilation fails with `cannot find 'RouterSettingsPatch' in scope` and missing `RouterAdministrationClient.settings/updateSettings` members. A syntax-only fixture error is not an acceptable RED.

- [ ] **Step 3: Implement the complete DTOs and explicit writable patches**

Create `RouterSettings.swift`:

```swift
import Foundation

public struct RouterListenerSettings: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let addr4: String
    public let addr6: String
    public let port: Int
    public init(enabled: Bool, addr4: String, addr6: String, port: Int) {
        self.enabled = enabled; self.addr4 = addr4; self.addr6 = addr6; self.port = port
    }
}

public struct RouterTLSSettings: Codable, Equatable, Sendable {
    public let cert: String
    public let key: String
    public let sha256: String
    public init(cert: String, key: String, sha256: String) {
        self.cert = cert; self.key = key; self.sha256 = sha256
    }
}

public struct RouterMDNSSettings: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let interfaces: [String]
    public init(enabled: Bool, interfaces: [String]) {
        self.enabled = enabled; self.interfaces = interfaces
    }
}

public struct RouterSettings: Codable, Equatable, Sendable {
    public let http: RouterListenerSettings
    public let https: RouterListenerSettings
    public let tls: RouterTLSSettings
    public let tokenStore: String
    public let pairingTTL: String
    public let pairingAlwaysOn: Bool
    public let advanced: Bool
    public let mdns: RouterMDNSSettings
    public let wanAccess: Bool
    public let blePIN: String
    enum CodingKeys: String, CodingKey {
        case http, https, tls, advanced, mdns
        case tokenStore = "token_store"
        case pairingTTL = "pairing_ttl"
        case pairingAlwaysOn = "pairing_always_on"
        case wanAccess = "wan_access"
        case blePIN = "ble_pin"
    }
}

public struct RouterListenerSettingsPatch: Encodable, Equatable, Sendable {
    public let enabled: Bool?
    public let addr4: String?
    public let addr6: String?
    public let port: Int?
    public init(enabled: Bool? = nil, addr4: String? = nil, addr6: String? = nil, port: Int? = nil) {
        self.enabled = enabled; self.addr4 = addr4; self.addr6 = addr6; self.port = port
    }
}

public struct RouterTLSSettingsPatch: Encodable, Equatable, Sendable {
    public let cert: String?
    public let key: String?
    public init(cert: String? = nil, key: String? = nil) { self.cert = cert; self.key = key }
}

public struct RouterMDNSSettingsPatch: Encodable, Equatable, Sendable {
    public let enabled: Bool?
    public let interfaces: [String]?
    public init(enabled: Bool? = nil, interfaces: [String]? = nil) {
        self.enabled = enabled; self.interfaces = interfaces
    }
}

public struct RouterSettingsPatch: Encodable, Equatable, Sendable {
    public let http: RouterListenerSettingsPatch?
    public let https: RouterListenerSettingsPatch?
    public let tls: RouterTLSSettingsPatch?
    public let tokenStore: String?
    public let pairingTTL: String?
    public let pairingAlwaysOn: Bool?
    public let advanced: Bool?
    public let mdns: RouterMDNSSettingsPatch?
    public let wanAccess: Bool?
    public let blePIN: String?
    public init(
        http: RouterListenerSettingsPatch? = nil,
        https: RouterListenerSettingsPatch? = nil,
        tls: RouterTLSSettingsPatch? = nil,
        tokenStore: String? = nil,
        pairingTTL: String? = nil,
        pairingAlwaysOn: Bool? = nil,
        advanced: Bool? = nil,
        mdns: RouterMDNSSettingsPatch? = nil,
        wanAccess: Bool? = nil,
        blePIN: String? = nil
    ) {
        self.http = http
        self.https = https
        self.tls = tls
        self.tokenStore = tokenStore
        self.pairingTTL = pairingTTL
        self.pairingAlwaysOn = pairingAlwaysOn
        self.advanced = advanced
        self.mdns = mdns
        self.wanAccess = wanAccess
        self.blePIN = blePIN
    }
    enum CodingKeys: String, CodingKey {
        case http, https, tls, advanced, mdns
        case tokenStore = "token_store"; case pairingTTL = "pairing_ttl"
        case pairingAlwaysOn = "pairing_always_on"; case wanAccess = "wan_access"
        case blePIN = "ble_pin"
    }
}

public struct RouterSettingsUpdateResult: Equatable, Sendable, Decodable {
    public let settings: RouterSettings
    public let restartRequired: Bool
    public init(from decoder: Decoder) throws {
        settings = try RouterSettings(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        restartRequired = try values.decode(Bool.self, forKey: .restartRequired)
    }
    enum CodingKeys: String, CodingKey { case restartRequired = "restart_required" }
}
```

Add:

```swift
extension RouterAdministrationClient {
    public func settings() async throws -> RouterSettings {
        let (data, _) = try await send("GET", "/api/v1/settings")
        guard let value = try? JSONDecoder().decode(RouterSettings.self, from: data) else {
            throw RouterAdministrationError.invalidResponse
        }
        return value
    }

    public func updateSettings(_ patch: RouterSettingsPatch) async throws -> RouterSettingsUpdateResult {
        let attachment = try attachmentLease()
        await acquirePrivilegedMutation()
        defer { releasePrivilegedMutation() }
        try Task.checkCancellation()
        try validate(attachment: attachment)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(patch)
        let (data, _) = try await send("PUT", "/api/v1/settings", body: body)
        try validate(attachment: attachment)
        guard let value = try? JSONDecoder().decode(RouterSettingsUpdateResult.self, from: data) else {
            throw RouterAdministrationError.invalidResponse
        }
        return value
    }
}
```

Do not alter `verifyAdministrator`: its exact-status-200 proof and credential persistence critical section remain unchanged. It may share only a private settings decoder later if doing so does not require decoding during verification.

- [ ] **Step 4: Run focused and full Task 12 GREEN**

```bash
swift test --package-path peakdo/apple/WattlineNetwork --filter RouterSettingsTests 2>&1 | tee /tmp/wattline-m3-task12-green.log
swift test --package-path peakdo/apple/WattlineNetwork 2>&1 | tee /tmp/wattline-m3-task12-network.log
git diff --check
```

Expected: focused settings tests pass; Network baseline 147 plus Task 12 tests passes with zero failures; no warning or whitespace error.

- [ ] **Step 5: Commit Task 12**

```bash
git add peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterSettings.swift \
  peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterSettingsTests.swift
git commit -m "feat: add typed router settings"
```

---

### Task 13: Safe settings editor and endpoint migration validation

**Files:**
- Create: `peakdo/apple/WattlineUI/Sources/WattlineUI/RouterSettingsPresentation.swift`
- Create: `peakdo/apple/WattlineUI/Tests/WattlineUITests/RouterSettingsPresentationTests.swift`
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterEndpointMigration.swift`
- Create: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterEndpointMigrationTests.swift`
- Modify: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterAdministrationModel.swift`
- Create: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterSettingsView.swift`
- Modify: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterAdministrationView.swift`
- Modify: `peakdo/apple/Wattline/WattlineTests/RouterAdministrationModelTests.swift`

**Interfaces:**
- Consumes: Task 12 settings/readback API and existing app `performAdmin` generation guard.
- Produces: UI-local `RouterSettingsValue`, `RouterSettingsDraft`, `RouterSettingsDraftPatch`, `RouterSettingsSaveContext`, `RouterSettingsSaveDecision`, `RouterSettingsConfirmation`; Network-owned `RouterEndpointMigrationValidator`; app mapping to `RouterSettingsPatch`; and readback-only `RouterAdministrationModel.settings` publication.
- Task 14 adds rotation state and actions to this same model/view but does not change the save policy.

- [ ] **Step 1: Write pure presentation RED tests**

Create `RouterSettingsPresentationTests.swift`:

```swift
import XCTest
@testable import WattlineUI

final class RouterSettingsPresentationTests: XCTestCase {
    func testUnchangedDraftProducesNoPatch() throws {
        let original = fixture()
        XCTAssertEqual(try RouterSettingsDraft(original).patch(from: original), .init())
    }

    func testNestedChangesAreSparseAndEmptyInterfacesAreExplicit() throws {
        let original = fixture()
        var draft = RouterSettingsDraft(original)
        draft.http.port = "9000"
        draft.mdns.interfaces = []
        let patch = try draft.patch(from: original)
        XCTAssertEqual(patch.http, .init(port: 9000))
        XCTAssertEqual(patch.mdns, .init(interfaces: []))
        XCTAssertNil(patch.https)
        XCTAssertNil(patch.tls)
    }

    func testBLEPINRequiresExactlySixASCIIDigitsAndPortsUseOneThrough65535() {
        for invalid in ["20555", "0205557", "02A555", "０２０５５５"] {
            var draft = RouterSettingsDraft(fixture()); draft.blePIN = invalid
            XCTAssertThrowsError(try draft.patch(from: fixture()))
        }
        for invalid in ["0", "65536", "8.0", ""] {
            var draft = RouterSettingsDraft(fixture()); draft.http.port = invalid
            XCTAssertThrowsError(try draft.patch(from: fixture()))
        }
    }

    func testZeroEnabledPostRestartListenersIsStructurallyInvalid() {
        let original = fixture()
        var draft = RouterSettingsDraft(original)
        draft.http.enabled = false; draft.https.enabled = false
        let decision = RouterSettingsSavePolicy.evaluate(
            original: original, draft: draft,
            context: .init(currentScheme: "https", currentPort: 8378)
        )
        XCTAssertEqual(decision.blocker, .noEnabledListener)
        XCTAssertFalse(decision.canSave)
    }

    func testRemovingCurrentListenerRequiresValidatedCorrelatedReplacement() {
        let original = fixture()
        var draft = RouterSettingsDraft(original); draft.https.enabled = false
        let missing = RouterSettingsSavePolicy.evaluate(
            original: original, draft: draft,
            context: .init(currentScheme: "https", currentPort: 8378)
        )
        XCTAssertEqual(missing.blocker, .validatedReplacementRequired)

        let wrongDevice = RouterReplacementCandidate(
            scheme: "http", host: "router.local", port: 8377,
            validation: .verified(deviceID: "AA:BB:CC:DD:EE:FF")
        )
        XCTAssertFalse(RouterSettingsSavePolicy.evaluate(
            original: original, draft: draft,
            context: .init(currentScheme: "https", currentPort: 8378,
                           expectedDeviceID: "DC:04:5A:EB:72:2B", replacement: wrongDevice)
        ).canSave)

        let matching = RouterReplacementCandidate(
            scheme: "http", host: "router.local", port: 8377,
            validation: .verified(deviceID: "dc045aeb722b")
        )
        let valid = RouterSettingsSavePolicy.evaluate(
            original: original, draft: draft,
            context: .init(currentScheme: "https", currentPort: 8378,
                           expectedDeviceID: "DC:04:5A:EB:72:2B", replacement: matching,
                           confirmations: [.listenerMigration])
        )
        XCTAssertTrue(valid.canSave)
    }

    func testRiskyChangesRequirePurposeSpecificConfirmations() {
        var insecure = RouterSettingsDraft(fixture())
        insecure.wanAccess = true
        let decision = RouterSettingsSavePolicy.evaluate(
            original: fixture(), draft: insecure,
            context: .init(currentScheme: "https", currentPort: 8378)
        )
        XCTAssertEqual(decision.requiredConfirmations, [.insecureWANHTTP])

        var listener = RouterSettingsDraft(fixture()); listener.http.port = "9000"
        XCTAssertEqual(RouterSettingsSavePolicy.evaluate(
            original: fixture(), draft: listener,
            context: .init(currentScheme: "https", currentPort: 8378)
        ).requiredConfirmations, [.listenerMigration])

        var store = RouterSettingsDraft(fixture()); store.tokenStore = "/mnt/new/tokens.json"
        XCTAssertEqual(RouterSettingsSavePolicy.evaluate(
            original: fixture(), draft: store,
            context: .init(currentScheme: "https", currentPort: 8378)
        ).requiredConfirmations, [.tokenStoreCutover])
    }

    func testRestartAndTokenStoreCopyIsHonest() {
        XCTAssertEqual(RouterSettingsCopy.restartRequired,
            "wattlined or the router must restart before these changes take effect.")
        XCTAssertTrue(RouterSettingsCopy.tokenStoreCutover.contains("closes existing managed live-update streams"))
        XCTAssertFalse(RouterSettingsCopy.restartRequired.contains("Link-Power"))
    }
}
```

The fixture contains every UI-local field corresponding to Task 12. `RouterSettingsDraft` uses `String` for editable ports and BLE PIN so leading zeroes survive. `RouterReplacementValidation.verified(deviceID:)` compares normalized MACs through a tiny UI-local ASCII-hex normalizer; it does not import Core or Network.

Create `RouterEndpointMigrationTests.swift` with the exact complete `/device` fixture from `docs/api.md` (including all required `RouterDeviceDTO` fields) and these tests:

```swift
import XCTest
@testable import WattlineNetwork

final class RouterEndpointMigrationTests: XCTestCase {
    func testCandidateProbeUsesSelectedEndpointAndSourceAdministratorCredential() async throws {
        let source = endpoint(scheme: "https", host: "router.local", port: 8378, pin: activePin)
        let candidate = endpoint(scheme: "http", host: "router.local", port: 8377, pin: nil)
        let credentials = RouterCredentialStore(backend: AdministrationCredentialBackend())
        try await credentials.saveToken("admin-token", for: source, role: .administrator)
        let http = ScriptedRouterHTTPClient(results: [.ok(deviceJSON(id: "DC:04:5A:EB:72:2B"))])
        let factory = RecordingHTTPFactory(client: http)
        let validator = RouterEndpointMigrationValidator(credentials: credentials,
                                                         httpFactory: factory.make)

        let value = try await validator.validate(
            sourceEndpoint: source, candidate: candidate,
            expectedDeviceID: "dc045aeb722b"
        )

        XCTAssertEqual(value.endpoint, candidate)
        XCTAssertEqual(value.deviceID, "DC:04:5A:EB:72:2B")
        XCTAssertEqual(factory.endpoints, [candidate])
        XCTAssertEqual(http.calls.map(\.path), ["/api/v1/device"])
        XCTAssertEqual(http.calls.map(\.token), ["admin-token"])
    }

    func testCandidateProbeRejectsDeviceMismatchAndMissingAdminCredential() async throws {
        let mismatch = try migrationHarness(deviceID: "AA:BB:CC:DD:EE:FF", storesToken: true)
        await XCTAssertThrowsErrorAsync(try await mismatch.validator.validate(
            sourceEndpoint: mismatch.source, candidate: mismatch.candidate,
            expectedDeviceID: "DC:04:5A:EB:72:2B"
        )) { XCTAssertEqual($0 as? RouterEndpointMigrationError, .deviceIDMismatch) }

        let missing = try migrationHarness(deviceID: "DC:04:5A:EB:72:2B", storesToken: false)
        await XCTAssertThrowsErrorAsync(try await missing.validator.validate(
            sourceEndpoint: missing.source, candidate: missing.candidate,
            expectedDeviceID: "DC:04:5A:EB:72:2B"
        )) { XCTAssertEqual($0 as? RouterAdministrationError, .invalidAdministratorToken) }
    }

    func testCandidateProbeDoesNotChangeSchemeOrFallbackAfterFailure() async throws {
        let harness = try migrationHarness(
            candidateScheme: "https", result: .failure(RouterHostValidationError.certificateFingerprintMismatch)
        )
        await XCTAssertThrowsErrorAsync(try await harness.validator.validate(
            sourceEndpoint: harness.source, candidate: harness.candidate,
            expectedDeviceID: "DC:04:5A:EB:72:2B"
        ))
        XCTAssertEqual(harness.factory.endpoints, [harness.candidate])
    }
}
```

- [ ] **Step 2: Run UI RED**

```bash
swift test --package-path peakdo/apple/WattlineUI --filter RouterSettingsPresentationTests 2>&1 | tee /tmp/wattline-m3-task13-ui-red.log
swift test --package-path peakdo/apple/WattlineNetwork --filter RouterEndpointMigrationTests 2>&1 | tee /tmp/wattline-m3-task13-network-red.log
```

Expected RED: missing `RouterSettingsDraft`/policy/presentation types and missing `RouterEndpointMigrationValidator`; failures must be feature absence, not malformed fixtures.

- [ ] **Step 3: Implement the pure UI-local form and policy**

Create `RouterSettingsPresentation.swift` with complete UI-local value mirrors and this API:

```swift
import Foundation

public struct RouterListenerSettingsValue: Equatable, Sendable {
    public var enabled: Bool; public var addr4: String; public var addr6: String; public var port: Int
    public init(enabled: Bool, addr4: String, addr6: String, port: Int) {
        self.enabled = enabled; self.addr4 = addr4; self.addr6 = addr6; self.port = port
    }
}
public struct RouterTLSSettingsValue: Equatable, Sendable {
    public var cert: String; public var key: String; public var sha256: String
    public init(cert: String, key: String, sha256: String) {
        self.cert = cert; self.key = key; self.sha256 = sha256
    }
}
public struct RouterMDNSSettingsValue: Equatable, Sendable {
    public var enabled: Bool; public var interfaces: [String]
    public init(enabled: Bool, interfaces: [String]) {
        self.enabled = enabled; self.interfaces = interfaces
    }
}
public struct RouterSettingsValue: Equatable, Sendable {
    public var http: RouterListenerSettingsValue; public var https: RouterListenerSettingsValue
    public var tls: RouterTLSSettingsValue; public var tokenStore: String
    public var pairingTTL: String; public var pairingAlwaysOn: Bool; public var advanced: Bool
    public var mdns: RouterMDNSSettingsValue; public var wanAccess: Bool; public var blePIN: String
    public init(http: RouterListenerSettingsValue, https: RouterListenerSettingsValue,
        tls: RouterTLSSettingsValue, tokenStore: String, pairingTTL: String,
        pairingAlwaysOn: Bool, advanced: Bool, mdns: RouterMDNSSettingsValue,
        wanAccess: Bool, blePIN: String) {
        self.http = http; self.https = https; self.tls = tls; self.tokenStore = tokenStore
        self.pairingTTL = pairingTTL; self.pairingAlwaysOn = pairingAlwaysOn
        self.advanced = advanced; self.mdns = mdns; self.wanAccess = wanAccess
        self.blePIN = blePIN
    }
}

public struct RouterListenerDraft: Equatable, Sendable {
    public var enabled: Bool; public var addr4: String; public var addr6: String; public var port: String
}
public struct RouterTLSDraft: Equatable, Sendable { public var cert: String; public var key: String }
public struct RouterMDNSDraft: Equatable, Sendable { public var enabled: Bool; public var interfaces: [String] }
public struct RouterSettingsDraft: Equatable, Sendable {
    public var http: RouterListenerDraft; public var https: RouterListenerDraft
    public var tls: RouterTLSDraft; public var tokenStore: String
    public var pairingTTL: String; public var pairingAlwaysOn: Bool; public var advanced: Bool
    public var mdns: RouterMDNSDraft; public var wanAccess: Bool; public var blePIN: String
    public init(_ value: RouterSettingsValue) {
        http = RouterListenerDraft(enabled: value.http.enabled, addr4: value.http.addr4,
            addr6: value.http.addr6, port: String(value.http.port))
        https = RouterListenerDraft(enabled: value.https.enabled, addr4: value.https.addr4,
            addr6: value.https.addr6, port: String(value.https.port))
        tls = RouterTLSDraft(cert: value.tls.cert, key: value.tls.key)
        tokenStore = value.tokenStore; pairingTTL = value.pairingTTL
        pairingAlwaysOn = value.pairingAlwaysOn; advanced = value.advanced
        mdns = RouterMDNSDraft(enabled: value.mdns.enabled, interfaces: value.mdns.interfaces)
        wanAccess = value.wanAccess; blePIN = value.blePIN
    }

    public func patch(from original: RouterSettingsValue) throws -> RouterSettingsDraftPatch {
        guard let httpPort = Int(http.port), (1...65_535).contains(httpPort) else {
            throw RouterSettingsValidationError.invalidHTTPPort
        }
        guard let httpsPort = Int(https.port), (1...65_535).contains(httpsPort) else {
            throw RouterSettingsValidationError.invalidHTTPSPort
        }
        let pinBytes = Array(blePIN.utf8)
        guard pinBytes.count == 6, pinBytes.allSatisfy({ (48...57).contains($0) }) else {
            throw RouterSettingsValidationError.invalidBLEPIN
        }
        return RouterSettingsDraftPatch(
            http: RouterListenerDraftPatch.changed(draft: http, port: httpPort, original: original.http),
            https: RouterListenerDraftPatch.changed(draft: https, port: httpsPort, original: original.https),
            tls: RouterTLSDraftPatch.changed(draft: tls, original: original.tls),
            tokenStore: tokenStore == original.tokenStore ? nil : tokenStore,
            pairingTTL: pairingTTL == original.pairingTTL ? nil : pairingTTL,
            pairingAlwaysOn: pairingAlwaysOn == original.pairingAlwaysOn ? nil : pairingAlwaysOn,
            advanced: advanced == original.advanced ? nil : advanced,
            mdns: RouterMDNSDraftPatch.changed(draft: mdns, original: original.mdns),
            wanAccess: wanAccess == original.wanAccess ? nil : wanAccess,
            blePIN: blePIN == original.blePIN ? nil : blePIN
        )
    }
}

public struct RouterSettingsDraftPatch: Equatable, Sendable {
    public var http: RouterListenerDraftPatch? = nil; public var https: RouterListenerDraftPatch? = nil
    public var tls: RouterTLSDraftPatch? = nil; public var tokenStore: String? = nil
    public var pairingTTL: String? = nil; public var pairingAlwaysOn: Bool? = nil
    public var advanced: Bool? = nil; public var mdns: RouterMDNSDraftPatch? = nil
    public var wanAccess: Bool? = nil; public var blePIN: String? = nil
    public init(http: RouterListenerDraftPatch? = nil, https: RouterListenerDraftPatch? = nil,
        tls: RouterTLSDraftPatch? = nil, tokenStore: String? = nil,
        pairingTTL: String? = nil, pairingAlwaysOn: Bool? = nil,
        advanced: Bool? = nil, mdns: RouterMDNSDraftPatch? = nil,
        wanAccess: Bool? = nil, blePIN: String? = nil) {
        self.http = http; self.https = https; self.tls = tls; self.tokenStore = tokenStore
        self.pairingTTL = pairingTTL; self.pairingAlwaysOn = pairingAlwaysOn
        self.advanced = advanced; self.mdns = mdns; self.wanAccess = wanAccess
        self.blePIN = blePIN
    }
    public var isEmpty: Bool {
        http == nil && https == nil && tls == nil && tokenStore == nil && pairingTTL == nil
            && pairingAlwaysOn == nil && advanced == nil && mdns == nil
            && wanAccess == nil && blePIN == nil
    }
}
public struct RouterListenerDraftPatch: Equatable, Sendable {
    public var enabled: Bool? = nil; public var addr4: String? = nil
    public var addr6: String? = nil; public var port: Int? = nil
    public init(enabled: Bool? = nil, addr4: String? = nil, addr6: String? = nil,
        port: Int? = nil) {
        self.enabled = enabled; self.addr4 = addr4; self.addr6 = addr6; self.port = port
    }
    static func changed(draft: RouterListenerDraft, port: Int,
        original: RouterListenerSettingsValue) -> Self? {
        let value = Self(enabled: draft.enabled == original.enabled ? nil : draft.enabled,
            addr4: draft.addr4 == original.addr4 ? nil : draft.addr4,
            addr6: draft.addr6 == original.addr6 ? nil : draft.addr6,
            port: port == original.port ? nil : port)
        return value.enabled == nil && value.addr4 == nil && value.addr6 == nil && value.port == nil
            ? nil : value
    }
}
public struct RouterTLSDraftPatch: Equatable, Sendable {
    public var cert: String? = nil; public var key: String? = nil
    public init(cert: String? = nil, key: String? = nil) { self.cert = cert; self.key = key }
    static func changed(draft: RouterTLSDraft, original: RouterTLSSettingsValue) -> Self? {
        let value = Self(cert: draft.cert == original.cert ? nil : draft.cert,
                         key: draft.key == original.key ? nil : draft.key)
        return value.cert == nil && value.key == nil ? nil : value
    }
}
public struct RouterMDNSDraftPatch: Equatable, Sendable {
    public var enabled: Bool? = nil; public var interfaces: [String]? = nil
    public init(enabled: Bool? = nil, interfaces: [String]? = nil) {
        self.enabled = enabled; self.interfaces = interfaces
    }
    static func changed(draft: RouterMDNSDraft, original: RouterMDNSSettingsValue) -> Self? {
        let value = Self(enabled: draft.enabled == original.enabled ? nil : draft.enabled,
                         interfaces: draft.interfaces == original.interfaces ? nil : draft.interfaces)
        return value.enabled == nil && value.interfaces == nil ? nil : value
    }
}

public enum RouterSettingsValidationError: Error, Equatable, Sendable { case invalidHTTPPort, invalidHTTPSPort, invalidBLEPIN }
public enum RouterSettingsSaveBlocker: Equatable, Sendable { case invalidDraft, noEnabledListener, validatedReplacementRequired }
public enum RouterSettingsConfirmation: Hashable, Sendable { case insecureWANHTTP, listenerMigration, tokenStoreCutover }
public enum RouterReplacementValidation: Equatable, Sendable { case unvalidated, failed, verified(deviceID: String) }
public struct RouterReplacementCandidate: Equatable, Sendable {
    public let scheme: String; public let host: String; public let port: Int
    public let validation: RouterReplacementValidation
    public init(scheme: String, host: String, port: Int,
        validation: RouterReplacementValidation) {
        self.scheme = scheme; self.host = host; self.port = port; self.validation = validation
    }
}
public struct RouterSettingsSaveContext: Equatable, Sendable {
    public let currentScheme: String; public let currentPort: Int
    public let expectedDeviceID: String?; public let replacement: RouterReplacementCandidate?
    public let confirmations: Set<RouterSettingsConfirmation>
    public init(currentScheme: String, currentPort: Int, expectedDeviceID: String? = nil,
        replacement: RouterReplacementCandidate? = nil,
        confirmations: Set<RouterSettingsConfirmation> = []) {
        self.currentScheme = currentScheme; self.currentPort = currentPort
        self.expectedDeviceID = expectedDeviceID; self.replacement = replacement
        self.confirmations = confirmations
    }
}
public struct RouterSettingsSaveDecision: Equatable, Sendable {
    public let patch: RouterSettingsDraftPatch?; public let blocker: RouterSettingsSaveBlocker?
    public let requiredConfirmations: Set<RouterSettingsConfirmation>
    public var canSave: Bool { blocker == nil && requiredConfirmations.isEmpty && patch != nil }
}
public enum RouterSettingsSavePolicy {
    public static func evaluate(original: RouterSettingsValue, draft: RouterSettingsDraft,
        context: RouterSettingsSaveContext) -> RouterSettingsSaveDecision {
        let patch: RouterSettingsDraftPatch
        do { patch = try draft.patch(from: original) }
        catch {
            return RouterSettingsSaveDecision(patch: nil, blocker: .invalidDraft,
                                              requiredConfirmations: [])
        }
        guard draft.http.enabled || draft.https.enabled else {
            return RouterSettingsSaveDecision(patch: patch, blocker: .noEnabledListener,
                                              requiredConfirmations: [])
        }
        let currentRemains = context.currentScheme.lowercased() == "https"
            ? draft.https.enabled && Int(draft.https.port) == context.currentPort
            : draft.http.enabled && Int(draft.http.port) == context.currentPort
        if !currentRemains && !replacementIsCorrelated(context) {
            return RouterSettingsSaveDecision(patch: patch,
                blocker: .validatedReplacementRequired, requiredConfirmations: [])
        }
        var required: Set<RouterSettingsConfirmation> = []
        if draft.wanAccess && draft.http.enabled
            && (!original.wanAccess || !original.http.enabled) {
            required.insert(.insecureWANHTTP)
        }
        if patch.http != nil || patch.https != nil || patch.tls != nil {
            required.insert(.listenerMigration)
        }
        if patch.tokenStore != nil { required.insert(.tokenStoreCutover) }
        required.subtract(context.confirmations)
        return RouterSettingsSaveDecision(patch: patch.isEmpty ? nil : patch,
            blocker: nil, requiredConfirmations: required)
    }

    private static func replacementIsCorrelated(_ context: RouterSettingsSaveContext) -> Bool {
        guard let expected = normalizedMAC(context.expectedDeviceID),
              let candidate = context.replacement,
              (1...65_535).contains(candidate.port),
              candidate.scheme == "http" || candidate.scheme == "https",
              case let .verified(deviceID) = candidate.validation
        else { return false }
        return normalizedMAC(deviceID) == expected
    }

    private static func normalizedMAC(_ value: String?) -> String? {
        guard let value else { return nil }
        let bytes = value.utf8.filter { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
        guard bytes.count == 12 else { return nil }
        return String(decoding: bytes, as: UTF8.self).uppercased()
    }
}
public enum RouterSettingsCopy {
    public static let restartRequired = "wattlined or the router must restart before these changes take effect."
    public static let tokenStoreCutover = "Changing token storage closes existing managed live-update streams; Wattline does not migrate tokens between stores."
}
```

Implementation rules: parse ports with `Int` and `1...65535`; validate BLE PIN with exactly six UTF-8 bytes all in `0x30...0x39`; compare each member to make the sparse patch; set `interfaces: []` when changed to empty; consider current listener preserved only when the matching scheme remains enabled on the same port; require a verified same-device candidate when it disappears; require confirmations without marking the underlying controls merely disabled.

Create `RouterEndpointMigration.swift`:

```swift
import Foundation

public struct ValidatedRouterReplacement: Equatable, Sendable {
    public let endpoint: RouterEndpoint
    public let deviceID: String
}

public enum RouterEndpointMigrationError: Error, Equatable, Sendable {
    case invalidExpectedDeviceID
    case invalidResponse
    case deviceIDMismatch
}

public struct RouterEndpointMigrationValidator: Sendable {
    public typealias HTTPFactory = @Sendable (RouterEndpoint) throws -> any RouterHTTPClient
    private let credentials: RouterCredentialStore
    private let httpFactory: HTTPFactory

    public init(credentials: RouterCredentialStore, httpFactory: @escaping HTTPFactory) {
        self.credentials = credentials; self.httpFactory = httpFactory
    }

    public func validate(sourceEndpoint: RouterEndpoint, candidate: RouterEndpoint,
        expectedDeviceID: String) async throws -> ValidatedRouterReplacement {
        guard let expected = DeviceIdentityDeduplicator.normalizedMAC(expectedDeviceID) else {
            throw RouterEndpointMigrationError.invalidExpectedDeviceID
        }
        guard let token = try await credentials.readToken(
            for: sourceEndpoint, role: .administrator
        ) else { throw RouterAdministrationError.invalidAdministratorToken }
        let (data, response) = try await httpFactory(candidate).get(
            "/api/v1/device", token: token
        )
        guard response.statusCode == 200,
              let device = try? JSONDecoder().decode(RouterDeviceDTO.self, from: data),
              let observed = DeviceIdentityDeduplicator.normalizedMAC(device.id)
        else { throw RouterEndpointMigrationError.invalidResponse }
        guard observed == expected else { throw RouterEndpointMigrationError.deviceIDMismatch }
        return ValidatedRouterReplacement(endpoint: candidate, deviceID: device.id)
    }
}
```

The validator receives an explicit selected candidate; it never discovers, rewrites, retries with another scheme, or falls back. It reads the source endpoint's stored administrator credential because a newly selected listener endpoint has no separate credential account yet. Its returned value contains no token.

- [ ] **Step 4: Run UI GREEN, then write app model RED tests**

```bash
swift test --package-path peakdo/apple/WattlineUI --filter RouterSettingsPresentationTests 2>&1 | tee /tmp/wattline-m3-task13-ui-green.log
swift test --package-path peakdo/apple/WattlineNetwork --filter RouterEndpointMigrationTests 2>&1 | tee /tmp/wattline-m3-task13-network-green.log
```

Add to `RouterAdministrationModelTests.swift`:

```swift
func testUnlockedModelLoadsSettingsAndPublishesOnlyCompletePUTReadback() async throws {
    let original = settings(advanced: false, httpPort: 8377)
    let readback = settings(advanced: true, httpPort: 9000)
    let harness = try await makeUnlockedHarness(settingsResults: [original, .update(readback, restart: true)])
    await harness.model.reloadSettings()
    XCTAssertEqual(harness.model.settings, original)

    await harness.model.saveSettings(.init(http: .init(port: 9000), advanced: true))

    XCTAssertEqual(harness.model.settings, readback)
    XCTAssertEqual(harness.model.settings?.http.port, 9000)
    XCTAssertTrue(harness.model.settingsRestartRequired)
}

func testControlRequestNeverPublishesDraftBeforeReadbackCompletes() async throws {
    let harness = try await makeUnlockedHarness(settingsResults: [settings(advanced: false)], gateSave: true)
    await harness.model.reloadSettings()
    let save = Task { await harness.model.saveSettings(.init(advanced: true)) }
    await harness.http.waitForGateRegistration()
    XCTAssertFalse(try XCTUnwrap(harness.model.settings).advanced)
    harness.http.releaseGates(); await save.value
}

func testSaveCompletingAfterEndpointReplacementDoesNotPublish() async throws {
    let first = try await makeUnlockedHarness(settingsResults: [settings(advanced: false), .update(settings(advanced: true), restart: false)], gateSave: true)
    await first.model.reloadSettings()
    let save = Task { await first.model.saveSettings(.init(advanced: true)) }
    await first.http.waitForGateRegistration()
    await first.model.begin(host: replacementHost())
    first.http.releaseGates(); await save.value
    XCTAssertNotEqual(first.model.settings?.advanced, true)
}

func testSettingsSectionIsStructurallyAbsentWhileAdministratorLocked() {
    XCTAssertFalse(RouterAdministrationPresentation(access: .locked).visibleSections.contains(.routerConfiguration))
    XCTAssertTrue(RouterAdministrationPresentation(access: .unlocked).visibleSections.contains(.routerConfiguration))
}

func testReplacementCandidateBecomesVerifiedOnlyAfterCorrelatedProbe() async throws {
    let harness = try await makeUnlockedHarness(replacementDeviceID: "DC:04:5A:EB:72:2B")
    await harness.model.validateReplacement(harness.candidateHost)
    XCTAssertEqual(harness.model.validatedReplacement?.validation,
                   .verified(deviceID: "DC:04:5A:EB:72:2B"))
}
```

- [ ] **Step 5: Run app RED**

```bash
WATTLINE_SIMULATOR_NAME=${WATTLINE_SIMULATOR_NAME:-Wattline-Tests-2}
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination "platform=iOS Simulator,name=${WATTLINE_SIMULATOR_NAME}" CODE_SIGNING_ALLOWED=NO \
  -only-testing:WattlineTests/RouterAdministrationModelTests 2>&1 | tee /tmp/wattline-m3-task13-app-red.log
```

Expected RED: missing model settings state/actions and `.routerConfiguration` presentation case.

- [ ] **Step 6: Implement app mapping, generation guards, and secure form**

Extend `RouterAdministrationModel` with:

```swift
private(set) var settings: RouterSettings?
private(set) var settingsError: String?
private(set) var settingsRestartRequired = false
private(set) var isSettingsLoading = false
private(set) var isSettingsSaving = false
private var settingsRequestGeneration: UInt64 = 0

func reloadSettings() async {
    settingsRequestGeneration &+= 1
    let request = settingsRequestGeneration
    isSettingsLoading = true; settingsError = nil
    let result = await performAdmin({ try await $0.settings() }, isCurrent: {
        self.settingsRequestGeneration == request
    })
    guard settingsRequestGeneration == request else { return }
    isSettingsLoading = false
    if case let .success(value) = result { settings = value; settingsError = nil }
    else if case let .failure(message) = result { settingsError = message }
}

func saveSettings(_ patch: RouterSettingsPatch) async {
    settingsRequestGeneration &+= 1
    let request = settingsRequestGeneration
    isSettingsSaving = true; settingsError = nil
    let result = await performAdmin({ try await $0.updateSettings(patch) }, isCurrent: {
        self.settingsRequestGeneration == request
    })
    guard settingsRequestGeneration == request else { return }
    isSettingsSaving = false
    switch result {
    case let .success(value): settings = value.settings; settingsRestartRequired = value.restartRequired
    case let .failure(message): settingsError = message
    case .stale: break
    }
}
```

Increment `settingsRequestGeneration`, clear settings/editor state, and reset flags in `beginSession`, `end`, and lock transitions. Map Network↔UI values in `RouterSettingsView` private functions. The view:

- loads once with `.task { await model.reloadSettings() }`;
- stores `RouterSettingsDraft?` only while visible and clears it on disappear;
- uses `SecureField("BLE PIN", text: ...)`, `.textContentType(.oneTimeCode)`, numeric keyboard, monospaced digits, no logging or string interpolation;
- renders HTTP/HTTPS toggles, addresses/ports, cert/key paths, token store, pairing TTL/always-on, Advanced, mDNS/interfaces, WAN, and BLE PIN;
- omits the Save button entirely when there is no valid patch or zero listeners; shows candidate selection/validation when required;
- presents separate confirmation dialogs for listener migration, insecure WAN HTTP, and token-store cutover;
- renders `RouterSettingsCopy.restartRequired` only from the authoritative PUT `restart_required` flag;
- states token-store cutover consequences without claiming migration.

Inject one `RouterEndpointMigrationValidator` into the model's production factory using `RouterURLSessionFactory`/`HTTPClient`. `validateReplacement(_:)` captures the current session and candidate request generation, probes the explicitly selected saved/discovered host against `host.deviceID`, and publishes `.verified(deviceID:)` only when both generations remain current. A failed or stale probe cannot leave a verified flag. Candidate choices come from already known saved/discovered hosts; the model does not fabricate an endpoint from an unstarted post-restart listener.

Add `.routerConfiguration` to the existing admin section presentation and insert `RouterSettingsView(model: admin)` only inside `if presentation.visibleSections.contains(.routerConfiguration)`.

- [ ] **Step 7: Run Task 13 GREEN suites**

```bash
swift test --package-path peakdo/apple/WattlineUI 2>&1 | tee /tmp/wattline-m3-task13-ui.log
swift test --package-path peakdo/apple/WattlineNetwork 2>&1 | tee /tmp/wattline-m3-task13-network.log
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination "platform=iOS Simulator,name=${WATTLINE_SIMULATOR_NAME}" CODE_SIGNING_ALLOWED=NO \
  -only-testing:WattlineTests/RouterAdministrationModelTests 2>&1 | tee /tmp/wattline-m3-task13-app-green.log
xcodebuild build -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
git diff --check
```

Expected: UI baseline 33 plus new pure tests; focused app model tests and generic build pass; no optimistic publication.

- [ ] **Step 8: Commit Task 13**

```bash
git add peakdo/apple/WattlineUI peakdo/apple/WattlineNetwork \
  peakdo/apple/Wattline/Wattline/RouterAdministration \
  peakdo/apple/Wattline/WattlineTests/RouterAdministrationModelTests.swift
git commit -m "feat: edit router configuration safely"
```

---

### Task 14: TLS staged-pin rotation and atomic promotion

**Files:**
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterTLSRotation.swift`
- Modify: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterHostStore.swift`
- Reuse unchanged unless a test proves a needed internal seam: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterTLSPinning.swift`
- Create: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterTLSRotationTests.swift`
- Modify: `peakdo/apple/Wattline/Wattline/RouterConnectionModel.swift`
- Modify: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterAdministrationModel.swift`
- Modify: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterSettingsView.swift`
- Modify: `peakdo/apple/Wattline/WattlineTests/RouterAdministrationModelTests.swift`

**Interfaces:**
- Consumes: active `RouterHostMetadata.certificateFingerprint`, Task 12 admin mutation path, client credential store, `RouterDeviceDTO`, `RouterURLSessionFactory`, and `RouterHostStore` actor serialization.
- Produces: `RouterTLSRotationResponse`, `RouterAdministrationClient.rotateTLS()`, additive `stagedCertificateFingerprint`, `RouterTLSPinPromoter`, atomic host-store stage/promote methods, and app rotation/promotion actions.

Normative rotate response copied exactly from `docs/api.md`:

```swift
private let rotateJSON = #"{"sha256":"abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789","restart_required":true}"#
```

- [ ] **Step 1: Write strict wire and persistence RED tests**

Create `RouterTLSRotationTests.swift`:

```swift
import XCTest
@testable import WattlineNetwork

final class RouterTLSRotationTests: XCTestCase {
    private let activeDER = Data([0x30, 0x03, 0x01, 0x10, 0x01])
    private let stagedDER = Data([0x30, 0x03, 0x01, 0x10, 0x02])
    private var activePin: String {
        RouterTLSFingerprintPolicy.fingerprint(of: activeDER).lowercased()
    }
    private var stagedPin: String {
        RouterTLSFingerprintPolicy.fingerprint(of: stagedDER).lowercased()
    }
    func testRotateUsesExactConfirmedBodyAndRequiresLowercaseFingerprintAndRestart() async throws {
        let (client, http) = try await attachedClient(results: [.ok(rotateJSON)])
        let response = try await client.rotateTLS()
        XCTAssertEqual(response.sha256, "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789")
        XCTAssertTrue(response.restartRequired)
        XCTAssertEqual(http.calls[0].method, "POST")
        XCTAssertEqual(http.calls[0].path, "/api/v1/tls/rotate")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: XCTUnwrap(http.calls[0].body)) as? NSDictionary,
                       ["confirm": true])
    }

    func testRotateRejectsUppercaseShortNonHexAndRestartFalse() async throws {
        for json in [
            #"{"sha256":"ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789","restart_required":true}"#,
            #"{"sha256":"abc","restart_required":true}"#,
            #"{"sha256":"gbcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789","restart_required":true}"#,
            #"{"sha256":"abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789","restart_required":false}"#,
        ] {
            let (client, _) = try await attachedClient(results: [.ok(json)])
            await XCTAssertThrowsErrorAsync(try await client.rotateTLS()) {
                XCTAssertEqual($0 as? RouterAdministrationError, .invalidResponse)
            }
        }
    }

    func testLegacyHostDecodesNilStagedPinAndOrdinaryEndpointUsesOnlyActivePin() throws {
        let legacy = try JSONDecoder().decode(RouterHostMetadata.self, from: legacyHostJSON)
        XCTAssertNil(legacy.stagedCertificateFingerprint)
        XCTAssertEqual(legacy.endpoint.certificateFingerprint, activePin.uppercased())
        XCTAssertNotEqual(legacy.endpoint.certificateFingerprint, stagedPin.uppercased())
    }

    func testStagePersistsSeparatelyWithoutChangingActiveEndpoint() async throws {
        let (store, backend, host) = try hostStoreFixture(active: activePin)
        let staged = try await store.stageCertificateFingerprint(stagedPin, for: host.id)
        XCTAssertEqual(staged.certificateFingerprint, activePin.uppercased())
        XCTAssertEqual(staged.stagedCertificateFingerprint, stagedPin.uppercased())
        XCTAssertEqual(staged.endpoint.certificateFingerprint, activePin.uppercased())
        XCTAssertFalse(String(decoding: try XCTUnwrap(backend.data), as: UTF8.self).contains("private"))
    }

    func testPromotionTrialUsesOnlyStagedPinAndCorrelatedDeviceThenAtomicallyPromotes() async throws {
        let (store, _, host) = try hostStoreFixture(active: activePin, staged: stagedPin,
                                                    deviceID: "DC:04:5A:EB:72:2B")
        let http = ScriptedRouterHTTPClient(results: [.ok(deviceJSON(id: "DC:04:5A:EB:72:2B"))])
        let factory = RecordingHTTPFactory(client: http)
        let promoter = RouterTLSPinPromoter(
            hostStore: store, credentials: credentialStore(token: "client-token"),
            httpFactory: factory.make
        )

        let promoted = try await promoter.promote(hostID: host.id)

        XCTAssertEqual(factory.endpoints.single?.scheme, "https")
        XCTAssertEqual(factory.endpoints.single?.certificateFingerprint, stagedPin.uppercased())
        XCTAssertEqual(promoted.certificateFingerprint, stagedPin.uppercased())
        XCTAssertNil(promoted.stagedCertificateFingerprint)
        XCTAssertEqual(http.calls.map(\.path), ["/api/v1/device"])
    }

    func testDeviceMismatchAbortsPromotionAndKeepsBothPins() async throws {
        let harness = try promotionHarness(deviceReplyID: "AA:BB:CC:DD:EE:FF")
        await XCTAssertThrowsErrorAsync(try await harness.promoter.promote(hostID: harness.host.id)) {
            XCTAssertEqual($0 as? RouterTLSPromotionError, .deviceIDMismatch)
        }
        let saved = try XCTUnwrap(await harness.store.hosts().first)
        XCTAssertEqual(saved.certificateFingerprint, activePin.uppercased())
        XCTAssertEqual(saved.stagedCertificateFingerprint, stagedPin.uppercased())
    }

    func testConcurrentRestagePreventsStaleTrialFromPromoting() async throws {
        let harness = try gatedPromotionHarness()
        let promotion = Task { try await harness.promoter.promote(hostID: harness.host.id) }
        await harness.http.waitForGateRegistration()
        _ = try await harness.store.stageCertificateFingerprint(thirdPin, for: harness.host.id)
        harness.http.releaseGates()
        await XCTAssertThrowsErrorAsync(try await promotion.value) {
            XCTAssertEqual($0 as? RouterTLSPromotionError, .hostChanged)
        }
        XCTAssertEqual(try XCTUnwrap(await harness.store.hosts().first).stagedCertificateFingerprint,
                       thirdPin.uppercased())
    }

    func testPromotionRejectsHTTPMissingStageAndNeverFallsBack() async throws {
        for host in [httpHost(staged: stagedPin), httpsHost(staged: nil)] {
            let harness = try promotionHarness(host: host)
            await XCTAssertThrowsErrorAsync(try await harness.promoter.promote(hostID: host.id))
            XCTAssertTrue(harness.factory.endpoints.isEmpty)
        }
    }

    func testOldPinIsNotUsedAfterPromotion() async throws {
        let harness = try promotionHarness(deviceReplyID: "DC:04:5A:EB:72:2B")
        let promoted = try await harness.promoter.promote(hostID: harness.host.id)
        XCTAssertEqual(promoted.endpoint.certificateFingerprint, stagedPin.uppercased())
        XCTAssertTrue(RouterTLSFingerprintPolicy.matches(
            expected: try XCTUnwrap(promoted.endpoint.certificateFingerprint),
            certificateData: stagedDER
        ))
        XCTAssertFalse(RouterTLSFingerprintPolicy.matches(
            expected: try XCTUnwrap(promoted.endpoint.certificateFingerprint),
            certificateData: activeDER
        ))
    }
}
```

The deterministic DER byte fixtures exercise the same SHA-256 leaf-byte policy as the URLSession delegate; the test proves the promoted active policy accepts staged certificate bytes and rejects the former active certificate bytes.

- [ ] **Step 2: Run Task 14 Network RED**

```bash
swift test --package-path peakdo/apple/WattlineNetwork --filter RouterTLSRotationTests 2>&1 | tee /tmp/wattline-m3-task14-network-red.log
```

Expected RED: missing rotation response, staged metadata, host-store operations, and promoter.

- [ ] **Step 3: Implement exact rotation, additive metadata, and staged-only promoter**

In `RouterHostStore.swift`, add `public let stagedCertificateFingerprint: String?` to `RouterHostMetadata`; supply `nil` from `RouterHostValidator.validate`. Because it is optional, synthesized decoding accepts legacy records. Add these complete copy helpers so stage/promote preserve every unrelated field including `tokenID` without ambiguous double-optionals:

```swift
extension RouterHostMetadata {
    func stagingCertificateFingerprint(_ value: String) -> RouterHostMetadata {
        RouterHostMetadata(
            id: id, displayName: displayName, scheme: scheme, host: host, port: port,
            reachability: reachability, allowsInsecureWAN: allowsInsecureWAN,
            deviceID: deviceID, certificateFingerprint: certificateFingerprint,
            stagedCertificateFingerprint: value, tokenID: tokenID
        )
    }

    func promotingStagedCertificateFingerprint(_ value: String) -> RouterHostMetadata {
        RouterHostMetadata(
            id: id, displayName: displayName, scheme: scheme, host: host, port: port,
            reachability: reachability, allowsInsecureWAN: allowsInsecureWAN,
            deviceID: deviceID, certificateFingerprint: value,
            stagedCertificateFingerprint: nil, tokenID: tokenID
        )
    }
}
```

Add actor-isolated operations:

```swift
public func stageCertificateFingerprint(_ fingerprint: String, for id: UUID) throws -> RouterHostMetadata {
    guard let normalized = RouterHostValidator.normalizeFingerprint(fingerprint),
          var host = hosts().first(where: { $0.id == id }),
          host.scheme == "https"
    else { throw RouterTLSPromotionError.invalidHost }
    host = host.stagingCertificateFingerprint(normalized)
    try save(host)
    return host
}

func promoteCertificateFingerprint(
    for id: UUID, expectedActive: String, expectedStaged: String,
    expectedDeviceID: String
) throws -> RouterHostMetadata {
    guard let host = hosts().first(where: { $0.id == id }),
          host.certificateFingerprint == expectedActive,
          host.stagedCertificateFingerprint == expectedStaged,
          normalizedMAC(host.deviceID) == normalizedMAC(expectedDeviceID)
    else { throw RouterTLSPromotionError.hostChanged }
    let promoted = host.promotingStagedCertificateFingerprint(expectedStaged)
    try save(promoted)
    return promoted
}
```

Create `RouterTLSRotation.swift`:

```swift
import Foundation

public struct RouterTLSRotationResponse: Equatable, Sendable, Decodable {
    public let sha256: String
    public let restartRequired: Bool
    enum CodingKeys: String, CodingKey { case sha256; case restartRequired = "restart_required" }
}

public enum RouterTLSPromotionError: Error, Equatable, Sendable {
    case invalidRotationResponse, invalidHost, missingStagedPin, deviceIDMismatch, hostChanged
}

extension RouterAdministrationClient {
    public func rotateTLS() async throws -> RouterTLSRotationResponse {
        let attachment = try attachmentLease()
        await acquirePrivilegedMutation()
        defer { releasePrivilegedMutation() }
        try validate(attachment: attachment)
        let body = Data(#"{"confirm":true}"#.utf8)
        let (data, _) = try await send("POST", "/api/v1/tls/rotate", body: body)
        try validate(attachment: attachment)
        guard let value = try? JSONDecoder().decode(RouterTLSRotationResponse.self, from: data),
              value.restartRequired,
              value.sha256.utf8.count == 64,
              value.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw RouterAdministrationError.invalidResponse }
        return value
    }
}

public actor RouterTLSPinPromoter {
    public typealias HTTPFactory = @Sendable (RouterEndpoint) throws -> any RouterHTTPClient
    private let hostStore: RouterHostStore
    private let credentials: RouterCredentialStore
    private let httpFactory: HTTPFactory

    public init(hostStore: RouterHostStore, credentials: RouterCredentialStore,
                httpFactory: @escaping HTTPFactory) {
        self.hostStore = hostStore
        self.credentials = credentials
        self.httpFactory = httpFactory
    }

    public func promote(hostID: UUID) async throws -> RouterHostMetadata {
        guard let host = await hostStore.hosts().first(where: { $0.id == hostID }),
              host.scheme == "https",
              let active = host.certificateFingerprint,
              let staged = host.stagedCertificateFingerprint,
              let expectedID = host.deviceID
        else { throw RouterTLSPromotionError.invalidHost }
        let trial = RouterEndpoint(
            scheme: "https", host: host.host, port: host.port,
            certificateFingerprint: staged, allowsInsecureWAN: false
        )
        let credential = try await credentials.credential(for: trial)
        let (data, response) = try await httpFactory(trial).get("/api/v1/device", token: credential.token)
        guard response.statusCode == 200,
              let device = try? JSONDecoder().decode(RouterDeviceDTO.self, from: data),
              DeviceIdentityDeduplicator.normalizedMAC(device.id)
                == DeviceIdentityDeduplicator.normalizedMAC(expectedID)
        else { throw RouterTLSPromotionError.deviceIDMismatch }
        return try await hostStore.promoteCertificateFingerprint(
            for: hostID, expectedActive: active, expectedStaged: staged,
            expectedDeviceID: expectedID
        )
    }
}
```

Production `HTTPFactory` must call `RouterURLSessionFactory.make(endpoint:)` and `baseURL(for:)`; because the trial endpoint contains only staged pin and remains HTTPS, the bearer token is never sent before staged-pin validation. Do not add a dual-pin delegate or fallback branch.

- [ ] **Step 4: Run Network GREEN, then write app integration RED tests**

```bash
swift test --package-path peakdo/apple/WattlineNetwork --filter RouterTLSRotationTests 2>&1 | tee /tmp/wattline-m3-task14-network-green.log
swift test --package-path peakdo/apple/WattlineNetwork 2>&1 | tee /tmp/wattline-m3-task14-network.log
```

Add app tests:

```swift
func testRotateStagesReturnedPinWithoutReplacingActivePinAndShowsRestart() async throws {
    let harness = try await makeTLSHarness(active: activePin, rotate: stagedPin)
    await harness.model.rotateTLS()
    XCTAssertEqual(harness.model.host?.certificateFingerprint, activePin.uppercased())
    XCTAssertEqual(harness.model.host?.stagedCertificateFingerprint, stagedPin.uppercased())
    XCTAssertTrue(harness.model.tlsRestartRequired)
}

func testRotationCompletionAfterEndpointReplacementDoesNotStageIntoNewHost() async throws {
    let harness = try await makeTLSHarness(active: activePin, rotate: stagedPin, gate: true)
    let rotate = Task { await harness.model.rotateTLS() }
    await harness.http.waitForGateRegistration()
    await harness.model.begin(host: replacementHost())
    harness.http.releaseGates(); await rotate.value
    XCTAssertNil(harness.model.host?.stagedCertificateFingerprint)
}

func testPromotionPublishesOnlyAtomicallyPromotedHost() async throws {
    let harness = try await makeTLSHarness(active: activePin, staged: stagedPin,
                                           promotionResult: promotedHost())
    await harness.model.promoteStagedTLSPin()
    XCTAssertEqual(harness.model.host?.certificateFingerprint, stagedPin.uppercased())
    XCTAssertNil(harness.model.host?.stagedCertificateFingerprint)
}
```

- [ ] **Step 5: Implement app staging/promotion wiring and destructive confirmation**

Expose narrow methods on `RouterConnectionModel` that call its existing `hostStore`/credential store and reload saved hosts; inject the promoter HTTP factory in its initializer with a production default. Do not expose tokens or construct a transport. Add generation-scoped `rotateTLS()` and `promoteStagedTLSPin()` to `RouterAdministrationModel`; capture the current host ID/session/request generation before awaiting and publish only if still current. A successful rotate first atomically stages through `RouterHostStore`, then replaces `model.host` with the returned persisted host. A failed or stale operation leaves prior state visible and reports a generic error.

In `RouterSettingsView`, show Rotate certificate only for HTTPS hosts and only in the administrator settings section. Use a destructive `confirmationDialog` whose message states that the current certificate remains active until `wattlined`/the router restarts. After a staged pin exists, show “Verify new certificate” as a separate action; do not auto-promote during ordinary reconnect and do not offer HTTP fallback.

- [ ] **Step 6: Run Task 14 GREEN suites and ABI/scope guards**

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination "platform=iOS Simulator,name=${WATTLINE_SIMULATOR_NAME}" CODE_SIGNING_ALLOWED=NO \
  -only-testing:WattlineTests/RouterAdministrationModelTests 2>&1 | tee /tmp/wattline-m3-task14-app-green.log
swift test --package-path peakdo/apple/WattlineUI
swift test --package-path peakdo/apple/WattlineNetwork
rg -n 'public init\(' peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterTransport.swift
rg -n 'func credential\(for endpoint: RouterEndpoint\)' peakdo/apple/WattlineNetwork/Sources/WattlineNetwork
git diff --check
```

Expected: all focused/affected tests pass; existing six-argument initializer and credential signature remain; no whitespace errors.

- [ ] **Step 7: Commit Task 14**

```bash
git add peakdo/apple/WattlineNetwork peakdo/apple/Wattline/Wattline/RouterConnectionModel.swift \
  peakdo/apple/Wattline/Wattline/RouterAdministration \
  peakdo/apple/Wattline/WattlineTests/RouterAdministrationModelTests.swift
git commit -m "feat: rotate router TLS pins safely"
```

---

### Task 15: Milestone 3 verification, audit, and handoff

**Files:**
- Create ignored evidence: `.superpowers/sdd/router-admin-m3-task-15-*.log`
- Do not change production merely to satisfy an overbroad textual grep; classify documented negative-test/doc matches semantically.

**Interfaces:**
- Consumes: Tasks 12–14 and approved M1/M2 code.
- Produces: no feature surface; only fresh evidence and the Milestone 3 handoff. Milestone 4 must remain absent.

- [ ] **Step 1: Run every required suite and generic build with unabridged logs**

```bash
cd /Users/keith/.codex/worktrees/wattline-phase-2
mkdir -p .superpowers/sdd
swift test --package-path peakdo/apple/WattlineCore 2>&1 | tee .superpowers/sdd/router-admin-m3-task-15-core.log
swift test --package-path peakdo/apple/WattlineUI 2>&1 | tee .superpowers/sdd/router-admin-m3-task-15-ui.log
swift test --package-path peakdo/apple/WattlineNetwork 2>&1 | tee .superpowers/sdd/router-admin-m3-task-15-network.log
WATTLINE_SIMULATOR_NAME=${WATTLINE_SIMULATOR_NAME:-Wattline-Tests-2}
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination "platform=iOS Simulator,name=${WATTLINE_SIMULATOR_NAME}" CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee .superpowers/sdd/router-admin-m3-task-15-ios.log
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineWidgets \
  -destination "platform=iOS Simulator,name=${WATTLINE_SIMULATOR_NAME}" CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee .superpowers/sdd/router-admin-m3-task-15-widgets.log
xcodebuild build -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee .superpowers/sdd/router-admin-m3-task-15-build.log
```

Record every pipeline exit with `PIPESTATUS[1]`/zsh `pipestatus[1]` or run under `set -o pipefail`. Core must remain exactly 156. UI, Network, app, and widget counts may increase only by M3 tests. Zero failures/skips/expected failures are required.

- [ ] **Step 2: Extract authoritative simulator identity and counts**

Use the generated `.xcresult` paths printed by both test invocations:

```bash
xcrun xcresulttool get test-results summary --path '<Wattline.xcresult>' --format json
xcrun xcresulttool get test-results summary --path '<WattlineWidgets.xcresult>' --format json
xcrun simctl list devices available | rg "${WATTLINE_SIMULATOR_NAME}"
xcodebuild -version
swift --version
```

Record `totalTestCount`, passed, failed, skipped, device name/model, OS/build, architecture, and UDID. Do not infer counts from “TEST SUCCEEDED.”

- [ ] **Step 3: Run the prescribed boundary/secret/scope audits verbatim with exit codes**

```bash
set +e
rg -n 'URLSession|NWBrowser|NWConnection|import Network|import Security' \
  peakdo/apple/WattlineCore/Sources peakdo/apple/WattlineUI/Sources
echo "boundary_exit=$?"
rg -n 'import WattlineNetwork' peakdo/apple/WattlineUI/Sources
echo "ui_network_import_exit=$?"
rg -n 'print\(|debugPrint\(|dump\(|Logger|os_log|NSLog' \
  peakdo/apple/WattlineNetwork/Sources peakdo/apple/Wattline/Wattline
echo "logging_exit=$?"
rg -n -i 'UserDefaults.{0,120}(token|pin)|(token|pin).{0,120}UserDefaults' \
  peakdo/apple/WattlineNetwork/Sources peakdo/apple/Wattline/Wattline
echo "userdefaults_secret_exit=$?"
rg -n '/device/action|/device/usbc-limit|/device/bypass-threshold|/device/schedules' \
  peakdo/apple/WattlineCore/Sources peakdo/apple/WattlineUI/Sources \
  peakdo/apple/WattlineNetwork/Sources peakdo/apple/Wattline/Wattline
echo "deprecated_routes_exit=$?"
rg -n 'api/v1/(pairing/|rules|device/advanced|device/ota)' \
  peakdo/apple/WattlineNetwork/Sources peakdo/apple/Wattline/Wattline
echo "m4_m5_scope_exit=$?"
git diff --check
echo "diff_check_exit=$?"
git status --short
echo "status_exit=$?"
```

Expected: all six `rg` commands exit 1 with no production matches; diff check/status exit 0 and clean. Also run:

```bash
rg -n 'WattlineNetwork' peakdo/apple/WattlineUI/Package.swift
git diff 75016b27 -- peakdo/Wattline-SPEC.md peakdo/API.md peakdo/src peakdo/scan.py peakdo/verify.py
git -C /Users/keith/src/openwrt-wattline status --short
```

Expected: no UI dependency, no contract/OEM diff, and the external router repository is untouched by this work (report any pre-existing external status rather than modifying it).

- [ ] **Step 4: Perform a whole-milestone self-review and mutation checks**

- Temporarily mutate one sparse-patch comparison so an unchanged nested field encodes; confirm a Task 12/13 test fails, then restore and rerun GREEN.
- Temporarily allow uppercase rotation hex or promote without device-ID comparison; confirm a Task 14 test fails, then restore and rerun GREEN.
- Inspect `git diff 75016b27` for secret interpolation, dual-pin trust, optimistic model assignment, transport construction, and M4/M5 routes.
- Run `git diff --check` again after restoration.

- [ ] **Step 5: Prepare the handoff and stop**

Report:

- Step 0 plan commit and exact Task 12–14 commits/fix waves;
- actual RED and GREEN command excerpts for each task;
- exact Core/UI/Network/iOS/widget counts and simulator identity from `.xcresult`;
- full audit transcript with exit codes;
- every deviation from this detailed plan, including compile-driven interface adjustments and why they were the smallest correct change;
- external checks unit tests cannot prove: a live settings save plus daemon/router restart, listener migration preserving a reachable endpoint, TLS rotation across restart with staged promotion and old-pin rejection, and token-store cutover closing managed SSE streams.

Do not begin Task 16 or any Milestone 4/5 surface. Stop and wait for review.

## Plan self-review

- **Contract coverage:** Every documented GET setting field is decoded; writable PUT fields have sparse nested patches; `tls.sha256` has no writable representation; empty mDNS interfaces are distinct; PUT readback and restart flag are complete; TLS rotate request/response and leaf-DER pin semantics are explicit.
- **Lifecycle coverage:** Settings and rotation operations use the existing privileged FIFO and generation/attachment guards. App state publishes only current complete readbacks. Host promotion is compare-and-swap actor persistence after staged-only identity verification.
- **Safety coverage:** Zero listeners, invalid ports/PIN, listener removal, insecure WAN HTTP, token-store cutover, no downgrade/TOFU, device mismatch, stale trial, and legacy metadata are tested.
- **Boundary coverage:** Core is unchanged; UI uses only local value types; Network owns URLSession/Security and persistence; no second transport owner exists.
- **Scope coverage:** No M4/M5 routes or UI are introduced.
- **Placeholder scan:** No TBD/TODO or omitted implementation body remains. Tests name exact observable behavior and expected RED causes.
- **Type consistency:** Task 12 Network DTOs map to Task 13 UI-local values; Task 14 consumes Task 12 admin methods and existing host/credential interfaces; app state names are consistent across model tests and view wiring.
