# Wattline Router Discovery and Administration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete Wattline's optional `wattlined` experience on iOS and macOS: discovery and enrollment, history, router administration, Link-Power pairing, advanced controls, and rules, while Bluetooth remains primary.

**Architecture:** `WattlineNetwork` owns the typed HTTP/SSE, Bonjour, Security, credential, and router-administration actors; `WattlineCore` remains transport/model-only and networking-free. Thin iOS/macOS adapters drive one shared-source administration model and platform QR/lifecycle services, while `WattlineUI` provides cross-platform presentation without networking imports. Client and administrator credentials are role-separated and every mutation re-reads authoritative router state.

**Tech Stack:** Swift 6, Swift Package Manager, SwiftUI, Observation, URLSession, Network.framework/NWBrowser, Security/Keychain, AVFoundation/Vision on iOS, CoreImage/Vision image recognition, XCTest, Xcode 26.

## Global Constraints

- The canonical router contract is `/Users/keith/src/openwrt-wattline/docs/api.md` plus its handlers and tests; do not edit that repository.
- Do not edit `peakdo/Wattline-SPEC.md`, `peakdo/API.md`, `peakdo/src/*`, `scan.py`, or `verify*.py`.
- OTA, firmware transfer, device Timers, cloud services, analytics, app-originated webhooks, automatic BT/router failover, and deprecated compatibility routes are excluded.
- Bluetooth remains the primary transport and each app process owns exactly one active `DeviceTransport`/BLE session.
- `WattlineCore` stays free of networking, Security, SwiftUI, UIKit, AppKit, ActivityKit, WidgetKit, AppIntents, UserNotifications, and ServiceManagement.
- `WattlineUI` stays cross-platform SwiftUI and imports neither networking nor Security frameworks.
- Networking and Keychain APIs remain confined to `WattlineNetwork`; AVFoundation/Vision/AppKit/UIKit stay in thin app adapters.
- Client and bootstrap-administrator tokens use distinct Keychain accounts and never enter UserDefaults, snapshots, logs, errors, notifications, QR payloads, or diagnostics.
- Telemetry and router readback are truth: no optimistic dashboard, settings, pairing, advanced-control, or rules state.
- Unsupported/client-only/admin-only/Advanced-off surfaces are structurally absent, not disabled.
- iOS deployment remains 17.0+, bundle ID `com.keithah.wattline`; macOS deployment is 14.0+, bundle ID `com.keithah.wattline.mac`; app group remains `group.com.keithah.wattline`.
- Every behavior starts with a non-vacuous failing test, then minimal implementation, green suites, and a focused commit.
- Simulator commands use `WATTLINE_SIMULATOR_NAME=${WATTLINE_SIMULATOR_NAME:-Wattline-Tests-2}` rather than a hard-coded Apple device model.

---

## File and ownership map

- `WattlineNetwork/RouterDiscovery.swift`: strict Bonjour decoding and injected browser lifecycle only.
- `WattlineNetwork/RouterCredentials.swift`: role-scoped credential accounts and Keychain adapter only.
- `WattlineNetwork/RouterAdministrationClient.swift`: generation-isolated authenticated administration actor.
- `WattlineNetwork/RouterHistory.swift`: history DTO/client and wall-clock conversion.
- `WattlineNetwork/RouterPairingAdministration.swift`: pairing-mode, PNG, and token administration contracts.
- `WattlineNetwork/RouterSettings.swift`: full settings DTO, sparse merge patch, validation, and request mapping.
- `WattlineNetwork/RouterTLSRotation.swift`: staged/active pin metadata and authenticated promotion state machine.
- `WattlineNetwork/RouterDevicePairing.swift`: router-to-Link-Power scan/pair/unpair DTOs and bounded polling.
- `WattlineNetwork/RouterAdvancedControls.swift`: bypass/clock/mode/barrier/USB firmware/BLE PIN APIs.
- `WattlineNetwork/RouterRules.swift`: lossless known/unknown rule decoding, validation, and mutation API.
- `WattlineUI/RouterPresentations.swift`: pure cross-platform history/admin/pairing/settings/rules presentation.
- `Wattline/Wattline/RouterConnectionModel.swift`: saved/discovered router identity and client enrollment orchestration.
- `Wattline/WattlineShared/RouterAdministrationModel.swift`: shared-source observable app model for both app targets.
- `Wattline/Wattline/RouterEnrollment/*`: iOS camera, deep-link, paste/image, and enrollment views.
- `Wattline/Wattline/RouterAdministration/*`: iOS navigation and platform adapters.
- `Wattline/WattlineMac/*`: macOS app shell, menu bar, navigation, and image/share/lifecycle adapters.
- `Wattline/Wattline.xcodeproj/project.pbxproj`: iOS permission/URL scheme and macOS target/product/test configuration.

---

## Milestone 1 — Discovery and client enrollment

### Task 1: Make Bonjour discovery lifecycle explicit

