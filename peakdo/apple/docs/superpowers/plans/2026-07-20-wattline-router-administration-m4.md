# Wattline Router Administration Milestone 4 Implementation Plan

> **Execution requirement:** Use `superpowers:subagent-driven-development` task by task. Each production behavior starts with a non-vacuous failing test, then the smallest implementation, a focused GREEN run, a task-wide GREEN run, review, and the exact commit named below.

**Goal:** Add HTTP-only router-to-Link-Power pairing and structurally gated advanced Link-Power administration without creating another BLE owner, widening `DeviceCommand`, or weakening M3's attachment/generation/credential guarantees.

**Authorities:**

- `peakdo/apple/docs/superpowers/specs/2026-07-18-wattline-router-administration-design.md` §§2.3, 3, 8, 9, 11
- `/Users/keith/src/openwrt-wattline/docs/api.md`, especially “BLE-device pairing” and “OTA, clock, and advanced”
- Approved source base `d983528a`

**Scope:** Tasks 16–19 only. No rules, macOS work, Demo fixtures, OTA/firmware transfer, or timers.

## Existing interfaces retained

- `RouterAdministrationClient.attach(endpoint:)`, `attachmentLease()`, `validate(attachment:)`, `send`, `sendDurableMutation`, and its privileged-mutation FIFO remain the single administrator request boundary.
- `RouterCredentialStore` retains the bare endpoint UUID account for `.client` and the `.administrator` suffix for administrator credentials.
- Pairing routes authenticate with the managed **client** credential. They do not use `RouterAdministrationClient`'s administrator token.
- `RouterConnectionClock` is the injected clock used for bounded pairing sleeps. No second clock abstraction is introduced.
- `RouterConnection.readDeviceTime()` and `RouterTransport.synchronizeDeviceTime()` already implement `/api/v1/device/clock` and `/api/v1/device/clock/sync`; Task 17 factors the shared DTO/decoder without changing their behavior.
- `RouterAdministrationModel` remains `@MainActor`; publication uses endpoint/session/request generations and `performAdmin`/`handleAdminFailure`.
- `RouterDeviceDTO` and `RouterAvailabilityDTO` remain the authoritative identity/availability inputs.

## Global invariants and test discipline

1. Pairing and administration issue HTTP only. No `BLETransport`, `DeviceSession`, `DeviceOperationBroker`, second `DeviceTransport`, or new `DeviceCommand` case.
2. Core/UI remain networking- and Security-free; WattlineUI does not depend on WattlineNetwork.
3. PIN/token/private-key bytes never enter persistence, snapshots, descriptions, mirrors, logs, or error strings. Empty pairing PIN is encoded as `"pin":""`.
4. Readback is truth. Bypass and barrier-free return decoded observed values. Running mode and BLE PIN publish only validated server responses.
5. Every async completion is quarantined by the attachment/session/request generation captured before dispatch.
6. Tests use `ScriptedRouterHTTPClient`, injected credential stores/clocks, and bounded waits only.

---

## Task 16: Pair Link-Power through the router

**Files**

- Create `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterDevicePairing.swift`
- Create `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterDevicePairingTests.swift`
- Create `peakdo/apple/WattlineUI/Sources/WattlineUI/RouterDevicePairingPresentation.swift`
- Create `peakdo/apple/WattlineUI/Tests/WattlineUITests/RouterDevicePairingPresentationTests.swift`
- Create `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterDevicePairingView.swift`
- Modify `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterAdministrationModel.swift`
- Modify `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterAdministrationView.swift`
- Modify `peakdo/apple/Wattline/WattlineTests/RouterAdministrationModelTests.swift`

### Interfaces produced

