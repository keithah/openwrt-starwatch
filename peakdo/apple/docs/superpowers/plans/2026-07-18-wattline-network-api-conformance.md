# Wattline Network API Conformance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Wattline's app-used network transport conform exactly to the current canonical `wattlined` HTTP v1 API in `~/src/openwrt-wattline`.

**Architecture:** `WattlineNetwork` remains the sole networking/Security boundary. `RouterTransport` connects through canonical identity, telemetry, SSE, and granular-control routes; separate pure types validate Bonjour, QR, pairing, and error contracts before the app persists metadata and Keychain credentials.

**Tech Stack:** Swift 6, Swift Package Manager, Foundation/URLSession, Network.framework, Security/Keychain, XCTest, in-process fake HTTP+SSE fixtures.

## Global Constraints

- Treat `~/src/openwrt-wattline/docs/api.md`, `internal/api/routeDescriptors`, handlers, and tests as read-only wire authority.
- Do not edit `~/src/openwrt-wattline`, `peakdo/Wattline-SPEC.md`, `peakdo/API.md`, or `peakdo/src`.
- In scope: discovery, API-client enrollment, identity, telemetry/SSE, DC/USB-C/bypass, USB-C limits, clock, restart, and shutdown.
- Deferred: OTA, timers, rules, router settings, token administration, BLE-device pairing, TLS rotation, and expert controls.
- `WattlineCore` and `WattlineUI` must remain free of networking and Security imports.
- Preserve one transport owner, serialized operations, telemetry-is-truth, Type-C mode reconciliation, bypass's 10-second window, and disconnect-as-success.
- iOS 17+ and macOS 14+ floors; bundle identifiers and app group remain unchanged.
- Every production behavior starts with a non-vacuous failing test and is committed only after GREEN.

---

### Task 1: Canonical identity and typed API errors

**Files:**
- Modify: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterDTOs.swift`
- Modify: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterMapping.swift`
- Modify: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/NetworkError.swift`
- Modify: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/HTTPClient.swift`
- Modify: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterConnection.swift`
- Modify: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterMappingTests.swift`
- Modify: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterTransportConnectionTests.swift`
- Modify: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/HTTPAndSSEClientTests.swift`

**Interfaces:**
- Produces: `RouterDeviceDTO`, `RouterAPIFailureDTO`, `RouterAPIErrorCode`, and canonical `NetworkError.api(status:code:message:)`.
- Changes: connection bootstrap route from `/api/v1/status` to `/api/v1/device`.

- [x] **Step 1: Add exact failing identity and error tests**

Use the canonical router fixtures:

```swift
let deviceJSON = #"{"id":"DC:04:5A:EB:72:2B","model":"BP4SL3V2","hardware_revision":"V2","application_firmware":"1.4.9","ota_firmware":"1.0.3","cid":773,"features_raw":32767,"features":{},"available":{"current_time":true,"ota":true,"dc":true,"usbc":true},"mode":"ota","connection":{"connected":true,"phase":"bootloader","reconnect":"bootloader"},"commands":{"active":[],"recent":[]},"magic_dns_name":"wattline.example.ts.net"}"#
let failureJSON = #"{"error":{"code":"capability_unsupported","message":"Operation is not supported","details":{}}}"#
```

Assert that mapping preserves MAC, both firmware revisions, raw features, CID, and `.ota`; connection requests exactly `GET /api/v1/device`; `409` maps to `.api(status: 409, code: .capabilityUnsupported, message: "Operation is not supported")`; `401 unauthorized` retains the dedicated `.unauthorized` case; unknown additive reply fields decode successfully.

- [x] **Step 2: Run focused tests and verify RED**

Run:

```bash
swift test --package-path peakdo/apple/WattlineNetwork --filter 'RouterMappingTests|RouterTransportConnectionTests|HTTPAndSSEClientTests'
```

Expected: FAIL because `RouterDeviceDTO`, canonical route selection, OTA identity mapping, and canonical API-error decoding do not exist.

- [x] **Step 3: Implement the canonical DTO and error decoder**

Add focused wire types:

```swift
public struct RouterDeviceDTO: Decodable, Equatable, Sendable {
    public let id: String
    public let model: String
    public let hardwareRevision: String
    public let applicationFirmware: String
    public let otaFirmware: String
    public let cid: UInt16
    public let featuresRaw: UInt32
    public let mode: String
    public let available: RouterAvailabilityDTO
}

public enum RouterAPIErrorCode: String, Equatable, Sendable {
    case invalidRequest = "invalid_request"
    case invalidOrExpiredPIN = "invalid_or_expired_pin"
    case adminRequired = "admin_required"
    case advancedDisabled = "advanced_disabled"
    case capabilityUnsupported = "capability_unsupported"
    case operationInProgress = "operation_in_progress"
    case deviceDisconnected = "device_disconnected"
    case bleOperationFailed = "ble_operation_failed"
    case commandTimeout = "command_timeout"
    case notFound = "not_found"
    case internalError = "internal_error"
    case unknown
}
```