**Files:**
- Modify: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterDiscovery.swift`
- Test: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/DiscoveryAndCredentialsTests.swift`
- Modify: `peakdo/apple/Wattline/Wattline/RouterConnectionModel.swift`
- Test: `peakdo/apple/Wattline/WattlineTests/RouterDiscoveryLifecycleTests.swift`

**Interfaces:**
- Consumes: `RouterDiscovery(source:)`, `RouterDiscovery.routers()`, and existing strict v1 TXT validation.
- Produces: `RouterDiscoverySession.start() -> AsyncStream<[DiscoveredRouter]>`, `RouterDiscoverySession.stop()`, and `RouterConnectionModel.startDiscovery()/stopDiscovery()` with `discoveredRouters` and `discoveryError`.

- [ ] **Step 1: Write failing lifecycle and stale-session tests**

```swift
func testScanLifecycleStartsOnceStopsOnExitAndRejectsOldSessionResults() async {
    let source = RecordingDiscoverySource()
    let model = makeRouterModel(discoverySource: source)
    model.startDiscovery()
    model.startDiscovery()
    XCTAssertEqual(await source.startCount, 1)
    model.stopDiscovery()
    await source.yield([router(id: "dc045aeb722b")], session: 0)
    XCTAssertTrue(model.discoveredRouters.isEmpty)
    XCTAssertEqual(await source.cancelCount, 1)
}
```

- [ ] **Step 2: Run RED test**

Run: `swift test --package-path peakdo/apple/WattlineNetwork --filter DiscoveryAndCredentialsTests && xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination "platform=iOS Simulator,name=${WATTLINE_SIMULATOR_NAME}" CODE_SIGNING_ALLOWED=NO -only-testing:WattlineTests/RouterDiscoveryLifecycleTests`

Expected: compilation fails because `startDiscovery`, `stopDiscovery`, and injectable discovery ownership do not exist.

- [ ] **Step 3: Implement one cancelable generation-scoped discovery task**

```swift
@MainActor func startDiscovery() {
    guard discoveryTask == nil else { return }
    discoveryGeneration &+= 1
    let generation = discoveryGeneration
    discoveryTask = Task { [discovery] in
        for await routers in discovery.routers() where !Task.isCancelled {
            guard generation == discoveryGeneration else { return }
            discoveredRouters = routers
        }
    }
}

@MainActor func stopDiscovery() {
    discoveryGeneration &+= 1
    discoveryTask?.cancel()
    discoveryTask = nil
    discoveredRouters = []
}
```

- [ ] **Step 4: Run GREEN tests**

Run the Task 1 command again, then `swift test --package-path peakdo/apple/WattlineNetwork`.

Expected: focused tests and all Network tests pass; canceled generation frames cannot mutate the model.

- [ ] **Step 5: Commit**

```bash
git add peakdo/apple/WattlineNetwork peakdo/apple/Wattline/Wattline/RouterConnectionModel.swift peakdo/apple/Wattline/WattlineTests/RouterDiscoveryLifecycleTests.swift
git commit -m "feat: drive router discovery lifecycle"
```

### Task 2: Unify and deduplicate Bluetooth, discovered, and saved devices

**Files:**
- Modify: `peakdo/apple/Wattline/Wattline/RouterConnectionModel.swift`
- Modify: `peakdo/apple/Wattline/Wattline/ScanView.swift`
- Test: `peakdo/apple/Wattline/WattlineTests/RouterAppWiringTests.swift`
- Test: `peakdo/apple/Wattline/WattlineUITests/WattlineEntryUITests.swift`
- Modify: `peakdo/apple/Wattline/Wattline/Info.plist`
- Modify: `peakdo/apple/Wattline/WattlineTests/Phase2ProjectConfigurationTests.swift`

**Interfaces:**
- Consumes: `DeviceIdentityDeduplicator`, saved `RouterHostMetadata`, discovered `DiscoveredRouter`, and cached BLE identities.
- Produces: `UnifiedScanRecord` with `id`, `identity`, `bluetoothDevice`, `router`, `savedHost`, `transportOptions`, and `.bluetooth` preference.

- [ ] **Step 1: Write failing merge, structure, and plist tests**

```swift
func testDiscoveredRouterAndBLEWithSameMACProduceOneBluetoothPreferredRow() {
    let records = RouterConnectionModel.scanRecords(
        bluetooth: [ble(mac: "DC:04:5A:EB:72:2B")],
        routers: [router(id: "dc045aeb722b")], saved: []
    )
    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(records[0].transportOptions, [.bluetooth, .router])
    XCTAssertEqual(records[0].preferredTransport, .bluetooth)
}

func testInfoPlistDeclaresBonjourAndLocalNetworkUsage() throws {
    let plist = try projectPlist("Wattline/Info.plist")
    XCTAssertEqual(plist["NSBonjourServices"] as? [String], ["_wattline._tcp"])
    XCTAssertNotNil(plist["NSLocalNetworkUsageDescription"] as? String)
}
```

- [ ] **Step 2: Run RED tests**