```swift
public enum RouterDevicePairingStage: String, Codable, Sendable {
    case idle, scanning, pairing, connected, failed
}

public struct RouterPairableDevice: Codable, Equatable, Sendable {
    public let mac: String
    public let name: String
    public let rssi: Int
    public let paired: Bool
}

public struct RouterDevicePairingStatus: Codable, Equatable, Sendable {
    public let stage: RouterDevicePairingStage
    public let target: String?
    public let devices: [RouterPairableDevice]
    public let error: String?
}

public enum RouterDevicePairingError: Error, Equatable, Sendable {
    case invalidMAC
    case invalidPIN
    case operationInProgress(RouterDevicePairingStatus)
    case timedOut
    case invalidResponse
}

public actor RouterDevicePairingClient {
    public init(
        endpoint: RouterEndpoint,
        credentials: RouterCredentialStore,
        http: any RouterHTTPClient,
        clock: any RouterConnectionClock,
        timeout: Duration = .seconds(30),
        pollInterval: Duration = .milliseconds(500)
    )
    public func status() async throws -> RouterDevicePairingStatus
    public func scan() async throws -> RouterDevicePairingStatus
    public func pair(mac: String, pin: String) async throws -> RouterDevicePairingStatus
    public func unpair(mac: String) async throws -> RouterDevicePairingStatus
    public func cancel()
}
```

`RouterDevicePairingClient` owns no transport. It captures an operation generation, reads `.client` credentials for every request, permits exactly one scan/pair poll loop, and increments the generation on `cancel`/replacement. `scan` and `pair` first GET status; if already scanning/pairing, they adopt and poll that activity rather than POST a second operation. A mapped 409 `operation_in_progress` also becomes an adopted status/poll, never a retrying POST. Terminal stages are idle/connected/failed; timeout is measured by injected sleeps, not wall-clock polling.

### Exact fixtures

```swift
let idle = #"{"stage":"idle","devices":[{"mac":"DC:04:5A:EB:72:2B","name":"PeakDo","rssi":-57,"paired":false}]}"#
let scanning = #"{"stage":"scanning","target":null,"devices":[]}"#
let pairing = #"{"stage":"pairing","target":"DC:04:5A:EB:72:2B","devices":[]}"#
let connected = #"{"stage":"connected","target":"DC:04:5A:EB:72:2B","devices":[{"mac":"DC:04:5A:EB:72:2B","name":"PeakDo","rssi":-48,"paired":true}]}"#
let failed = #"{"stage":"failed","target":"DC:04:5A:EB:72:2B","devices":[],"error":"pair_failed"}"#
let scanAccepted = #"{"status":"scanning"}"#
let pairAccepted = #"{"status":"pairing"}"#
let removed = #"{"status":"removed"}"#
```

### RED tests

Add complete XCTest cases that:

```swift
func testStatusDecodesExactDeviceFieldsAndUsesClientCredential() async throws
func testScanUsesGETThenBodyless202POSTAndPollsToTerminal() async throws
func testPairNormalizesMACAndSendsExactSixDigitPIN() async throws
func testPairSendsExplicitEmptyPINToRetainRouterConfiguration() async throws
func testExistingOr409ActivityIsAdoptedWithoutSecondPOST() async throws
func testPollingTimesOutOnInjectedClockAndStopsIssuingRequests() async throws
func testCancellationStopsPollingAndLateResponsePublishesNothing() async throws
func testEndpointReplacementQuarantinesOldPollCompletion() async throws
func testUnpairPercentEncodesNormalizedMACUsesBodylessDeleteAndRefetchesStatus() async throws
func testInvalidMACOrPINFailsBeforeCredentialOrHTTPAccess() async throws
func testAsyncFailedStagePreservesSanitizedErrorWithoutSecretMaterial() async throws
```

Use the existing scripted HTTP double and a `PairingTestClock: RouterConnectionClock` whose `sleep(for:)` records bounded continuations. Assert exact call sequences:

```swift
XCTAssertEqual(http.calls.map { ($0.method, $0.path) }, [
    ("GET", "/api/v1/pairing/status"),
    ("POST", "/api/v1/pairing/pair"),
    ("GET", "/api/v1/pairing/status"),
])
XCTAssertEqual(http.calls[1].body, Data(#"{"mac":"DC:04:5A:EB:72:2B","pin":""}"#.utf8))
XCTAssertEqual(http.calls.map(\.token), ["managed-client", "managed-client", "managed-client"])
```

UI-local presentation contains no network DTO:

```swift
public struct RouterPairableDeviceValue: Equatable, Sendable { /* mac/name/rssi/paired */ }
public enum RouterDevicePairingPresentation {
    public static func rows(stage: String, devices: [RouterPairableDeviceValue]) -> [RouterPairingRow]
    public static func statusText(stage: String, target: String?, error: String?) -> String
}
```

Test RSSI labels, paired markers, busy/terminal/error text, deterministic ordering, and that the optional PIN is never present in presentation values/reflection.

App-model tests prove one operation, endpoint replacement/cancellation quarantine, no PIN retention after dispatch, 409 adoption, timeout error, and authoritative unpair refetch. `RouterDevicePairingView` shows discovered rows and RSSI, secure optional six-digit PIN entry, Scan/Pair/Unpair actions, and clears PIN on submit/disappear/background.

### RED command and expected failure

```bash
swift test --package-path peakdo/apple/WattlineNetwork --filter RouterDevicePairingTests
swift test --package-path peakdo/apple/WattlineUI --filter RouterDevicePairingPresentationTests
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination "platform=iOS Simulator,name=${WATTLINE_SIMULATOR_NAME:-Wattline-Tests-2}" \
  -only-testing:WattlineTests/RouterAdministrationModelTests CODE_SIGNING_ALLOWED=NO
```

Expected RED: missing `RouterDevicePairingClient`, pairing DTO/presentation types, model state/methods, and view composition.

### GREEN implementation

Implement the interfaces exactly, decode only documented shapes, require exact 200/202 response codes, normalize MAC via `DeviceIdentityDeduplicator.normalizedMAC`, encode JSON through a private redacted payload with custom mirror, and sanitize asynchronous error to a finite enum/presentation string. Pairing client replacement is explicit (`cancel`, then construct/attach the new endpoint client in the app model); late generations throw `CancellationError`.

Run focused tests, then full Network/UI/iOS suites. Review for secret reflection, bounded polling, exactly one operation, and client-role auth.

Commit:

```bash
git commit -m "feat: pair Link-Power through router"
```

---

## Task 17: Add exact router advanced-device APIs

**Files**

- Create `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterAdvancedControls.swift`
- Create `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterAdvancedControlsTests.swift`
- Modify `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterConnection.swift` only to reuse the shared clock DTO/decoder
- Modify `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterCommandTests.swift` only to prove existing clock behavior is unchanged

### Interfaces produced

```swift
public struct RouterBypassThreshold: Codable, Equatable, Sendable { public let volts: Double }
public struct RouterDeviceClock: Equatable, Sendable {
    public let available: Bool
    public let deviceTime: Date?
    public let systemTime: Date
    public let driftSeconds: Double?
}
public struct RouterClockSyncResult: Equatable, Sendable { public let synced: Bool; public let systemTime: Date }
public struct RouterRunningMode: Codable, Equatable, Sendable { public let mode: UInt8 }
public struct RouterBarrierFree: Codable, Equatable, Sendable { public let enabled: Bool }
public struct RouterUSBFirmwareVersion: Codable, Equatable, Sendable {
    public let raw: String; public let major: Int; public let minor: Int; public let patch: Int
}
public struct RouterBLEPINUpdate: Equatable, Sendable { public let updated: Bool }

extension RouterAdministrationClient {
    public func bypassThreshold() async throws -> RouterBypassThreshold
    public func setBypassThreshold(volts: Double) async throws -> RouterBypassThreshold
    public func deviceClock() async throws -> RouterDeviceClock
    public func synchronizeDeviceClock() async throws -> RouterClockSyncResult
    public func setRunningMode(_ mode: UInt8) async throws -> RouterRunningMode
    public func barrierFree() async throws -> RouterBarrierFree
    public func setBarrierFree(_ enabled: Bool) async throws -> RouterBarrierFree
    public func usbFirmwareVersion() async throws -> RouterUSBFirmwareVersion
    public func updateBLEPIN(_ pin: String) async throws -> RouterBLEPINUpdate
}
```