Decode the canonical envelope centrally from every non-2xx HTTP response. Preserve `.unauthorized` for code `unauthorized`; preserve unknown status/code/message without reflecting secrets. Change `RouterConnection.connect` to `GET /api/v1/device` and map `mode == "ota"` to `.ota`, otherwise require `"app"`.

- [x] **Step 4: Run focused tests and the Network suite GREEN**

```bash
swift test --package-path peakdo/apple/WattlineNetwork --filter 'RouterMappingTests|RouterTransportConnectionTests|HTTPAndSSEClientTests'
swift test --package-path peakdo/apple/WattlineNetwork
```

Expected: all tests pass; existing `/status` assertions are migrated to `/device`.

- [x] **Step 5: Commit**

```bash
git add peakdo/apple/WattlineNetwork
git commit -m "fix: conform router identity and errors to canonical API"
```

### Task 2: Canonical controls, limits, and clock

**Files:**
- Modify: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterCommandMapper.swift`
- Modify: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterConnection.swift`
- Modify: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterTransport.swift`
- Modify: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterCapabilities.swift`
- Modify: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterCommandTests.swift`
- Modify: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterCapabilitiesTests.swift`

**Interfaces:**
- Consumes: Task 1 typed API failures.
- Produces: canonical `RouterRequest` mappings and working `synchronizeDeviceTime()` / `readDeviceTimeIfSupported()`.

- [x] **Step 1: Replace legacy-route expectations with failing canonical tests**

Assert exact requests:

```swift
XCTAssertEqual(dc, RouterRequest(method: "POST", path: "/api/v1/device/dc", body: json(["on": true]), confirmation: .telemetry(.dcEnabled(true), timeout: .seconds(3))))
XCTAssertEqual(typeC.path, "/api/v1/device/usbc/output")
XCTAssertEqual(bypass.path, "/api/v1/device/dc/bypass")
XCTAssertEqual(limitSet.method, "PUT")
XCTAssertEqual(limitSet.path, "/api/v1/device/usbc/limit/output")
XCTAssertEqual(limitClear.method, "DELETE")
XCTAssertEqual(restart.path, "/api/v1/device/restart")
XCTAssertEqual(shutdown.body, Data(#"{"confirm":true}"#.utf8))
```

Add execution tests proving boolean responses do not complete before SSE telemetry; Type-C matches `mode`; bypass waits 10 seconds; limit PUT/DELETE responses are converted directly from `{"type":"output","level":4,"watts":100}`; runtime mutation remains unsupported; clock `available:false` returns nil; clock sync sends a zero-byte body; restart/shutdown preserve disconnect behavior. Assert no request path equals `/device/action`, `/device/usbc-limit`, `/device/bypass-threshold`, or `/device/schedules`.

- [x] **Step 2: Run command tests and verify RED**

```bash
swift test --package-path peakdo/apple/WattlineNetwork --filter 'RouterCommandMapperTests|RouterCommandExecutionTests|RouterCapabilitiesTests'
```

Expected: FAIL on legacy method/path/body behavior and unsupported clock methods.

- [x] **Step 3: Implement minimal canonical mapping and execution**

Use path-specific JSON bodies and per-type limit replies. Remove schedule and bypass-threshold endpoints from `RouterEndpointCapability` and supported surfaces for this pass. Implement:

```swift
func synchronizeDeviceTime() async throws {
    try await transactions.enqueue { [connection] in
        try await connection.executeBodyless("POST", "/api/v1/device/clock/sync")
    }
}

func readDeviceTimeIfSupported() async throws -> Date? {
    try await transactions.enqueue { [connection] in
        try await connection.readDeviceTime()
    }
}
```

Clock decoding accepts exactly `available`, nullable `device_time`, `system_time`, and nullable `drift_seconds`. A paired-client transport profile does not advertise clock controls; an explicitly configured administrator profile may call them.

- [x] **Step 4: Run command tests and all Network tests GREEN**

```bash
swift test --package-path peakdo/apple/WattlineNetwork --filter 'RouterCommandMapperTests|RouterCommandExecutionTests|RouterCapabilitiesTests'
swift test --package-path peakdo/apple/WattlineNetwork
```