Run: `xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination "platform=iOS Simulator,name=${WATTLINE_SIMULATOR_NAME}" CODE_SIGNING_ALLOWED=NO -only-testing:WattlineTests/RouterAppWiringTests -only-testing:WattlineTests/Phase2ProjectConfigurationTests`

Expected: failures because discovered routers are not in the scan composition and Bonjour privacy keys are absent.

- [ ] **Step 3: Implement unified rows and structural router actions**

```swift
struct UnifiedScanRecord: Identifiable, Equatable {
    let id: String
    let identity: DeviceIdentitySnapshot?
    let bluetoothDevice: DiscoveredDevice?
    let router: DiscoveredRouter?
    let savedHost: RouterHostMetadata?
    let transportOptions: Set<AppTransportKind>
    let preferredTransport: AppTransportKind
}
```

Render one row per physical device; show the Router badge/action only when `.router` is in `transportOptions`. Add `NSLocalNetworkUsageDescription` and `NSBonjourServices = ["_wattline._tcp"]`.

- [ ] **Step 4: Run GREEN tests and UI build**

Run the Task 2 test command and `xcodebuild build -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`.

Expected: tests pass and the iOS target builds.

- [ ] **Step 5: Commit**

```bash
git add peakdo/apple/Wattline/Wattline peakdo/apple/Wattline/WattlineTests peakdo/apple/Wattline/WattlineUITests
git commit -m "feat: unify Bluetooth and router discovery"
```

### Task 3: Define platform-neutral pairing input and routing

**Files:**
- Modify: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterPairingPayload.swift`
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterPairingInput.swift`
- Test: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterPairingInputTests.swift`
- Create: `peakdo/apple/Wattline/Wattline/RouterEnrollment/RouterEnrollmentRoute.swift`
- Test: `peakdo/apple/Wattline/WattlineTests/RouterEnrollmentRouteTests.swift`

**Interfaces:**
- Consumes: canonical `wattline://pair` v1 parser and `RouterEnrollmentClient`.
- Produces: `RouterPairingInputParser.parse(text:)`, `RouterPairingInputParser.parse(url:)`, and `RouterEnrollmentRoute.consume(_:)` that owns no secret persistence.

- [ ] **Step 1: Write failing exact URL, paste, redaction, and replacement tests**

```swift
func testPairingTextAcceptsOnlyCanonicalURLAndDescriptionRedactsPIN() throws {
    let input = try RouterPairingInputParser.parse(text: canonicalPairURL)
    XCTAssertEqual(input.payload.deviceID, "dc045aeb722b")
    XCTAssertFalse(String(describing: input).contains("123456"))
    XCTAssertThrowsError(try RouterPairingInputParser.parse(text: canonicalPairURL + "&extra=x"))
}

func testNewDeepLinkReplacesAndClearsPriorSecretRoute() {
    var route = RouterEnrollmentRoute()
    route.consume(firstURL)
    route.consume(secondURL)
    XCTAssertEqual(route.payload?.deviceID, secondDeviceID)
    route.clear()
    XCTAssertNil(route.payload)
}
```

- [ ] **Step 2: Run RED tests**

Run: `swift test --package-path peakdo/apple/WattlineNetwork --filter RouterPairingInputTests` and the iOS app test filtered to `RouterEnrollmentRouteTests`.

Expected: new parser and route types are missing.

- [ ] **Step 3: Implement canonical parser facade and ephemeral route**

```swift
public struct RouterPairingInput: Sendable, CustomStringConvertible {
    public let payload: RouterPairingPayload
    public var description: String { "RouterPairingInput([REDACTED])" }
}

@MainActor @Observable final class RouterEnrollmentRoute {
    private(set) var payload: RouterPairingPayload?
    func consume(_ url: URL) { payload = try? RouterPairingPayload.parse(url) }
    func clear() { payload = nil }
}
```

- [ ] **Step 4: Run GREEN tests**

Run both focused suites and `swift test --package-path peakdo/apple/WattlineNetwork`.

Expected: all pass and no secret appears in descriptions.

- [ ] **Step 5: Commit**

```bash
git add peakdo/apple/WattlineNetwork peakdo/apple/Wattline/Wattline/RouterEnrollment peakdo/apple/Wattline/WattlineTests/RouterEnrollmentRouteTests.swift
git commit -m "feat: route router pairing inputs"
```

### Task 4: Add PIN enrollment and iOS QR/paste/image surfaces

**Files:**
- Create: `peakdo/apple/Wattline/Wattline/RouterEnrollment/QRCodeRecognition.swift`
- Create: `peakdo/apple/Wattline/Wattline/RouterEnrollment/RouterQRCodeScannerView.swift`
- Create: `peakdo/apple/Wattline/Wattline/RouterEnrollment/RouterEnrollmentView.swift`
- Modify: `peakdo/apple/Wattline/Wattline/ScanView.swift`
- Modify: `peakdo/apple/Wattline/Wattline/WattlineApp.swift`
- Modify: `peakdo/apple/Wattline/Wattline/Info.plist`
- Modify: `peakdo/apple/Wattline/WattlineTests/RouterAppWiringTests.swift`
- Modify: `peakdo/apple/Wattline/WattlineTests/Phase2ProjectConfigurationTests.swift`
- Test: `peakdo/apple/Wattline/WattlineTests/RouterEnrollmentCoordinatorTests.swift`
- Test: `peakdo/apple/Wattline/WattlineUITests/WattlineEntryUITests.swift`

