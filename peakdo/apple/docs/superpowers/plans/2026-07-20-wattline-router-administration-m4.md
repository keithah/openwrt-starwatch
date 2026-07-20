# Wattline Router Administration Milestone 4 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use `superpowers:subagent-driven-development` (preferred) or `superpowers:executing-plans`. Execute Tasks 16–19 in order, RED→GREEN, and stop before Milestone 5.

**Goal:** Pair the router with Link-Power through the documented client-role BlueZ API, add exact administrator/advanced device controls, and expose only structurally supported controls with authoritative readback.

**Architecture:** `WattlineNetwork` owns an HTTP-only client-token pairing actor and advanced extensions on the existing administrator actor. Pairing polling reuses `RouterConnectionClock`; no second clock or BLE stack is added. `WattlineUI` owns Foundation-only values/policies. The iOS administration model maps DTOs, owns request/session generations, and publishes only current authoritative results.

**Approved base:** `d983528a`.

## Binding constraints

- Contract: `/Users/keith/src/openwrt-wattline/docs/api.md`. Never edit it, `peakdo/Wattline-SPEC.md`, `peakdo/API.md`, `peakdo/src/*`, `scan.py`, or `verify*.py`.
- Scope is Tasks 16–19 only. No rules, macOS, Demo fixtures, OTA, firmware transfer, Timers, App Intents, or notification work.
- Pairing uses the managed **client** token. Advanced controls use the **administrator** token and existing privileged-mutation FIFO.
- One BLE owner per process. Pairing/administration code performs HTTP only and never constructs `BLETransport`, `DeviceSession`, or `DeviceOperationBroker`; do not widen `DeviceCommand`.
- Core remains unchanged. UI has no Network/Security import and no `WattlineNetwork` dependency.
- No PIN/token/private key in logs, errors, descriptions, reflection, snapshots, UserDefaults, or persistence. Empty pairing PIN is sent explicitly as `"pin":""`; advanced BLE PIN is exactly six ASCII digits and is never echoed.
- Router response/readback is truth. Threshold/barrier publish decoded response only. Running mode/BLE PIN never optimistically publish submitted values.
- Reuse existing `RouterConnectionClock.now/sleep` and existing `RouterConnection` `/device/clock` decode. No duplicate clock path or transaction owner.
- Strict TDD: non-vacuous RED, minimal GREEN, full affected suites, exact requested commit per task.

## Grounded interfaces at the approved base

```swift
public protocol RouterConnectionClock: Sendable {
    var now: DeviceTimestamp { get async }
    func sampleTimestampOrigin() async -> RouterTimestampOrigin
    func sleep(for duration: Duration) async throws
}
public actor RouterAdministrationClient {
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
}
@MainActor @Observable final class RouterAdministrationModel {
    private var sessionGeneration: UInt64
    private var adminOperationGeneration: UInt64
    private func performAdmin<Value>(
        _ operation: (RouterAdministrationClient) async throws -> Value,
        isCurrent: () -> Bool = { true }
    ) async -> AdminResult<Value>
    private func handleAdminFailure(_ error: Error) -> Bool
}
```

Existing `RouterTransport.synchronizeDeviceTime`, `readDeviceTimeIfSupported`, and `RouterConnection.readDeviceTime/executeBodyless` remain authoritative.

---

### Task 16: Pair Link-Power through the router

**Files**
- Create `WattlineNetwork/Sources/WattlineNetwork/RouterDevicePairing.swift`
- Create `WattlineNetwork/Tests/WattlineNetworkTests/RouterDevicePairingTests.swift`
- Create `WattlineUI/Sources/WattlineUI/RouterDevicePairingPresentation.swift`
- Create `WattlineUI/Tests/WattlineUITests/RouterDevicePairingPresentationTests.swift`
- Create `Wattline/Wattline/RouterAdministration/RouterDevicePairingView.swift`
- Modify `RouterAdministrationModel.swift`, `RouterAdministrationView.swift`, and app model tests

**Produces:** an HTTP-only `RouterDevicePairingClient` sharing `RouterCredentialStore` and `RouterConnectionClock`; status/progress values; model scan/pair/unpair state.

- [ ] Write Network RED tests with `ScriptedRouterHTTPClient` and deterministic `RouterConnectionClock`:

```swift
func testStatusDecodesDocumentedFixture() async throws {
    let f = try await fixture([.ok(#"{"stage":"idle","devices":[{"mac":"DC:04:5A:EB:72:2B","name":"Link-Power-2","rssi":-60,"paired":false}]}"#)])
    let value = try await f.client.status()
    XCTAssertEqual(value.stage, .idle)
    XCTAssertEqual(value.devices.first, .init(mac: "DC:04:5A:EB:72:2B", name: "Link-Power-2", rssi: -60, paired: false))
    XCTAssertEqual(f.http.calls.map(\.path), ["/api/v1/pairing/status"])
    XCTAssertNil(f.http.calls[0].body)
}
func testScanUsesBodyless202ThenBoundedPollToTerminal() async throws {
    let f = try await fixture([
        .ok(#"{"stage":"idle","devices":[]}"#),
        .response(status: 202, #"{"status":"scanning"}"#),
        .ok(#"{"stage":"scanning","devices":[]}"#),
        .ok(#"{"stage":"idle","devices":[]}"#),
    ])
    XCTAssertEqual(try await f.client.scan(timeout: .seconds(10)) { _ in }.stage, .idle)
    XCTAssertEqual(f.http.calls.map { ($0.method, $0.path) }, [
        ("GET", "/api/v1/pairing/status"), ("POST", "/api/v1/pairing/scan"),
        ("GET", "/api/v1/pairing/status"), ("GET", "/api/v1/pairing/status"),
    ])
    XCTAssertNil(f.http.calls[1].body)
}
func testAlreadyScanningDoesNotStartSecondOperation() async throws {
    let f = try await fixture([.ok(#"{"stage":"scanning","devices":[]}"#), .ok(#"{"stage":"idle","devices":[]}"#)])
    _ = try await f.client.scan(timeout: .seconds(10)) { _ in }
    XCTAssertFalse(f.http.calls.contains { $0.method == "POST" })
}
func testPairNormalizesMACAndPreservesEmptyPIN() async throws {
    let f = try await fixture([
        .ok(#"{"stage":"idle","devices":[]}"#),
        .response(status: 202, #"{"status":"pairing"}"#),
        .ok(#"{"stage":"idle","target":"DC:04:5A:EB:72:2B","devices":[]}"#),
    ])
    _ = try await f.client.pair(mac: "dc-04-5a-eb-72-2b", pin: "", timeout: .seconds(10)) { _ in }
    XCTAssertEqual(try json(f.http.calls[1].body), ["mac":"DC:04:5A:EB:72:2B", "pin":""])
}
func testUnpairHasNoBodyAndRefetchesStatus() async throws {
    let f = try await fixture([.response(status: 200, #"{"status":"removed"}"#), .ok(#"{"stage":"idle","devices":[]}"#)])
    XCTAssertEqual(try await f.client.unpair(mac: "dc:04:5a:eb:72:2b").devices, [])
    XCTAssertEqual(f.http.calls[0].path, "/api/v1/pairing/device/DC%3A04%3A5A%3AEB%3A72%3A2B")
    XCTAssertNil(f.http.calls[0].body)
}
func testTimeoutCancellationReplacementAndClientRole() async throws {
    // Clock advances only through injected sleep: impossible terminal status -> NetworkError.timeout.
    // Gate a poll, attach replacement, release -> CancellationError and no progress publication.
    // Save both roles; assert every pairing call token == client-token and never admin-token.
}
```

Also test malformed status, async `error`, invalid MAC, empty/1–6 router-contract PIN validation, non-ASCII digits, `URLError.cancelled -> CancellationError`, and `409 operation_in_progress` continuing current polling without another POST.

- [ ] RED:

```bash
swift test --package-path peakdo/apple/WattlineNetwork --filter RouterDevicePairingTests 2>&1 | tee /tmp/wattline-m4-task16-network-red.log
```

Expected: missing pairing actor/types, not a fixture syntax failure.

- [ ] Implement these complete interface shapes:

```swift
public enum RouterPairingStage: String, Codable, Sendable { case idle, scanning, pairing }
public struct RouterPairingDevice: Codable, Equatable, Sendable {
    public let mac: String; public let name: String; public let rssi: Int; public let paired: Bool
}
public struct RouterDevicePairingStatus: Codable, Equatable, Sendable {
    public let stage: RouterPairingStage
    public let devices: [RouterPairingDevice]
    public let error: String?
    public let target: String?
}
public actor RouterDevicePairingClient {
    public typealias HTTPFactory = @Sendable (RouterEndpoint) throws -> any RouterHTTPClient
    public typealias Progress = @Sendable (RouterDevicePairingStatus) async -> Void
    public init(credentials: RouterCredentialStore, clock: any RouterConnectionClock,
                pollInterval: Duration = .milliseconds(250), httpFactory: @escaping HTTPFactory)
    public func attach(endpoint: RouterEndpoint) throws
    public func detach()
    public func status() async throws -> RouterDevicePairingStatus
    public func scan(timeout: Duration, progress: @escaping Progress) async throws -> RouterDevicePairingStatus
    public func pair(mac: String, pin: String, timeout: Duration,
                     progress: @escaping Progress) async throws -> RouterDevicePairingStatus
    public func unpair(mac: String) async throws -> RouterDevicePairingStatus
}
```

Implementation requirements:
1. `attach/detach` increment generation before replacing HTTP context.
2. A Boolean operation lease permits exactly one scan/pair/unpair; actor reentrancy cannot dispatch a second operation.
3. Initial GET: if already scanning/pairing, poll it and do not POST. Treat `409 operation_in_progress` from start as current activity and poll.
4. Use `clock.now` and `clock.sleep`; elapsed >= injected timeout throws `.timeout`. Check Task cancellation and generation before/after every await/publication.
5. All requests read `.client` token. Exact success statuses: status 200, scan/pair 202, unpair 200. Convert URL cancellation. Error strings published to UI are generic/redacted.
6. Normalize MAC to uppercase colon form; unpair uses strict RFC3986 path-segment percent encoding. Pair JSON always contains both `mac` and `pin`, including empty PIN.
7. Unpair re-GETs status before returning.

- [ ] Write UI/app RED tests:

```swift
func testPresentationSortsPairedThenRSSIAndNeverCarriesPIN()
func testStageTargetDeviceAndAsyncErrorPresentation()
func testProgressFromReplacedHostIsIgnored()
func testOperationInProgressDoesNotEnableSecondAction()
func testUnpairPublishesOnlyAuthoritativeRefetch()
func testViewClearsLocalPINBeforeAwaitAndModelHasNoPINProperty()
```

- [ ] Implement Foundation-only UI types:

```swift
public enum RouterDevicePairingStageValue: Equatable, Sendable { case idle, scanning, pairing }
public struct RouterDevicePairingDeviceValue: Equatable, Sendable, Identifiable {
    public var id: String { mac }
    public let mac: String; public let name: String; public let rssi: Int; public let paired: Bool
}
public struct RouterDevicePairingStatusValue: Equatable, Sendable {
    public let stage: RouterDevicePairingStageValue; public let target: String?
    public let devices: [RouterDevicePairingDeviceValue]; public let error: String?
}
public struct RouterDevicePairingPresentation: Equatable, Sendable {
    public let stageLabel: String; public let devices: [RouterDevicePairingDeviceValue]; public let error: String?
    public init(status: RouterDevicePairingStatusValue) {
        stageLabel = switch status.stage { case .idle: "Idle"; case .scanning: "Scanning…"; case .pairing: "Pairing…" }
        devices = status.devices.sorted { $0.paired != $1.paired ? $0.paired : $0.rssi > $1.rssi }
        error = status.error
    }
}
```

Inject/attach the pairing actor in `RouterAdministrationModel.production/beginSession`; detach and increment `devicePairingGeneration` on end/replacement. Each progress/final publication checks session, operation generation, request generation, endpoint, and cancellation. `RouterDevicePairingView` owns the secure PIN field, copies then clears it synchronously before dispatch. It displays stage/target/devices/RSSI/paired/error and structurally removes conflicting actions while busy.

- [ ] GREEN and commit:

```bash
swift test --package-path peakdo/apple/WattlineNetwork --filter RouterDevicePairingTests
swift test --package-path peakdo/apple/WattlineUI --filter RouterDevicePairingPresentationTests
swift test --package-path peakdo/apple/WattlineNetwork
swift test --package-path peakdo/apple/WattlineUI
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination "platform=iOS Simulator,name=${WATTLINE_SIMULATOR_NAME:-Wattline-Tests-2}" CODE_SIGNING_ALLOWED=NO
git diff --check
git add peakdo/apple/WattlineNetwork peakdo/apple/WattlineUI peakdo/apple/Wattline/Wattline/RouterAdministration peakdo/apple/Wattline/WattlineTests/RouterAdministrationModelTests.swift
git commit -m "feat: pair Link-Power through router"
```

---

### Task 17: Exact advanced device APIs

**Files**
- Create `WattlineNetwork/Sources/WattlineNetwork/RouterAdvancedControls.swift`
- Create `WattlineNetwork/Tests/WattlineNetworkTests/RouterAdvancedControlsTests.swift`
- Reuse/minimally modify `RouterConnection.swift` only to share the clock response decoder

**Produces:** typed threshold/clock/running-mode/barrier/USB-firmware/BLE-PIN results and allow-listed administrator methods. No `DeviceCommand` additions.

- [ ] Write RED tests:

```swift
func testBypassUsesCanonicalGETPUTAndPublishesObservedResponse() async throws {
    let f = try await fixture([.ok(#"{"volts":19.6}"#), .ok(#"{"volts":19.5}"#)])
    XCTAssertEqual(try await f.client.bypassThreshold().volts, 19.6)
    XCTAssertEqual(try await f.client.setBypassThreshold(volts: 19.6).volts, 19.5)
    XCTAssertEqual(f.http.calls.map { ($0.method,$0.path) }, [
        ("GET","/api/v1/device/dc/bypass/threshold"),
        ("PUT","/api/v1/device/dc/bypass/threshold"),
    ])
}
func testClockUnavailableAvailableAndBodylessSync() async throws {
    let f = try await fixture([
        .ok(#"{"available":false,"device_time":null,"system_time":"2026-07-17T20:00:02Z","drift_seconds":null}"#),
        .ok(#"{"available":true,"device_time":"2026-07-17T20:00:00Z","system_time":"2026-07-17T20:00:02Z","drift_seconds":-2}"#),
        .ok(#"{"synced":true,"system_time":"2026-07-17T20:00:02Z"}"#),
    ])
    XCTAssertFalse(try await f.client.deviceClock().available)
    XCTAssertEqual(try await f.client.deviceClock().driftSeconds, -2)
    XCTAssertTrue(try await f.client.syncDeviceClock().synced)
    XCTAssertNil(f.http.calls[2].body)
}
func testRunningModePUTOnlyUnsignedAndExactBody()
func testBarrierPUTPublishesObservedFalseWhenRequestedTrue()
func testUSBFirmwareDecodesRawMajorMinorPatch()
func testBLEPINRequiresSixASCIIDigitsAndResultNeverEchoesPIN()
func testAdvancedDisabledAndCapabilityUnsupportedPropagatePrecisely()
func testReplacementCancelsLateCompletionAndAllRequestsUseAdminToken()
func testAdvancedIdentityDecodesCompleteDocumentedDeviceFixture()
```

RED:

```bash
swift test --package-path peakdo/apple/WattlineNetwork --filter RouterAdvancedControlsTests 2>&1 | tee /tmp/wattline-m4-task17-red.log
```

- [ ] Implement:

```swift
public struct RouterBypassThreshold: Codable, Equatable, Sendable { public let volts: Double }
public struct RouterDeviceClockStatus: Codable, Equatable, Sendable {
    public let available: Bool; public let deviceTime: String?; public let systemTime: String
    public let driftSeconds: Int?
    enum CodingKeys: String, CodingKey {
        case available; case deviceTime = "device_time"; case systemTime = "system_time"
        case driftSeconds = "drift_seconds"
    }
}
public struct RouterClockSyncResult: Codable, Equatable, Sendable {
    public let synced: Bool; public let systemTime: String
    enum CodingKeys: String, CodingKey { case synced; case systemTime = "system_time" }
}
public struct RouterRunningModeResult: Codable, Equatable, Sendable { public let mode: UInt8 }
public struct RouterBarrierFreeResult: Codable, Equatable, Sendable { public let enabled: Bool }
public struct RouterUSBFirmwareVersion: Codable, Equatable, Sendable {
    public let raw: String; public let major: UInt8; public let minor: UInt8; public let patch: UInt8
}
public struct RouterBLEPINUpdateResult: Codable, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let updated: Bool
    public var description: String { "RouterBLEPINUpdateResult(updated: \(updated))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["updated": updated]) }
}
extension RouterAdministrationClient {
    public func advancedIdentity() async throws -> RouterDeviceDTO
    public func bypassThreshold() async throws -> RouterBypassThreshold
    public func setBypassThreshold(volts: Double) async throws -> RouterBypassThreshold
    public func deviceClock() async throws -> RouterDeviceClockStatus
    public func syncDeviceClock() async throws -> RouterClockSyncResult
    public func setRunningMode(_ mode: UInt8) async throws -> RouterRunningModeResult
    public func barrierFree() async throws -> RouterBarrierFreeResult
    public func setBarrierFree(_ enabled: Bool) async throws -> RouterBarrierFreeResult
    public func usbFirmwareVersion() async throws -> RouterUSBFirmwareVersion
    public func setBLEPIN(_ pin: String) async throws -> RouterBLEPINUpdateResult
}
```

Use private concrete `Encodable` request structs (not `[String:Any]`). GET helper: lease → privileged FIFO only where mutation serialization requires it → `send` → validate → decode. Mutations: acquire existing privileged FIFO, validate before/after every await, exact sorted JSON, exact canonical routes. Validate volts finite and `0 < volts <= 60`; BLE PIN exactly six ASCII digits; require `updated == true`. Never include PIN/value in thrown text.

Reuse `RouterDeviceClockStatus` in `RouterConnection.readDeviceTime` (or share one internal decoder) while preserving existing `Date?` semantics, `available:false -> nil`, and existing `RouterCommandTests.testCanonicalClockReadUnavailableAndManualSync`. Do not add a clock, route, or transaction owner.

- [ ] GREEN and commit:

```bash
swift test --package-path peakdo/apple/WattlineNetwork --filter RouterAdvancedControlsTests
swift test --package-path peakdo/apple/WattlineNetwork --filter RouterCommandTests.testCanonicalClockReadUnavailableAndManualSync
swift test --package-path peakdo/apple/WattlineNetwork
git diff --check
git add peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterAdvancedControls.swift peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterConnection.swift peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterAdvancedControlsTests.swift
git commit -m "feat: add router advanced device controls"
```

---

### Task 18: Structurally gated advanced administration UI

**Files**
- Create `WattlineUI/Sources/WattlineUI/RouterAdvancedPresentation.swift`
- Create `WattlineUI/Tests/WattlineUITests/RouterAdvancedPresentationTests.swift`
- Create `Wattline/Wattline/RouterAdministration/RouterAdvancedView.swift`
- Modify real app path `Wattline/Wattline/RouterAdministration/RouterAdministrationModel.swift`, view, and app model tests

- [ ] Write UI RED tests:

```swift
func testEveryOuterGateMakesAllSurfacesAbsent() {
    // admin false; advanced false; OTA mode: each yields empty surfaces.
}
func testFeatureAndInventoryIntersectPerSurface() {
    // bypass requires dc + dcBypassControl; clock current_time; factory controls factoryMode;
    // USB firmware also requires USB availability.
}
func testCapabilityUnsupportedRemovesOnlyAffectedSurface()
func testAdvancedDisabledShowsEnableAffordanceAndNoControls()
func testRunningModeAndBLEPINRequirePurposeSpecificConfirmation()
```

Implement Foundation-only policy:

```swift
public enum RouterAdvancedSurface: String, CaseIterable, Hashable, Sendable {
    case bypassThreshold, clock, runningMode, barrierFree, usbFirmware, blePIN
}
public enum RouterAdvancedApplicationMode: Sendable { case application, ota }
public enum RouterAdvancedServerGate: Sendable { case allowed, advancedDisabled }
public struct RouterAdvancedVisibilityInput: Sendable {
    public let adminVerified: Bool; public let advanced: Bool
    public let mode: RouterAdvancedApplicationMode
    public let hasFactoryMode, hasBypassControl, currentTimeAvailable, dcAvailable, usbAvailable: Bool
    public let unsupported: Set<RouterAdvancedSurface>
    public let serverGate: RouterAdvancedServerGate
}
public struct RouterAdvancedVisibility: Equatable, Sendable {
    public let surfaces: Set<RouterAdvancedSurface>
    public let showsEnableAdvancedAffordance: Bool
    public static func evaluate(_ x: RouterAdvancedVisibilityInput) -> Self {
        guard x.adminVerified else { return .init(surfaces: [], showsEnableAdvancedAffordance: false) }
        guard x.advanced, x.serverGate == .allowed else {
            return .init(surfaces: [], showsEnableAdvancedAffordance: true)
        }
        guard x.mode == .application else { return .init(surfaces: [], showsEnableAdvancedAffordance: false) }
        var s: Set<RouterAdvancedSurface> = []
        if x.hasBypassControl && x.dcAvailable { s.insert(.bypassThreshold) }
        if x.currentTimeAvailable { s.insert(.clock) }
        if x.hasFactoryMode { s.formUnion([.runningMode, .barrierFree, .blePIN]) }
        if x.hasFactoryMode && x.usbAvailable { s.insert(.usbFirmware) }
        s.subtract(x.unsupported)
        return .init(surfaces: s, showsEnableAdvancedAffordance: false)
    }
}
public enum RouterAdvancedConfirmation: Equatable, Sendable {
    case runningMode, blePIN
    public static func required(for x: RouterAdvancedSurface) -> Self? {
        switch x { case .runningMode: .runningMode; case .blePIN: .blePIN; default: nil }
    }
}
```

Use additional UI-local value types for threshold/clock/mode/barrier/USB; no Network DTO imports.

- [ ] Add app RED tests:

```swift
func testAdvancedStateAppearsOnlyAfterAdminSettingsIdentityGates()
func testThresholdAndBarrierPublishOnlyObservedResponse()
func testAdvancedDisabledPublishesSettingsEditorAffordance()
func testCapabilityUnsupportedRemovesOnlyAffectedSurfaceAfterRefresh()
func testLateMutationAfterHostReplacementPublishesNothing()
func testBLEPINClearsBeforeAwaitAndIsNotRetainedOrReflected()
func testRunningModeAndBLEPINDoNotDispatchBeforeConfirmation()
```

RED commands:

```bash
swift test --package-path peakdo/apple/WattlineUI --filter RouterAdvancedPresentationTests 2>&1 | tee /tmp/wattline-m4-task18-ui-red.log
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination "platform=iOS Simulator,name=${WATTLINE_SIMULATOR_NAME:-Wattline-Tests-2}" CODE_SIGNING_ALLOWED=NO -only-testing:WattlineTests/RouterAdministrationModelTests 2>&1 | tee /tmp/wattline-m4-task18-app-red.log
```

- [ ] Implement model/view:
  1. Load `settings` plus `advancedIdentity()` only after verified admin. Derive application/OTA, feature bits, and availability. Publish only under session/admin/request/endpoint guards.
  2. Every action uses `performAdmin`; store only observed response values.
  3. `403 advanced_disabled`: clear controls and expose “Enable Advanced in Router Configuration”.
  4. `409 capability_unsupported`: mark only attempted surface unsupported, refresh authoritative identity/settings, recompute.
  5. Clear all advanced state on lock/end/replacement or advanced=false.
  6. `RouterAdvancedView` iterates only `visibility.surfaces`; absence is structural. Purpose-specific dialogs precede running mode/BLE PIN. BLE PIN lives only in a local `SecureField`, copied and cleared synchronously before await. USB firmware is read-only. Enable affordance goes to the existing M3 Advanced settings toggle, never fabricates settings.
  7. Because `RouterDeviceDTO.available` has no individual advanced bits, initial visibility uses documented feature/inventory proxies: threshold = `dc && dcBypassControl`; clock = `current_time`; running/barrier/PIN = application + factory feature; USB version adds USB availability. The server’s authoritative 409 then removes only the affected surface.

- [ ] GREEN and commit:

```bash
swift test --package-path peakdo/apple/WattlineUI --filter RouterAdvancedPresentationTests
swift test --package-path peakdo/apple/WattlineUI
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination "platform=iOS Simulator,name=${WATTLINE_SIMULATOR_NAME:-Wattline-Tests-2}" CODE_SIGNING_ALLOWED=NO
git diff --check
git add peakdo/apple/WattlineUI peakdo/apple/Wattline/Wattline/RouterAdministration peakdo/apple/Wattline/WattlineTests/RouterAdministrationModelTests.swift
git commit -m "feat: present router device administration"
```