- [x] **Step 5: Commit**

```bash
git add peakdo/apple/WattlineNetwork
git commit -m "fix: use canonical wattlined control routes"
```

### Task 3: Exact Bonjour and endpoint contract

**Files:**
- Modify: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterDiscovery.swift`
- Modify: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterHostStore.swift`
- Modify: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/DiscoveryAndCredentialsTests.swift`

**Interfaces:**
- Produces: validated `DiscoveredRouter.endpoint`, exact v1 TXT parsing, and daemon default ports.

- [x] **Step 1: Write failing contract tests**

Create records containing resolved host and port plus exact TXT keys:

```swift
RouterServiceRecord(
    serviceName: "Wattline",
    domain: "local.",
    host: "wattline.local.",
    port: 8378,
    txt: [
        "api": Data("1".utf8), "id": Data("DC:04:5A:EB:72:2B".utf8),
        "auth": Data("pin".utf8), "tls": Data(fingerprint.lowercased().utf8),
        "cid": Data("0305".utf8), "features": Data("00000fff".utf8)
    ]
)
```

Assert HTTPS and the normalized pin for 64-hex `tls`; HTTP for `tls=none`; invalid `api`, `auth`, MAC, CID, feature mask, fingerprint, missing resolved authority, and obsolete `fingerprint`-only records are rejected; duplicates merge by normalized MAC. Assert `router.lan` → HTTP 8377, `https://router.lan` → 8378, and explicit ports remain unchanged.

- [x] **Step 2: Run discovery tests and verify RED**

```bash
swift test --package-path peakdo/apple/WattlineNetwork --filter 'RouterDiscoveryTests|RouterHostStoreTests'
```

Expected: FAIL because records lack resolved authority, read the obsolete key, and default to 80/443.

- [x] **Step 3: Implement strict TXT parsing and router defaults**

Extend `RouterServiceRecord` with `host` and `port`. Extend `DiscoveredRouter` with `model`, `cid`, `features`, and `endpoint`. Parse only `api=1`, `auth=pin`, and `tls`; normalize a valid pin or recognize literal `none`. Update the Network.framework source to resolve services before publishing records and cancel superseded resolution work. Change manual defaults to 8377/8378 while preserving explicit ports.

- [x] **Step 4: Run focused and full Network tests GREEN**

```bash
swift test --package-path peakdo/apple/WattlineNetwork --filter 'RouterDiscoveryTests|RouterHostStoreTests'
swift test --package-path peakdo/apple/WattlineNetwork
```

- [x] **Step 5: Commit**

```bash
git add peakdo/apple/WattlineNetwork
git commit -m "fix: match wattlined discovery and default ports"
```

### Task 4: PIN enrollment and QR parsing

**Files:**
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterEnrollment.swift`
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterPairingPayload.swift`
- Create: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterEnrollmentTests.swift`
- Modify: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/HTTPClient.swift`
- Modify: `peakdo/apple/Wattline/Wattline/RouterConnectionModel.swift`
- Modify: `peakdo/apple/Wattline/WattlineTests/RouterAppWiringTests.swift`

**Interfaces:**
- Produces: `RouterPairingPayload.parse(_:)`, `RouterEnrollmentClient.enroll(pin:label:expectedDeviceID:expectedFingerprint:)`, and atomic `RouterConnectionModel.enroll(...)`.

- [x] **Step 1: Add failing pure and fake-HTTP tests**

Test the documented QR:

```swift
let url = URL(string: "wattline://pair?v=1&id=DC%3A04%3A5A%3AEB%3A72%3A2B&host=wattline.lan&http=8377&https=8378&pin=123456&tls=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")!
let payload = try RouterPairingPayload.parse(url)
XCTAssertEqual(payload.deviceID, "DC045AEB722B")
XCTAssertEqual(payload.pin, "123456")
```

Reject wrong scheme, version, missing required fields, malformed six-digit PIN, invalid port/MAC/pin, duplicate required query keys, and TLS without HTTPS. For enrollment, assert exact unauthenticated `POST /api/v1/pair`, JSON body, required 201, response correlation, TLS-pin match, `.invalidOrExpiredPIN` mapping, no Authorization header, and token redaction. App-level tests assert token-save then host-save, rollback deletes the token on metadata failure, and no write occurs when validation fails.

- [x] **Step 2: Run focused tests and verify RED**

```bash
swift test --package-path peakdo/apple/WattlineNetwork --filter RouterEnrollmentTests
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination 'platform=iOS Simulator,name=Wattline-Tests-2' CODE_SIGNING_ALLOWED=NO -only-testing:WattlineTests/RouterAppWiringTests
```