**Interfaces:**
- Consumes: Task 3 route, discovered router endpoint/ID/pin, `RouterConnectionModel.enroll`, injected `QRCodeRecognizer`, and injected lifecycle adapter.
- Produces: camera/paste/photo/deep-link enrollment UI, `RouterEnrollmentCoordinator.submit(pin:label:router:)`, Keychain-before-host rollback behavior, and connect-after-save.

- [ ] **Step 1: Write failing coordinator and project configuration tests**

```swift
func testDiscoveredPINEnrollmentUsesPublicPairThenSavesCredentialAndHost() async throws {
    let fixture = EnrollmentFixture()
    try await fixture.coordinator.submit(pin: "123456", label: "Keith iPhone", router: fixture.router)
    XCTAssertEqual(await fixture.http.authorizationHeaders, [nil])
    XCTAssertEqual(await fixture.credentials.savedTokens.count, 1)
    XCTAssertEqual(await fixture.hosts.values.count, 1)
    XCTAssertEqual(fixture.connectedEndpoint, fixture.response.endpoint)
}

func testHostFailureRollsBackNewKeychainCredential() async {
    let fixture = EnrollmentFixture(hostFailure: TestError.write)
    await XCTAssertThrowsErrorAsync { try await fixture.submit() }
    XCTAssertEqual(await fixture.credentials.deleteCount, 1)
}
```

Assert `CFBundleURLSchemes == ["wattline"]` and a nonempty `NSCameraUsageDescription`.

- [ ] **Step 2: Run RED tests**

Run the filtered iOS coordinator and configuration tests.

Expected: missing coordinator/adapters/configuration and no discovered PIN UI.

- [ ] **Step 3: Implement ephemeral scanner and enrollment coordinator**

```swift
protocol QRCodeRecognizer: Sendable { func payload(from imageData: Data) async throws -> String }

@MainActor final class RouterEnrollmentCoordinator {
    func submit(pin: String, label: String, router: DiscoveredRouter) async throws {
        let result = try await enrollmentClient(router.endpoint).enroll(
            pin: pin, label: label, expectedDeviceID: router.deviceID,
            expectedFingerprint: router.certificateFingerprint
        )
        try await connectionModel.persistEnrollment(result, displayName: router.serviceName)
        connect(result.endpoint)
    }
}
```

Request camera access only from the Scan QR button, clear payload/PIN on dismissal or background, register `wattline` URL scheme, and handle `.onOpenURL` through Task 3.

- [ ] **Step 4: Run GREEN tests and launch smoke**

Run the focused tests, full `WattlineNetwork`, and iOS scheme tests. Build, install, and launch on `${WATTLINE_SIMULATOR_NAME}`; use paste fixture when the simulator has no camera.

Expected: all tests pass; the app reaches PIN, paste, and image-import enrollment without retaining a dismissed secret.

- [ ] **Step 5: Commit**

```bash
git add peakdo/apple/Wattline/Wattline peakdo/apple/Wattline/WattlineTests peakdo/apple/Wattline/WattlineUITests
git commit -m "feat: add router enrollment surfaces"
```

### Task 5: Milestone 1 verification and handoff

**Files:**
- Modify only if a regression is found: files from Tasks 1–4.

**Interfaces:**
- Produces: independently usable iOS discovery/enrollment with Bluetooth preference and no administration work.

- [ ] **Step 1: Run package suites**

```bash
swift test --package-path peakdo/apple/WattlineCore
swift test --package-path peakdo/apple/WattlineUI
swift test --package-path peakdo/apple/WattlineNetwork
```

Expected: zero failures.

- [ ] **Step 2: Run executed iOS suites and build**

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination "platform=iOS Simulator,name=${WATTLINE_SIMULATOR_NAME}" CODE_SIGNING_ALLOWED=NO
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineWidgets -destination "platform=iOS Simulator,name=${WATTLINE_SIMULATOR_NAME}" CODE_SIGNING_ALLOWED=NO
xcodebuild build -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

Expected: real executed tests and generic build pass.

- [ ] **Step 3: Run boundary and scope audits**

```bash
rg -n 'URLSession|NWBrowser|NWConnection|import Network|import Security' peakdo/apple/WattlineCore/Sources peakdo/apple/WattlineUI/Sources
rg -n 'api\.peakdo\.ca|/device/action|/device/usbc-limit|/device/bypass-threshold|/device/schedules' peakdo/apple
git diff --check
```

Expected: first and second searches return no matches; diff check exits zero.

- [ ] **Step 4: Stop for review**