Every method captures an attachment lease before joining the existing privileged FIFO, checks cancellation and attachment after acquiring it, uses `send`, validates exact status/response shape, then revalidates before returning. Mutations are serialized with settings/TLS/admin reads. PIN validation occurs before credential access. The PIN request payload is reflection-redacted.

### Exact fixtures and RED assertions

```swift
let threshold = #"{"volts":19.6}"#
let clockAvailable = #"{"available":true,"device_time":"2026-07-20T03:04:05Z","system_time":"2026-07-20T03:04:08Z","drift_seconds":-3}"#
let clockUnavailable = #"{"available":false,"device_time":null,"system_time":"2026-07-20T03:04:08Z","drift_seconds":null}"#
let sync = #"{"synced":true,"system_time":"2026-07-20T03:04:08Z"}"#
let running = #"{"mode":1}"#
let barrier = #"{"enabled":true}"#
let usb = #"{"raw":"010409","major":1,"minor":4,"patch":9}"#
let pinUpdated = #"{"updated":true}"#
```

Add tests:

```swift
func testBypassGETAndPUTUseCanonicalRouteAndReturnObservedBodies() async throws
func testBypassPUTRejectsMalformedObservedReadbackRatherThanEchoingRequest() async throws
func testClockAvailableAndUnavailableDecodeExactlyAndUnavailableRequiresNoSecondRequest() async throws
func testClockSyncUsesBodylessPOSTAndExistingTransportClockTestsStayGreen() async throws
func testRunningModeUsesUnsignedJSONAndReturnsValidatedServerMode() async throws
func testBarrierGETAndPUTReturnOnlyObservedResponses() async throws
func testUSBFirmwareIsReadOnlyAndDecodesRawAndComponents() async throws
func testBLEPINRequiresSixDigitsSendsExactBodyAndNeverEchoesPIN() async throws
func testAdvancedDisabledAndCapabilityUnsupportedRemainTypedNetworkErrors() async throws
func testQueuedAdvancedRequestCancelledByAttachmentReplacementNeverDispatches() async throws
func testURLErrorCancelledMapsToCancellationError() async throws
func testAdvancedRequestsSharePrivilegedFIFOWithSettingsAndTLS() async throws
```

Exact routes/bodies:

```swift
("GET", "/api/v1/device/dc/bypass/threshold", nil)
("PUT", "/api/v1/device/dc/bypass/threshold", Data(#"{"volts":19.6}"#.utf8))
("GET", "/api/v1/device/clock", nil)
("POST", "/api/v1/device/clock/sync", nil)
("PUT", "/api/v1/device/advanced/running-mode", Data(#"{"mode":1}"#.utf8))
("GET", "/api/v1/device/advanced/barrier-free", nil)
("PUT", "/api/v1/device/advanced/barrier-free", Data(#"{"enabled":true}"#.utf8))
("GET", "/api/v1/device/advanced/usb-fw-version", nil)
("PUT", "/api/v1/device/advanced/ble-pin", Data(#"{"pin":"020555"}"#.utf8))
```

### Clock reconciliation

Move the private `RouterConnection.ClockResponse` representation into a shared internal decoder in `RouterAdvancedControls.swift`. `RouterConnection.readDeviceTime()` continues to call the same route and returns nil for `available:false`; `RouterTransport.synchronizeDeviceTime()` remains bodyless POST. No duplicate request path or public transport behavior is added.

### RED/GREEN commands