---

### Task 19: Verification and handoff

- [ ] Run actual gates:

```bash
cd /Users/keith/.codex/worktrees/wattline-phase-2
swift test --package-path peakdo/apple/WattlineCore 2>&1 | tee /tmp/wattline-m4-core.log
swift test --package-path peakdo/apple/WattlineUI 2>&1 | tee /tmp/wattline-m4-ui.log
swift test --package-path peakdo/apple/WattlineNetwork 2>&1 | tee /tmp/wattline-m4-network.log
WATTLINE_SIMULATOR_NAME=${WATTLINE_SIMULATOR_NAME:-Wattline-Tests-2}
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination "platform=iOS Simulator,name=${WATTLINE_SIMULATOR_NAME}" CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/wattline-m4-ios.log
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineWidgets -destination "platform=iOS Simulator,name=${WATTLINE_SIMULATOR_NAME}" CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/wattline-m4-widgets.log
xcodebuild build -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/wattline-m4-build.log
```

Baselines: Core 156 (must remain exactly 156), UI 45, Network 185, iOS 276, Widgets 276. Report exact grown counts from xcresult, simulator identity, and zero failed/skipped/expected failures.

- [ ] Audits with exit codes:

```bash
rg -n 'URLSession|NWBrowser|NWConnection|import Network|import Security' peakdo/apple/WattlineCore/Sources peakdo/apple/WattlineUI/Sources; echo "boundary=$?"
rg -n 'import WattlineNetwork' peakdo/apple/WattlineUI/Sources; echo "ui_source_dependency=$?"
rg -n 'WattlineNetwork' peakdo/apple/WattlineUI/Package.swift; echo "ui_manifest_dependency=$?"
rg -n '/device/action|/device/usbc-limit|/device/bypass-threshold|/device/schedules' peakdo/apple/WattlineCore/Sources peakdo/apple/WattlineUI/Sources peakdo/apple/WattlineNetwork/Sources peakdo/apple/Wattline/Wattline; echo "deprecated_routes=$?"
rg -n 'BLETransport|DeviceSession\(|DeviceOperationBroker' peakdo/apple/WattlineNetwork/Sources peakdo/apple/Wattline/Wattline/RouterAdministration; echo "admin_ble_owner=$?"
rg -n 'api/v1/rules|api/v1/device/ota' peakdo/apple/WattlineNetwork/Sources peakdo/apple/Wattline/Wattline; echo "m5_scope=$?"
rg -n 'print\(|debugPrint\(|dump\(|Logger\(|os_log|NSLog' peakdo/apple/WattlineNetwork/Sources peakdo/apple/Wattline/Wattline; echo "logging=$?"
rg -n 'DeviceCommand' peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterDevicePairing.swift peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterAdvancedControls.swift; echo "device_command_widening=$?"
git diff --check d983528a..HEAD
git status --short
```

No-match audits should exit 1. Inspect semantic false positives rather than hiding them. Confirm `git diff --name-only d983528a..HEAD` has no contract/OEM/router/M5 edits.

- [ ] Handoff: commits, per-task actual RED/GREEN logs, exact suite counts, audit transcript, every deviation, and external checks unit tests cannot prove: physical BlueZ scan/pair/unpair; empty-PIN retention; real threshold/barrier readback; clock drift/sync and unavailable zero BLE I/O; running-mode/BLE-PIN hardware effect; live advanced-disabled vs capability-unsupported.

Stop after Task 19.

## Explicit deviations from the compressed master plan

1. Pairing is a separate HTTP-only **client-role** actor rather than an extension of the admin-token actor. This follows the normative role table and still creates no BLE owner.
2. The real app model path is `Wattline/Wattline/RouterAdministration/RouterAdministrationModel.swift`, not the master sketch’s nonexistent M5 `WattlineShared` path.
3. Clock GET/sync already exists. Task 17 shares/extracts its DTO decoder and adds admin-surface access without duplicating routes, clocks, or transaction ownership.
4. Network accepts the router contract’s empty or up-to-six-digit pairing PIN; UI accepts empty or exactly six digits to avoid ambiguous short user entries.