Report commits, exact pass counts, RED→GREEN evidence, simulator used, and external real-router/camera/Bonjour checks. Do not begin Milestone 2 without approval.

---

## Milestone 2 — Administration foundation

### Task 6: Add role-scoped credentials without migrating the client account

**Files:**
- Modify: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterCredentials.swift`
- Test: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/DiscoveryAndCredentialsTests.swift`

**Interfaces:**
- Produces: `RouterCredentialRole.client`, `.administrator`; `readToken(for:role:)`, `saveToken(_:for:role:)`, `deleteToken(for:role:)`. Client uses the current unsuffixed endpoint UUID account; administrator uses `"\(uuid).administrator"`.

- [ ] RED: Assert existing client account is unchanged, role values never collide, deleting admin leaves client, and descriptions redact both tokens.
- [ ] Run: `swift test --package-path peakdo/apple/WattlineNetwork --filter DiscoveryAndCredentialsTests`; expect role API compilation failure.
- [ ] GREEN implementation:

```swift
public enum RouterCredentialRole: String, Sendable { case client, administrator }
private func account(for endpoint: RouterEndpoint, role: RouterCredentialRole) -> String {
    role == .client ? endpoint.peripheralID.uuidString : "\(endpoint.peripheralID.uuidString).administrator"
}
```

- [ ] Re-run focused and full Network suites; expect zero failures.
- [ ] Commit `feat: separate router credential roles`.

### Task 7: Add generation-isolated administrator verification

**Files:**
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterAdministrationClient.swift`
- Test: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterAdministrationClientTests.swift`
- Create: `peakdo/apple/Wattline/WattlineShared/RouterAdministrationModel.swift`
- Test: `peakdo/apple/Wattline/WattlineTests/RouterAdministrationModelTests.swift`

**Interfaces:**
- Produces: actor `RouterAdministrationClient.attach(endpoint:credentials:)`, `verifyAdministrator() async throws`, `detach()`; `RouterAdministrationModel.unlock(token:)` saves admin only after GET `/settings` returns 200.

- [ ] RED: Test 200 saves, 401 invalidates only admin, 403 `admin_required` never saves, cancellation resumes once, and old-generation verification cannot unlock a new endpoint.
- [ ] Run focused tests; expect missing types.
- [ ] GREEN implementation:

```swift
public actor RouterAdministrationClient {
    private var generation: UInt64 = 0
    public func attach(endpoint: RouterEndpoint, credentials: any RouterCredentialProvider) { generation &+= 1 /* replace context */ }
    public func verifyAdministrator() async throws -> RouterSettings { try await accepted { try await settings() } }
}
```

- [ ] Run focused app and Network suites; expect zero failures.
- [ ] Commit `feat: verify router administrator sessions`.

### Task 8: Decode and present router history

**Files:**
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterHistory.swift`
- Test: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterHistoryTests.swift`
- Create: `peakdo/apple/WattlineUI/Sources/WattlineUI/RouterHistoryPresentation.swift`
- Test: `peakdo/apple/WattlineUI/Tests/WattlineUITests/RouterHistoryPresentationTests.swift`
- Create: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterHistoryView.swift`

**Interfaces:**
- Produces: `RouterHistorySample(at:level:status:dcWatts:typeCWatts:)`, `RouterHistoryClient.fetch()`, and lazy `RouterHistoryPresentation` with explicit fetched-at staleness.

- [ ] RED: Test exact `at/level/status/dc_w/typec_w`, negative status, missing optional watts, invalid dates, empty state, and no local persistence.
- [ ] Run Network/UI focused tests; expect missing types.
- [ ] GREEN: GET `/api/v1/history`, ISO-8601 decode, preserve order/value absence, present level and two power series without fabricating samples.
- [ ] Run full Network/UI suites; expect zero failures.
- [ ] Commit `feat: add router history`.

### Task 9: Add pairing-mode secret lifecycle and QR sharing

**Files:**
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterPairingAdministration.swift`
- Test: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterPairingAdministrationTests.swift`
- Create: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterPairingModeView.swift`
- Test: `peakdo/apple/Wattline/WattlineTests/RouterAdministrationModelTests.swift`

**Interfaces:**
- Produces: exact GET/POST/DELETE `/pairing-mode`, GET `/pairing-mode/qr.png`, `PairingModeSecret.clear()`, and expiry/background/dismiss clearing.

- [ ] RED: Assert POST/DELETE have zero-byte bodies, PNG has no query, QR fetch only while open, and PIN/PNG clear on expiry/dismiss/background/generation change.
- [ ] Run focused tests; expect missing API.
- [ ] GREEN: implement typed endpoints and keep PIN/PNG only in the observable model while visible.
- [ ] Run Network/app suites; expect zero failures and redacted descriptions.
- [ ] Commit `feat: administer router pairing mode`.

### Task 10: List and revoke managed client tokens