Expected: FAIL because pairing/QR types and unauthenticated HTTP support do not exist.

- [x] **Step 3: Implement pairing without secret leakage**

Add a dedicated unauthenticated request seam:

```swift
public protocol RouterEnrollmentHTTPClient: Sendable {
    func publicRequest(_ method: String, _ path: String, body: Data?) async throws -> (Data, HTTPURLResponse)
}
```

Have `HTTPClient` conform without adding Authorization. Decode the exact 201 response, validate device/pin/base URL correlation, and return a result that holds the secret only in memory with redacted descriptions. `RouterConnectionModel.enroll` saves Keychain first and host metadata second, deleting the Keychain entry if metadata persistence fails.

- [x] **Step 4: Run focused, Network, and app tests GREEN**

```bash
swift test --package-path peakdo/apple/WattlineNetwork --filter RouterEnrollmentTests
swift test --package-path peakdo/apple/WattlineNetwork
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination 'platform=iOS Simulator,name=Wattline-Tests-2' CODE_SIGNING_ALLOWED=NO -only-testing:WattlineTests/RouterAppWiringTests
```

- [x] **Step 5: Commit**

```bash
git add peakdo/apple/WattlineNetwork peakdo/apple/Wattline/Wattline/RouterConnectionModel.swift peakdo/apple/Wattline/WattlineTests/RouterAppWiringTests.swift
git commit -m "feat: add wattlined PIN enrollment contract"
```

### Task 5: App capability wiring, stale-doc correction, and full verification

**Files:**
- Modify: `peakdo/apple/Wattline/Wattline/AppModel.swift`
- Modify: `peakdo/apple/Wattline/Wattline/RouterConnectionModel.swift`
- Modify: `peakdo/apple/Wattline/WattlineTests/RouterAppWiringTests.swift`
- Modify: `peakdo/apple/docs/superpowers/specs/2026-07-17-wattline-network-design.md`
- Modify: `peakdo/apple/docs/superpowers/plans/2026-07-17-wattline-network.md`

**Interfaces:**
- Consumes: canonical endpoint profile and identity from Tasks 1–4.
- Produces: structurally correct router capability gating and accurate historical planning documentation.

- [x] **Step 1: Add failing app wiring and source-audit tests**

Assert the default router profile exposes ordinary granular actions and limits but not schedules, bypass threshold, OTA, or administrator clock controls. Feed an identity with all feature bits and prove unsupported/deferred features are removed from `DeviceCapabilities`. Add a source assertion that app-used production strings contain canonical routes and do not contain the four deprecated route strings.

- [x] **Step 2: Run focused tests and verify RED**

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination 'platform=iOS Simulator,name=Wattline-Tests-2' CODE_SIGNING_ALLOWED=NO -only-testing:WattlineTests/RouterAppWiringTests
```

Expected: FAIL because `connectViaRouter` defaults to every historical endpoint capability.

- [x] **Step 3: Implement the production profile and correct stale docs**

Replace `Set(RouterEndpointCapability.allCases)` with a named canonical client profile. Ensure capability gating removes deferred schedules and administrator-only controls structurally. Update the 2026-07-17 network design/plan to point at the 2026-07-18 conformance spec and mark compatibility-route/PIN/TXT descriptions as superseded rather than leaving false statements as current guidance.

- [x] **Step 4: Run complete verification**

```bash
swift test --package-path peakdo/apple/WattlineCore
swift test --package-path peakdo/apple/WattlineUI
swift test --package-path peakdo/apple/WattlineNetwork
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination 'platform=iOS Simulator,name=Wattline-Tests-2' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineWidgets -destination 'platform=iOS Simulator,name=Wattline-Tests-2' CODE_SIGNING_ALLOWED=NO
rg -n 'URLSession|NWBrowser|NWConnection|import Network|import Security' peakdo/apple/WattlineCore/Sources peakdo/apple/WattlineUI/Sources
rg -n '/api/v1/device/action|/api/v1/device/usbc-limit|/api/v1/device/bypass-threshold|/api/v1/device/schedules' peakdo/apple/WattlineNetwork/Sources
git diff --check
```

Expected: every suite passes; both audits return no forbidden matches. Real router/Bonjour/QR/TLS/VPN/physical-command checks are reported as external.

- [x] **Step 5: Commit**

```bash
git add peakdo/apple/Wattline peakdo/apple/docs/superpowers
git commit -m "fix: finish canonical router API wiring"
```