```bash
swift test --package-path peakdo/apple/WattlineNetwork --filter RouterAdvancedControlsTests
swift test --package-path peakdo/apple/WattlineNetwork --filter RouterCommandTests
```

Expected RED: missing advanced DTOs/client methods. GREEN requires both focused suites and the full  Network suite.

Commit:

```bash
git commit -m "feat: add router advanced device controls"
```

---

## Task 18: Present structurally gated advanced administration

**Files**

- Create `peakdo/apple/WattlineUI/Sources/WattlineUI/RouterAdvancedPresentation.swift`
- Create `peakdo/apple/WattlineUI/Tests/WattlineUITests/RouterAdvancedPresentationTests.swift`
- Create `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterAdvancedView.swift`
- Modify `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterAdministrationModel.swift`
- Modify `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterAdministrationView.swift`
- Modify `peakdo/apple/Wattline/WattlineTests/RouterAdministrationModelTests.swift`

### Pure UI interface

```swift
public enum RouterAdvancedSurface: String, CaseIterable, Sendable {
    case bypassThreshold, clock, runningMode, barrierFree, usbFirmware, blePIN
}
public struct RouterAdvancedGate: Equatable, Sendable {
    public let administratorVerified: Bool
    public let advancedEnabled: Bool
    public let applicationMode: Bool
    public let supported: Set<RouterAdvancedSurface>
    public func visibleSurfaces() -> Set<RouterAdvancedSurface>
}
public enum RouterAdvancedFailurePresentation: Equatable, Sendable {
    case enableAdvanced
    case removeSurface(RouterAdvancedSurface)
    case retry(String)
}
```

`visibleSurfaces` returns empty unless administrator verification, settings advanced, and application mode all pass. It intersects the authoritative support set. There is no disabled representation for unsupported controls.

### Capability mapping

The app maps identity/availability to support:

- bypass threshold: DC available plus bypass-control feature
- clock: `available.currentTime`
- running mode, barrier-free, USB firmware, BLE PIN: application mode plus the daemon/API support advertised by authoritative identity/settings; a 409 `capability_unsupported` removes only that surface after an identity/settings refresh

Do not infer support from a successful button tap and do not mutate FEATURES locally. A 403 `advanced_disabled` clears advanced presentation and provides a navigation affordance to M3's settings editor.

### RED tests

UI tests enumerate every missing gate and assert structural absence:

```swift
func testNoSurfaceExistsWhileLockedAdvancedOffOrNotApplicationMode()
func testVisibleSurfacesAreExactIntersectionOfAuthoritativeSupport()
func testAdvancedDisabledPresentsEnableAdvancedAffordance()
func testCapabilityUnsupportedRemovesOnlyAffectedSurface()
func testRunningModeAndBLEPINRequirePurposeSpecificConfirmation()
func testNumericalPresentationIsDeterministicAndPINNeverAppears()
```

App-model tests:

```swift
func testAdvancedLoadsPublishOnlyAuthoritativeReadbacks() async throws
func testBypassAndBarrierMutationsPublishServerResponseNotRequestedValue() async throws
func testRunningModeRequiresConfirmationAndPublishesValidatedResponse() async throws
func testBLEPINClearsBeforeAwaitAndNeverEntersModelState() async throws
func testAdvancedDisabledRoutesToSettingsWithoutDeadControl() async throws
func testCapabilityUnsupportedRefreshesIdentityAndRemovesOnlySurface() async throws
func testEndpointReplacementSuppressesLateAdvancedCompletion() async throws
func testLockAndSessionEndClearAdvancedState() async throws
```

Use request/operation generations parallel to M3's settings/TLS patterns. `handleAdminFailure` still handles invalid administrator credentials. Add typed handling for `NetworkError.api(403,.advancedDisabled,...)` and `(409,.capabilityUnsupported,...)` without storing the router message. `RouterAdvancedView` conditionally constructs controls from `visibleSurfaces`; uses secure six-digit PIN entry; requires confirmation dialogs for running-mode and PIN mutations; and says “router/wattlined” for router operations.