**Files:**
- Modify: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterPairingAdministration.swift`
- Test: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterPairingAdministrationTests.swift`
- Create: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterTokensView.swift`

**Interfaces:**
- Produces: `listTokens()`, `revokeToken(id:)`, percent-encoded ID path, local bootstrap/empty rejection, and relist; current-client revoke deletes only matching client credential and exits enrollment.

- [ ] RED: Test metadata-only decode, path encoding, bootstrap rejection without HTTP, relist, current-token cleanup, and unrelated-token preservation.
- [ ] Run focused tests; expect failures.
- [ ] GREEN: implement canonical GET `/tokens` and DELETE `/tokens/{id}` plus destructive confirmation.
- [ ] Run Network/app suites; expect zero failures.
- [ ] Commit `feat: manage router client tokens`.

### Task 11: Milestone 2 verification and handoff

- [ ] Run Core/UI/Network and executed iOS/widget suites using Task 5 commands.
- [ ] Audit forbidden imports, secret logging (`rg -n 'print\(|Logger.*token|UserDefaults.*token' peakdo/apple`), deprecated routes, and `git diff --check`.
- [ ] Report exact counts and external pairing-mode/token-revoked-SSE checks; stop before Milestone 3.

---

## Milestone 3 — Router configuration and TLS

### Task 12: Add complete settings DTO and sparse merge patch

**Files:**
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterSettings.swift`
- Test: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterSettingsTests.swift`

**Interfaces:**
- Produces: `RouterSettings`, nested listener/TLS/pairing/mDNS settings, `RouterSettingsPatch`, `settings()`, `updateSettings(_:)`; patch cannot encode `tls.sha256`.

- [ ] RED: Decode every documented field; prove omission differs from empty mDNS interfaces; reject read-only/unknown keys; assert PUT exact body and complete returned settings.
- [ ] Run focused tests; expect missing DTO.
- [ ] GREEN: implement explicit Codable keys and optional nested patch members only.
- [ ] Run Network suite; expect zero failures.
- [ ] Commit `feat: add typed router settings`.

### Task 13: Add safe settings editor and endpoint migration validation

**Files:**
- Create: `peakdo/apple/WattlineUI/Sources/WattlineUI/RouterSettingsPresentation.swift`
- Test: `peakdo/apple/WattlineUI/Tests/WattlineUITests/RouterSettingsPresentationTests.swift`
- Create: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterSettingsView.swift`
- Modify: `peakdo/apple/Wattline/WattlineShared/RouterAdministrationModel.swift`
- Test: `peakdo/apple/Wattline/WattlineTests/RouterAdministrationModelTests.swift`

**Interfaces:**
- Produces: form draft→sparse patch, exact six-digit BLE PIN validation, insecure-WAN/listener confirmation, at least one post-restart listener, replacement endpoint validation, and honest `restartRequired` message.

- [ ] RED: Test no-op patch, individual nested changes, empty interfaces, invalid ports/PIN, removal of last listener, replacement candidate validation, stale-generation save, and readback-only publication.
- [ ] Run focused UI/app tests; expect missing types.
- [ ] GREEN: implement cross-platform draft validation and iOS form; publish only complete PUT response.
- [ ] Run UI/app suites; expect zero failures.
- [ ] Commit `feat: edit router configuration safely`.

### Task 14: Stage and atomically promote TLS certificate pins

**Files:**
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterTLSRotation.swift`
- Modify: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterHostStore.swift`
- Modify: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterTLSPinning.swift`
- Test: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterTLSRotationTests.swift`
- Modify: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterSettingsView.swift`

**Interfaces:**
- Produces: POST `/tls/rotate` body `{"confirm":true}`, `activeFingerprint`, `stagedFingerprint`, and `promoteStagedPin(endpoint:verifiedDeviceID:)` atomic metadata update.

- [ ] RED: Test exact 64-lowercase-hex response, required restart flag, old-only before restart, staged-only trial after restart, device-ID mismatch rejection, atomic promotion, old-pin rejection after promotion, and no HTTP downgrade/TOFU.
- [ ] Run focused tests; expect missing rotation model.
- [ ] GREEN: implement staged pin state machine and destructive UI confirmation.
- [ ] Run Network/app suites; expect zero failures.
- [ ] Commit `feat: rotate router TLS pins safely`.

### Task 15: Milestone 3 verification and handoff

- [ ] Run all package/iOS/widget suites and generic iOS build.
- [ ] Audit network boundary, secrets, deprecated routes, contract/OEM untouched, and diff check.
- [ ] Report exact counts; classify daemon restart/certificate/listener migration as external; stop before Milestone 4.

---

## Milestone 4 — Link-Power pairing and advanced device administration

### Task 16: Implement router-to-Link-Power pairing with bounded polling

**Files:**
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterDevicePairing.swift`
- Test: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterDevicePairingTests.swift`
- Create: `peakdo/apple/WattlineUI/Sources/WattlineUI/RouterDevicePairingPresentation.swift`
- Test: `peakdo/apple/WattlineUI/Tests/WattlineUITests/RouterDevicePairingPresentationTests.swift`
- Create: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterDevicePairingView.swift`

**Interfaces:**
- Produces: status/scan/pair/unpair exact routes, `RouterPairingPoller(clock:timeout:)`, stage/device/RSSI presentation, cancel and generation quarantine.

- [ ] RED: Test exact bodies/routes, empty PIN omission, six-digit PIN, busy operation reuse, bounded timeout, cancellation, terminal/error states, unpair re-fetch, and old endpoint poll rejection.
- [ ] Run focused tests; expect missing types.
- [ ] GREEN: implement injected clock poll loop with one in-flight operation and no secret persistence.
- [ ] Run Network/UI/app suites; expect zero failures.
- [ ] Commit `feat: pair Link-Power through router`.

### Task 17: Implement exact advanced device APIs

**Files:**
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterAdvancedControls.swift`
- Test: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterAdvancedControlsTests.swift`

**Interfaces:**
- Produces: bypass threshold GET/PUT readback, admin clock GET/POST, running-mode PUT, barrier-free GET/PUT readback, USB firmware GET, BLE PIN PUT.

- [ ] RED: Assert every documented route/body/response, bypass and barrier readback, signed/unsigned enum validation, exact six-digit PIN, cancellation, `advanced_disabled`, and unsupported hardware errors.
- [ ] Run focused tests; expect missing client extensions.
- [ ] GREEN: add allow-listed methods to administration actor; do not widen `DeviceCommand`.
- [ ] Run Network suite; expect zero failures.
- [ ] Commit `feat: add router advanced device controls`.

### Task 18: Add structurally gated advanced administration UI

**Files:**
- Create: `peakdo/apple/WattlineUI/Sources/WattlineUI/RouterAdvancedPresentation.swift`
- Test: `peakdo/apple/WattlineUI/Tests/WattlineUITests/RouterAdvancedPresentationTests.swift`
- Create: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterAdvancedView.swift`
- Modify: `peakdo/apple/Wattline/WattlineShared/RouterAdministrationModel.swift`
- Test: `peakdo/apple/Wattline/WattlineTests/RouterAdministrationModelTests.swift`

**Interfaces:**
- Produces: composition based on admin verified + `settings.advanced` + application mode + feature/availability; observed readback only; confirmation for running mode/BLE PIN.

- [ ] RED: Test structural absence for every gate, Advanced enable affordance on 403, bypass/barrier readback, PIN clearing, and stale-generation mutation suppression.
- [ ] Run focused tests; expect failures.
- [ ] GREEN: implement presentation and iOS view using authoritative model state.
- [ ] Run UI/app suites; expect zero failures.
- [ ] Commit `feat: present router device administration`.

### Task 19: Milestone 4 verification and handoff

- [ ] Run all package/iOS/widget suites and generic iOS build.
- [ ] Audit one BLE owner, no `DeviceCommand` router-admin widening, no secrets, forbidden imports, deprecated routes, and diff check.
- [ ] Report exact counts; classify physical BlueZ and advanced BLE commands as external; stop before Milestone 5.

---

## Milestone 5 — Rules, macOS, Demo, and completion

### Task 20: Add lossless rule model, validation, and canonical CRUD

**Files:**
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterRules.swift`
- Test: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterRulesTests.swift`

**Interfaces:**
- Produces: known conditions/actions, checked nanosecond duration conversion, `.known(RouterRule)`/`.unknown(RawRouterRule)`, CRUD `/rules`, relist after mutation, and `PowerLossPreset` compatibility/reset.

- [ ] RED: Test all four condition families, ports, cron, hold/hysteresis/repeat, all actions including webhook, overflow, unknown additive read-only preservation, exact CRUD routes, relist, no deprecated action route, compatible preset field preservation, and incompatible Reset requirement.
- [ ] Run focused tests; expect missing rules types.
- [ ] GREEN: implement lossless raw JSON fallback and canonical rule API.
- [ ] Run Network suite; expect zero failures.
- [ ] Commit `feat: add router automation rules`.

### Task 21: Add rules and power-loss shutdown UI

**Files:**
- Create: `peakdo/apple/WattlineUI/Sources/WattlineUI/RouterRulesPresentation.swift`
- Test: `peakdo/apple/WattlineUI/Tests/WattlineUITests/RouterRulesPresentationTests.swift`
- Create: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterRulesView.swift`
- Modify: `peakdo/apple/Wattline/WattlineShared/RouterAdministrationModel.swift`

**Interfaces:**
- Produces: known rule editor, unknown read-only JSON summary, router-webhook warning, destructive shutdown confirmation, and dedicated compatible/reset power-loss editor.

- [ ] RED: Test structural read-only unknown rules, webhook copy, shutdown confirmation, preset field preservation, and Reset action.
- [ ] Run focused UI/app tests; expect missing presentation/view.
- [ ] GREEN: implement forms and model mutations with post-mutation relist only.
- [ ] Run UI/app suites; expect zero failures.
- [ ] Commit `feat: present router automation rules`.