### RED/GREEN commands

```bash
swift test --package-path peakdo/apple/WattlineUI --filter RouterAdvancedPresentationTests
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination "platform=iOS Simulator,name=${WATTLINE_SIMULATOR_NAME:-Wattline-Tests-2}" \
  -only-testing:WattlineTests/RouterAdministrationModelTests CODE_SIGNING_ALLOWED=NO
```

Expected RED: missing presentation/model/view APIs. GREEN requires focused tests followed by full UI, Network, app, and widget suites.

Commit:

```bash
git commit -m "feat: present router device administration"
```

---

## Task 19: Verification and handoff

Run from `/Users/keith/.codex/worktrees/wattline-phase-2` and save complete logs under `/tmp/wattline-m4-*`:

```bash
swift test --package-path peakdo/apple/WattlineCore
swift test --package-path peakdo/apple/WattlineUI
swift test --package-path peakdo/apple/WattlineNetwork
WATTLINE_SIMULATOR_NAME=${WATTLINE_SIMULATOR_NAME:-Wattline-Tests-2}
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination "platform=iOS Simulator,name=${WATTLINE_SIMULATOR_NAME}" CODE_SIGNING_ALLOWED=NO
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineWidgets \
  -destination "platform=iOS Simulator,name=${WATTLINE_SIMULATOR_NAME}" CODE_SIGNING_ALLOWED=NO
xcodebuild build -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

Extract exact executed counts and simulator identity from both xcresults. Require Core exactly 156 and zero failed/skipped/expected failures everywhere.

Run and record exit codes for:

```bash
rg -n 'URLSession|NWBrowser|NWConnection|import Network|import Security' \
  peakdo/apple/WattlineCore/Sources peakdo/apple/WattlineUI/Sources
rg -n 'import WattlineNetwork' peakdo/apple/WattlineUI/Sources
rg -n 'WattlineNetwork' peakdo/apple/WattlineUI/Package.swift
rg -n '/device/action|/device/usbc-limit|/device/bypass-threshold|/device/schedules' \
  peakdo/apple/WattlineCore/Sources peakdo/apple/WattlineUI/Sources \
  peakdo/apple/WattlineNetwork/Sources peakdo/apple/Wattline/Wattline
rg -n 'BLETransport|DeviceSession\(|DeviceOperationBroker' \
  peakdo/apple/WattlineNetwork/Sources \
  peakdo/apple/Wattline/Wattline/RouterAdministration
rg -n 'api/v1/rules|api/v1/device/ota' \
  peakdo/apple/WattlineNetwork/Sources peakdo/apple/Wattline/Wattline
rg -n 'print\(|debugPrint\(|dump\(|Logger\(|os_log\(|NSLog\(' \
  peakdo/apple/WattlineNetwork/Sources peakdo/apple/Wattline/Wattline
git diff --check d983528a..HEAD
git status --short
```

Also inspect the diff to prove `DeviceCommand`, the six-argument `RouterTransport` initializer, `RouterCredentialProvider.credential(for:)`, and client Keychain account string are unchanged; contracts/OEM/router repo are untouched; no secret-bearing field has a default synthesized reflection.

Record per-task RED/GREEN commands and exact outputs in `.superpowers/sdd/task-16-report.md`, `task-17-report.md`, `task-18-report.md`, and `task-19-report.md`. The final report lists commits, deviations from this plan, counts, audit transcript, and these external checks:

1. Physical BlueZ scan/pair/unpair.
2. Real bypass/barrier authoritative readback.
3. Real clock drift and sync.
4. Running-mode and BLE-PIN effects on hardware.
5. Live daemon distinction between `advanced_disabled` and `capability_unsupported`.

Stop after Task 19. Do not start Milestone 5.