### Task 22: Add the macOS 14 menu-bar app and shared administration navigation

**Files:**
- Modify: `peakdo/apple/Wattline/Wattline.xcodeproj/project.pbxproj`
- Create: `peakdo/apple/Wattline/WattlineMac/WattlineMacApp.swift`
- Create: `peakdo/apple/Wattline/WattlineMac/MacAppModel.swift`
- Create: `peakdo/apple/Wattline/WattlineMac/MacRootView.swift`
- Create: `peakdo/apple/Wattline/WattlineMac/MacMenuBarView.swift`
- Create: `peakdo/apple/Wattline/WattlineMac/RouterAdministration/MacRouterPlatformAdapters.swift`
- Create: `peakdo/apple/Wattline/WattlineMac/WattlineMac.entitlements`
- Create: `peakdo/apple/Wattline/WattlineMac/Info.plist`
- Create: `peakdo/apple/Wattline/WattlineMacTests/MacAppModelTests.swift`
- Create: `peakdo/apple/Wattline/WattlineMacTests/MacRouterAdministrationTests.swift`
- Modify: `peakdo/apple/Wattline/WattlineTests/Phase2ProjectConfigurationTests.swift`

**Interfaces:**
- Produces: macOS target/test target, bundle ID `com.keithah.wattline.mac`, app group, one `MacAppModel` transport owner, MenuBarExtra, Home/Shortcuts/Settings split view without Timers, Demo badge/real-device affordance, and shared router administration with paste/image QR.

- [ ] RED: Test project target/bundle/platform/app-group, exactly one MacAppModel transport factory invocation, Demo navigation, menu-title semantics, router admin composition, image/paste enrollment, and no camera permission.
- [ ] Run: `xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`; expect missing scheme/target.
- [ ] GREEN: add synchronized shared sources to both app/test targets, macOS-only adapters, MenuBarExtra and NavigationSplitView; embed the existing multi-platform widget with macOS bundle ID `com.keithah.wattline.mac.widgets`.
- [ ] Run macOS app/widget tests and build; expect zero failures.
- [ ] Commit `feat: add Wattline macOS menu bar app`.

### Task 23: Add Demo fixtures, accessibility, and cross-platform composition tests

**Files:**
- Create: `peakdo/apple/Wattline/WattlineShared/RouterAdministrationDemo.swift`
- Test: `peakdo/apple/Wattline/WattlineTests/RouterAdministrationDemoTests.swift`
- Test: `peakdo/apple/Wattline/WattlineMacTests/MacRouterAdministrationTests.swift`
- Modify: router administration views from Tasks 8–22.

**Interfaces:**
- Produces: deterministic Demo history/admin/settings/pairing/advanced/rules data, DEMO badge, “Connect a real device,” and accessibility identifiers/labels for secret, chart, toggle, destructive, stale, and unavailable states.

- [ ] RED: Test every P1 administration screen is navigable in Demo on iOS/macOS, never writes real Keychain/host store, and required accessibility labels/identifiers exist.
- [ ] Run focused iOS/macOS tests; expect fixture/composition failures.
- [ ] GREEN: inject Demo administration service and add accessibility semantics without duplicating telemetry colors.
- [ ] Run iOS/macOS/UI suites; expect zero failures.
- [ ] Commit `feat: complete router administration demo`.

### Task 24: Final verification and handoff

- [ ] Run `swift test` for WattlineCore, WattlineUI, and WattlineNetwork; record exact counts.
- [ ] Run real executed iOS Wattline and WattlineWidgets tests on `${WATTLINE_SIMULATOR_NAME}`; record exact counts.
- [ ] Run real executed `WattlineMac` and macOS widget tests plus generic iOS/macOS builds; record exact counts.
- [ ] Clean-build/install/launch iOS and macOS products and confirm the six-argument `RouterTransport` initializer ABI symbol remains present with `nm`.
- [ ] Run forbidden-import/network/Security/secret/deprecated-route/OTA/timer/one-owner/app-group audits and `git diff --check`.
- [ ] Verify `git diff -- peakdo/Wattline-SPEC.md peakdo/API.md peakdo/src /Users/keith/src/openwrt-wattline` shows no task-authored contract/OEM/router changes.
- [ ] Report real-router external checks: Bonjour/local-network permission, camera/photo QR, PIN rate limit, VPN/WAN, TLS rotation across daemon restart, listener migration, revoked SSE, BlueZ pairing, advanced BLE, rules firing, webhook delivery, launch-at-login/signing, and physical latency.
- [ ] Stop for final review; do not begin OTA or Timers.

## Self-review checklist

- Design §§2–11 map to Tasks 1–23; every API family and platform surface has an owner and a non-vacuous test boundary.
- Credential roles, generation quarantine, readback truth, structural absence, secret lifetime, and TLS staged promotion are explicitly tested.
- The plan creates the currently absent macOS target instead of assuming it exists.
- All new production types consumed by later tasks are introduced in an earlier `Interfaces` block.
- Milestone gates yield independently useful software and stop for review.
