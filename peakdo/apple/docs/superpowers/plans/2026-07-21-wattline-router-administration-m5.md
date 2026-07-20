# Wattline Router Administration Milestone 5 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use `superpowers:subagent-driven-development` (preferred) or `superpowers:executing-plans`. Execute Tasks 20–24 in order, preserve captured RED/GREEN output, and stop after the final gate.

**Goal:** Complete router automation rules, the power-loss shutdown preset, a native macOS 14 menu-bar app, deterministic cross-platform Demo administration, accessibility coverage, and the project verification gate.

**Architecture:** `WattlineNetwork` adds a lossless rule codec and canonical CRUD on the existing `RouterAdministrationClient` actor and privileged-mutation FIFO. `WattlineUI` adds Foundation-only rule/preset presentation policies. The existing `RouterAdministrationModel` moves from the iOS-only synchronized root to `WattlineShared/RouterAdministration`, where both apps compile it; the macOS target supplies only platform composition/adapters and owns exactly one transport through `MacAppModel`.

**Tech stack:** Swift 6, Foundation, SwiftUI, Observation, XCTest, Swift Package Manager, Xcode 26 synchronized root groups, macOS 14 `MenuBarExtra`/`NavigationSplitView`, iOS 17.

**Approved base:** `845d852909052d6187411c0cd80cdce7c0023d08`.

## Global constraints

- Scope is master-plan Tasks 20–24 only. Stop after Task 24; no OTA, firmware transfer, Timers, App Intents, or notification expansion.
- Normative router contract is `/Users/keith/src/openwrt-wattline/docs/api.md`, sections “Rules and legacy actions” and “Power-loss shutdown preset”; it is read-only.
- Never edit `peakdo/Wattline-SPEC.md`, `peakdo/API.md`, `peakdo/src/`, `scan.py`, `verify.py`, or `/Users/keith/src/openwrt-wattline` in either API filename case.
- No `/device/action`, `/device/usbc-limit`, `/device/bypass-threshold`, or `/device/schedules`; manual ordinary actions keep their existing granular endpoints and the app never sends a webhook itself.
- Each app process has one `DeviceTransport` owner. Shared/mac administration constructs no `BLETransport`, `DeviceSession`, or `DeviceOperationBroker` and does not widen `DeviceCommand`.
- `WattlineCore` remains at 156 tests and free of networking/Security/UI frameworks. `WattlineUI` stays Foundation-only and gains neither a source import nor package dependency on `WattlineNetwork`.
- Network and Keychain remain in `WattlineNetwork` plus thin app wiring. No PIN/token/private key enters UserDefaults, logs, errors, descriptions, reflection, snapshots, or Demo storage.
- Keep the six-argument `RouterTransport` initializer, `RouterCredentialProvider.credential(for:)`, and the existing client Keychain account unchanged.
- Every production behavior begins with a non-vacuous failing test, captured to `/tmp/wattline-m5-task*-red.log`; run focused GREEN, then the affected full suites before the focused task commit.

## Grounded interfaces at `845d8529`

```swift
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

The project uses `PBXFileSystemSynchronizedRootGroup` for `Wattline/`, `WattlineTests/`, `WattlineWidgets/`, and `../WattlineShared`. `RouterAdministrationModel.swift` is currently `Wattline/Wattline/RouterAdministration/RouterAdministrationModel.swift`; Task 22 moves it, not Task 20 or 21. The widget already supports macOS 14 and maps `sdk=macosx*` to `com.keithah.wattline.mac.widgets`.

---

### Task 20: Lossless automation-rule model, validation, canonical CRUD, and power-loss policy

**Files:**
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterRules.swift`
- Create: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterRulesTests.swift`
- Modify: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterAdministrationClient.swift`

**Interfaces:**
- Consumes: `RouterAdministrationClient.attachmentLease`, admin `send`/`sendDurableMutation`, `validate`, `RouterCredentialStore`'s unchanged client account, and the existing privileged-mutation FIFO.
- Produces: `RouterJSONValue`, `RouterRuleDuration`, `RouterRuleCondition`, `RouterRuleAction`, `RouterRule`, `RawRouterRule`, `RouterRuleDocument`, `RouterPowerLossPreset`, and `RouterAdministrationClient.rules/createRule/updateRule/deleteRule`.

- [ ] **Step 1: Write the failing duration/model tests using exact contract fixtures.**

```swift
final class RouterRulesTests: XCTestCase {
    func testDocumentedLowBatteryFixtureDecodesAndRoundTripsCanonically() throws {
        let data = Data(#"{"name":"low_battery","enabled":true,"condition":"battery_level","op":"below","percent":15,"hold":600000000000,"hysteresis_margin":5,"actions":["dc_off"],"confirm_shutdown":false}"#.utf8)
        let document = try JSONDecoder().decode(RouterRuleDocument.self, from: data)
        guard case let .known(rule) = document else { return XCTFail("expected known rule") }
        XCTAssertEqual(rule.name, "low_battery")
        XCTAssertEqual(rule.condition, .batteryLevel(op: .below, percent: 15))
        XCTAssertEqual(try rule.hold.nanoseconds(), 600_000_000_000)
        XCTAssertEqual(rule.hysteresisMargin, 5)
        XCTAssertEqual(rule.actions, [.dcOff])
        XCTAssertFalse(rule.confirmShutdown)
    }

    func testAllConditionFamiliesAndActionsDecode() throws {
        let fixtures = [
            #"{"name":"input","enabled":true,"condition":"input_power","state":"present","hold":0,"hysteresis_margin":0,"actions":["dc_on","dc_off","usbc_on","usbc_off","bypass_on","bypass_off","restart"],"confirm_shutdown":false}"#,
            #"{"name":"port","enabled":true,"condition":"port_power","port":"usbc","op":"above","watts":45.5,"hold":1000000000,"hysteresis_margin":2,"repeat_every":30000000000,"actions":["webhook:https://example.test/hook"],"confirm_shutdown":false}"#,
            #"{"name":"cron","enabled":false,"condition":"schedule","cron":"0 2 * * 1","hold":0,"hysteresis_margin":5,"actions":["shutdown"],"confirm_shutdown":true}"#,
        ]
        let decoded = try fixtures.map { try JSONDecoder().decode(RouterRuleDocument.self, from: Data($0.utf8)) }
        XCTAssertEqual(decoded.count, 3)
        XCTAssertTrue(decoded.allSatisfy { if case .known = $0 { true } else { false } })
    }

    func testDurationConversionRejectsOverflowAndSubNanosecondValues() throws {
        XCTAssertThrowsError(try RouterRuleDuration(.seconds(Int64.max)).nanoseconds())
        XCTAssertThrowsError(try RouterRuleDuration(
            .seconds(1) + .init(secondsComponent: 0, attosecondsComponent: 1)
        ).nanoseconds())
        XCTAssertThrowsError(try RouterRuleDuration(nanoseconds: -1))
    }

    func testZeroHysteresisNormalizesToFiveAndZeroRepeatIsOmitted() throws {
        let rule = try RouterRule(name: "power", enabled: true,
            condition: .inputPower(state: .absent), hold: .init(nanoseconds: 0),
            hysteresisMargin: 0, repeatEvery: .init(nanoseconds: 0),
            actions: [.dcOff], confirmShutdown: false)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as? [String: Any])
        XCTAssertEqual(object["hysteresis_margin"] as? Int, 5)
        XCTAssertNil(object["repeat_every"])
    }
}
```

- [ ] **Step 2: Run the model RED and capture the expected missing-type failure.**

```bash
swift test --package-path peakdo/apple/WattlineNetwork --filter RouterRulesTests 2>&1 | tee /tmp/wattline-m5-task20-model-red.log
```

Expected: compiler errors such as `cannot find 'RouterRuleDocument' in scope`; no fixture syntax or unrelated failure.

- [ ] **Step 3: Add the minimal lossless codec and checked duration implementation.**

```swift
public enum RouterJSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String)
    case array([RouterJSONValue]), object([String: RouterJSONValue])
}

public struct RouterRuleDuration: Equatable, Sendable {
    public let value: Duration
    public init(_ value: Duration) { self.value = value }
    public init(nanoseconds: Int64) throws {
        guard nanoseconds >= 0 else { throw RouterRuleValidationError.invalidDuration }
        value = .seconds(nanoseconds / 1_000_000_000)
            + .nanoseconds(nanoseconds % 1_000_000_000)
    }
    public func nanoseconds() throws -> Int64 {
        let parts = value.components
        guard parts.seconds >= 0, parts.attoseconds >= 0,
              parts.attoseconds % 1_000_000_000 == 0 else {
            throw RouterRuleValidationError.invalidDuration
        }
        let (whole, overflow1) = parts.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let (answer, overflow2) = whole.addingReportingOverflow(parts.attoseconds / 1_000_000_000)
        guard !overflow1, !overflow2 else { throw RouterRuleValidationError.durationOverflow }
        return answer
    }
}

public enum RouterRuleInputState: String, Codable, Sendable { case present, absent }
public enum RouterRuleComparison: String, Codable, Sendable { case below, above }
public enum RouterRulePort: String, Codable, Sendable { case dc, usbc }
public enum RouterRuleCondition: Equatable, Sendable {
    case inputPower(state: RouterRuleInputState)
    case batteryLevel(op: RouterRuleComparison, percent: Int)
    case portPower(port: RouterRulePort, op: RouterRuleComparison, watts: Double)
    case schedule(cron: String)
}
public enum RouterRuleAction: Equatable, Sendable {
    case dcOn, dcOff, usbcOn, usbcOff, bypassOn, bypassOff, restart, shutdown
    case webhook(URL)
}
public struct RouterRule: Equatable, Sendable {
    public let name: String
    public let enabled: Bool
    public let condition: RouterRuleCondition
    public let hold: RouterRuleDuration
    public let hysteresisMargin: Double
    public let repeatEvery: RouterRuleDuration?
    public let actions: [RouterRuleAction]
    public let confirmShutdown: Bool
}
public struct RawRouterRule: Equatable, Sendable {
    public let name: String?
    public let json: RouterJSONValue
    public let canonicalJSON: String
}
public enum RouterRuleDocument: Equatable, Sendable, Codable {
    case known(RouterRule)
    case unknown(RawRouterRule)
}
```

Decode each document first as `RouterJSONValue.object`. A known decode succeeds only when the top-level key set equals the documented common keys plus the exact keys for its condition, every action string is one of the nine documented forms, webhook suffix parses as an absolute `http` or `https` URL, ranges are valid (`percent 0...100`, finite nonnegative watts/margin, nonempty name, five nonempty cron fields), and shutdown implies `confirm_shutdown == true`. Any additive or unknown condition/action field returns `.unknown` with the complete raw tree and sorted canonical JSON; never decode partially and never make `.unknown` encodable for mutation. Encode `.known` only.

- [ ] **Step 4: Run focused duration/model GREEN.**

```bash
swift test --package-path peakdo/apple/WattlineNetwork --filter RouterRulesTests
```

Expected: the initial four tests pass.

- [ ] **Step 5: Add failing forward-compatibility, CRUD, FIFO, and preset tests.**

```swift
func testUnknownAdditiveFieldPreservesEntireRawDocumentAndCannotMutate() throws {
    let fixture = #"{"name":"future","enabled":true,"condition":"input_power","state":"absent","future_window":3,"hold":0,"hysteresis_margin":5,"actions":["shutdown","future:opaque"],"confirm_shutdown":true}"#
    let decoded = try JSONDecoder().decode(RouterRuleDocument.self, from: Data(fixture.utf8))
    guard case let .unknown(raw) = decoded else { return XCTFail("expected lossless fallback") }
    XCTAssertTrue(raw.canonicalJSON.contains(#""future_window":3"#))
    XCTAssertTrue(raw.canonicalJSON.contains(#""future:opaque""#))
}

func testCRUDUsesCanonicalRoutesURLNameWinsAndEveryMutationRelists() async throws {
    let f = try await fixture([
        .ok("[]"),
        .ok(lowBatteryJSON), .ok("[\(lowBatteryJSON)]"),
        .ok(lowBatteryJSON.replacingOccurrences(of: "low_battery", with: "url_name")), .ok("[]"),
        .ok(#"{"deleted":"url_name"}"#), .ok("[]"),
    ])
    XCTAssertEqual(try await f.client.rules(), [])
    _ = try await f.client.createRule(knownRule)
    _ = try await f.client.updateRule(named: "url_name", rule: knownRule)
    _ = try await f.client.deleteRule(named: "url_name")
    XCTAssertEqual(f.http.calls.map { ($0.method, $0.path) }, [
        ("GET", "/api/v1/rules"),
        ("POST", "/api/v1/rules"), ("GET", "/api/v1/rules"),
        ("PUT", "/api/v1/rules/url_name"), ("GET", "/api/v1/rules"),
        ("DELETE", "/api/v1/rules/url_name"), ("GET", "/api/v1/rules"),
    ])
    XCTAssertFalse(f.http.calls.contains { $0.path.contains("/device/action") })
    XCTAssertEqual(f.http.calls.filter { $0.method == "GET" }.map(\.token),
                   ["client-token", "client-token", "client-token", "client-token"])
    XCTAssertEqual(f.http.calls.filter { $0.method != "GET" }.map(\.token),
                   ["admin-token", "admin-token", "admin-token"])
}

func testCompatiblePresetUpdatePreservesEveryOtherFieldAndWebhook() throws {
    let source = try known(#"{"name":"no_input_shutdown","enabled":true,"condition":"input_power","state":"absent","hold":600000000000,"hysteresis_margin":9,"repeat_every":30000000000,"actions":["shutdown","webhook:https://example.test/lost"],"confirm_shutdown":true}"#)
    let preset = RouterPowerLossPreset(document: .known(source))
    XCTAssertTrue(preset.isCompatible)
    let changed = try preset.updating(enabled: false, hold: .init(nanoseconds: 120_000_000_000), confirmShutdown: true)
    XCTAssertEqual(changed.hysteresisMargin, 9)
    XCTAssertEqual(changed.repeatEvery, source.repeatEvery)
    XCTAssertEqual(changed.actions, source.actions)
}

func testIncompatiblePresetRequiresExplicitResetAndResetIsCanonical() throws {
    let source = try known(#"{"name":"no_input_shutdown","enabled":true,"condition":"battery_level","op":"below","percent":5,"hold":0,"hysteresis_margin":5,"actions":["shutdown"],"confirm_shutdown":true}"#)
    let preset = RouterPowerLossPreset(document: .known(source))
    XCTAssertFalse(preset.isCompatible)
    XCTAssertThrowsError(try preset.updating(enabled: true, hold: .init(nanoseconds: 1), confirmShutdown: true))
    let reset = try preset.reset(enabled: true, hold: .init(nanoseconds: 600_000_000_000), confirmed: true)
    XCTAssertEqual(reset.condition, .inputPower(state: .absent))
    XCTAssertEqual(reset.actions, [.shutdown])
    XCTAssertTrue(reset.confirmShutdown)
}
```

Also cover path-segment percent encoding, DELETE body exactness, deleted-name mismatch, malformed response, old-attachment cancellation, queued FIFO order, mutation-success/relist-failure surfacing without guessed state, unknown rule rejection at every mutation boundary, and `URL name wins` in the PUT response/list.

- [ ] **Step 6: Run CRUD/preset RED.**

```bash
swift test --package-path peakdo/apple/WattlineNetwork --filter RouterRulesTests 2>&1 | tee /tmp/wattline-m5-task20-crud-red.log
```

Expected: failures for missing client CRUD and preset interfaces while the first group remains green.

- [ ] **Step 7: Implement canonical CRUD and preset policy.**

```swift
public struct RouterRuleMutationResult: Equatable, Sendable {
    public let stored: RouterRule?
    public let deletedName: String?
    public let rules: [RouterRuleDocument]
}

extension RouterAdministrationClient {
    public func rules() async throws -> [RouterRuleDocument]
    public func createRule(_ rule: RouterRule) async throws -> RouterRuleMutationResult
    public func updateRule(named name: String, rule: RouterRule) async throws -> RouterRuleMutationResult
    public func deleteRule(named name: String) async throws -> RouterRuleMutationResult
}

public struct RouterPowerLossPreset: Equatable, Sendable {
    public static let reservedName = "no_input_shutdown"
    public let source: RouterRuleDocument?
    public var isCompatible: Bool
    public func updating(enabled: Bool, hold: RouterRuleDuration,
                         confirmShutdown: Bool) throws -> RouterRule
    public func reset(enabled: Bool, hold: RouterRuleDuration,
                      confirmed: Bool) throws -> RouterRule
}
```

Add an internal `sendClient(_:_:)` beside `send` in `RouterAdministrationClient.swift`. It follows the same attachment-generation, cancellation, status, and error mapping but reads `RouterCredentialRole.client`; it neither changes `send`, the Keychain account, nor `RouterCredentialProvider.credential(for:)`. `rules()` leases and enters the existing FIFO before client-role GET/decode. Each mutation captures one attachment, validates and encodes before entering the FIFO, calls the existing admin-role `sendDurableMutation`, validates the exact stored/deleted response, then uses a private non-reentrant client-role `rulesUnserialized(attachment:)` to re-list before releasing the FIFO. PUT encodes a copy whose name equals the URL name. The compatible preset copies `source` and changes only `enabled`, `hold`, `confirmShutdown`; Reset requires `confirmed == true` and creates the exact absent-input, 10-minute-default-capable canonical shutdown rule with hysteresis 5 and no repeat.

- [ ] **Step 8: Run Task 20 GREEN and commit.**

```bash
swift test --package-path peakdo/apple/WattlineNetwork --filter RouterRulesTests 2>&1 | tee /tmp/wattline-m5-task20-green.log
swift test --package-path peakdo/apple/WattlineNetwork
git diff --check
git add peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterAdministrationClient.swift peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterRules.swift peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterRulesTests.swift
git commit -m "feat: add router automation rules"
```

---

### Task 21: Rules and Power-loss shutdown UI

**Files:**
- Create: `peakdo/apple/WattlineUI/Sources/WattlineUI/RouterRulesPresentation.swift`
- Create: `peakdo/apple/WattlineUI/Tests/WattlineUITests/RouterRulesPresentationTests.swift`
- Create: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterRulesView.swift`
- Modify: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterAdministrationModel.swift`
- Modify: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterAdministrationView.swift`
- Modify: `peakdo/apple/Wattline/WattlineTests/RouterAdministrationModelTests.swift`

**Interfaces:**
- Consumes: Task 20 rule documents, preset policy, CRUD relist results, and existing `performAdmin` generation/error handling.
- Produces: `RouterRulePresentationValue`, `RouterRulesPresentation`, `RouterPowerLossPresentation`, model rule state/mutations, known editor, raw read-only summary, router-webhook warning, and destructive shutdown/reset confirmations.

- [ ] **Step 1: Write presentation RED tests.**

```swift
func testUnknownRuleIsStructurallyReadOnlyAndShowsCanonicalJSON() {
    let value = RouterRulePresentationValue(name: "future", summary: "{\"future\":true}",
        isKnown: false, hasWebhook: false, hasShutdown: false)
    let row = RouterRulesPresentation.row(for: value, adminVerified: true)
    XCTAssertTrue(row.isReadOnly)
    XCTAssertFalse(row.showsEditAction)
    XCTAssertEqual(row.jsonSummary, "{\"future\":true}")
}

func testWebhookCopyNamesRouterAsOutboundRequesterAndRequiresAdmin() {
    XCTAssertEqual(RouterRulesPresentation.webhookWarning,
        "The router—not the Wattline app—makes this outbound request.")
    XCTAssertFalse(RouterRulesPresentation.canSave(hasWebhook: true, adminVerified: false))
    XCTAssertTrue(RouterRulesPresentation.canSave(hasWebhook: true, adminVerified: true))
}

func testShutdownAndResetRequireDistinctDestructiveConfirmations() {
    XCTAssertEqual(RouterRulesPresentation.confirmation(hasShutdown: true, resetsPreset: false), .shutdown)
    XCTAssertEqual(RouterRulesPresentation.confirmation(hasShutdown: true, resetsPreset: true), .resetPowerLossPreset)
}

func testPowerLossPresentationSeparatesCompatibleAndIncompatibleStates() {
    XCTAssertEqual(RouterPowerLossPresentation.compatible.editorMode, .editablePreservingFields)
    XCTAssertEqual(RouterPowerLossPresentation.incompatible.editorMode, .readOnlyUntilReset)
}
```

- [ ] **Step 2: Run UI RED.**

```bash
swift test --package-path peakdo/apple/WattlineUI --filter RouterRulesPresentationTests 2>&1 | tee /tmp/wattline-m5-task21-ui-red.log
```

Expected: missing presentation types.

- [ ] **Step 3: Implement Foundation-only presentation.**

```swift
public struct RouterRulePresentationValue: Equatable, Sendable, Identifiable {
    public let name: String
    public let summary: String
    public let isKnown: Bool
    public let hasWebhook: Bool
    public let hasShutdown: Bool
    public var id: String { name }
}
public enum RouterRuleConfirmation: Equatable, Sendable { case shutdown, resetPowerLossPreset }
public enum RouterPowerLossEditorMode: Equatable, Sendable {
    case editablePreservingFields, readOnlyUntilReset
}
public struct RouterPowerLossPresentation: Equatable, Sendable {
    public let editorMode: RouterPowerLossEditorMode
    public static let compatible = Self(editorMode: .editablePreservingFields)
    public static let incompatible = Self(editorMode: .readOnlyUntilReset)
}
public enum RouterRulesPresentation {
    public static let webhookWarning = "The router—not the Wattline app—makes this outbound request."
    public static func canSave(hasWebhook: Bool, adminVerified: Bool) -> Bool
    public static func confirmation(hasShutdown: Bool, resetsPreset: Bool) -> RouterRuleConfirmation?
    public static func row(for value: RouterRulePresentationValue,
                           adminVerified: Bool) -> RouterRuleRowPresentation
}
```

No Network/Security imports, network DTOs, URLs fetched, or credential state enter this file.

- [ ] **Step 4: Write app RED tests for authoritative generation behavior and field preservation.**

```swift
func testReloadRulesPublishesKnownAndUnknownOnlyForCurrentSession() async
func testCreateUpdateDeletePublishOnlyMutationRelist() async
func testMutationFailureKeepsPriorRulesAndMarksThemStale() async
func testCompatiblePowerLossUpdatePreservesExtraWebhookAndFields() async
func testIncompatiblePowerLossCannotSaveUntilConfirmedReset() async
func testWebhookRuleRequiresUnlockedAdminAndViewContainsRouterWarning() throws
func testShutdownAndResetButtonsAreDestructiveAndConfirmed() throws
func testUnknownRuleViewHasJSONSummaryAndNoEditControl() throws
```

The compatible fixture is:

```json
{"name":"no_input_shutdown","enabled":true,"condition":"input_power","state":"absent","hold":600000000000,"hysteresis_margin":9,"repeat_every":30000000000,"actions":["shutdown","webhook:https://example.test/lost"],"confirm_shutdown":true}
```

- [ ] **Step 5: Run app RED.**

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination "platform=iOS Simulator,name=${WATTLINE_SIMULATOR_NAME:-Wattline-Tests-2}" CODE_SIGNING_ALLOWED=NO -only-testing:WattlineTests/RouterAdministrationModelTests 2>&1 | tee /tmp/wattline-m5-task21-app-red.log
```

Expected: missing model rule members/view composition assertions.

- [ ] **Step 6: Implement model and iOS view.**

Add `rules`, `rulesError`, `rulesFetchedAt`, `rulesLoadState`, and one request generation to the model. Attach no new transport/client: call Task 20 methods on the existing `adminClient`. `reloadRules` is available with client sections; mutations require `.unlocked`, call `performAdmin`, and publish only returned relists under session/admin/request guards. Failure leaves the prior array visible with stale presentation. Clear admin-only editing state on lock/end/endpoint replacement.

`RouterRulesView` renders known rows/editors and unknown canonical JSON using `Text(...).font(.system(.caption, design: .monospaced))`; unknown rows have no bindings or save/delete rewrite path. Webhook actions show the exact router warning before save and exist only for admin. Shutdown save and preset Reset use purpose-specific destructive dialogs. The dedicated preset editor changes only enabled, hold, and confirm shutdown when compatible; incompatible state offers only a confirmed Reset. Add Automation Rules after Device Administration in the established administration order.

- [ ] **Step 7: Run Task 21 GREEN and commit.**

```bash
swift test --package-path peakdo/apple/WattlineUI --filter RouterRulesPresentationTests 2>&1 | tee /tmp/wattline-m5-task21-ui-green.log
swift test --package-path peakdo/apple/WattlineUI
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination "platform=iOS Simulator,name=${WATTLINE_SIMULATOR_NAME:-Wattline-Tests-2}" CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/wattline-m5-task21-app-green.log
git diff --check
git add peakdo/apple/WattlineUI peakdo/apple/Wattline/Wattline/RouterAdministration peakdo/apple/Wattline/WattlineTests/RouterAdministrationModelTests.swift
git commit -m "feat: present router automation rules"
```

---

### Task 22: macOS 14 menu-bar app and shared administration navigation

**Files:**
- Move: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterAdministrationModel.swift` → `peakdo/apple/WattlineShared/RouterAdministration/RouterAdministrationModel.swift`
- Create: `peakdo/apple/Wattline/WattlineMac/WattlineMacApp.swift`
- Create: `peakdo/apple/Wattline/WattlineMac/MacAppModel.swift`
- Create: `peakdo/apple/Wattline/WattlineMac/MacRootView.swift`
- Create: `peakdo/apple/Wattline/WattlineMac/MacMenuBarView.swift`
- Create: `peakdo/apple/Wattline/WattlineMac/RouterAdministration/MacRouterAdministrationView.swift`
- Create: `peakdo/apple/Wattline/WattlineMac/RouterAdministration/MacRouterPlatformAdapters.swift`
- Create: `peakdo/apple/Wattline/WattlineMac/Info.plist`
- Create: `peakdo/apple/Wattline/WattlineMac/WattlineMac.entitlements`
- Create: `peakdo/apple/Wattline/WattlineMacTests/MacAppModelTests.swift`
- Create: `peakdo/apple/Wattline/WattlineMacTests/MacRouterAdministrationTests.swift`
- Modify: `peakdo/apple/Wattline/Wattline.xcodeproj/project.pbxproj`
- Modify: `peakdo/apple/Wattline/WattlineTests/Phase2ProjectConfigurationTests.swift`

**Interfaces:**
- Consumes: all shared package APIs and Task 21 model/rule interfaces.
- Produces: `WattlineMac` app/test schemes, `MacAppModel` as the sole mac transport owner, menu-bar shell, split navigation, Demo/real-device affordance, paste/image/URL enrollment without camera permission, and the existing widget embedded with `com.keithah.wattline.mac.widgets`.

- [ ] **Step 1: Extend configuration tests first.**

```swift
func testMacTargetsDeploymentBundlePackagesAndWidgetEmbedding() throws {
    let project = try projectText()
    let app = try target("A100000000000000000000A0", in: project)
    let tests = try target("A100000000000000000000A1", in: project)
    XCTAssertTrue(app.contains("name = WattlineMac;"))
    XCTAssertTrue(tests.contains("name = WattlineMacTests;"))
    for configuration in try configurations(for: app, in: project) {
        XCTAssertTrue(configuration.contains("MACOSX_DEPLOYMENT_TARGET = 14.0;"))
        XCTAssertTrue(configuration.contains("PRODUCT_BUNDLE_IDENTIFIER = com.keithah.wattline.mac;"))
        XCTAssertTrue(configuration.contains("CODE_SIGN_ENTITLEMENTS = WattlineMac/WattlineMac.entitlements;"))
    }
    XCTAssertTrue(app.contains("WattlineCore"))
    XCTAssertTrue(app.contains("WattlineUI"))
    XCTAssertTrue(app.contains("WattlineNetwork"))
    XCTAssertTrue(app.contains("Embed Foundation Extensions"))
}

func testMacPlistHasBonjourAndNoCameraPermission() throws {
    let plist = try NSDictionary(contentsOf: TestProjectFiles.url("WattlineMac/Info.plist"), error: ())
    XCTAssertEqual(plist["NSBonjourServices"] as? [String], ["_wattline._tcp"])
    XCTAssertNil(plist["NSCameraUsageDescription"])
}
```

- [ ] **Step 2: Create mac tests before the target and capture missing-scheme RED.**

```swift
@MainActor func testMacAppModelConstructsExactlyOneTransportOwner() {
    var constructions = 0
    let model = MacAppModel(transportFactory: { constructions += 1; return TestTransport() })
    model.start(); model.start()
    XCTAssertEqual(constructions, 1)
}

func testMenuAndSplitCompositionContainsRequiredDestinations() throws {
    let root = try source("WattlineMac/MacRootView.swift")
    XCTAssertTrue(root.contains("NavigationSplitView"))
    XCTAssertTrue(root.contains("Home"))
    XCTAssertTrue(root.contains("Shortcuts"))
    XCTAssertTrue(root.contains("Settings"))
    XCTAssertFalse(root.contains("Timers"))
}

func testMacAdministrationSupportsPasteAndImageButNoCamera() throws {
    let source = try source("WattlineMac/RouterAdministration/MacRouterAdministrationView.swift")
    XCTAssertTrue(source.contains("Paste pairing link"))
    XCTAssertTrue(source.contains("Import QR image"))
    XCTAssertFalse(source.contains("AVCapture"))
}
```

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/wattline-m5-task22-red.log
```

Expected: `The project named "Wattline" does not contain a scheme named "WattlineMac"`.

- [ ] **Step 3: Add synchronized targets and complete mac composition.**

Add synchronized roots `WattlineMac` and `WattlineMacTests`, products, source/framework/resource/copy phases, package products, test-host dependencies, Debug/Release configurations, schemes through target discovery, and project target attributes. `WattlineMac` uses `MACOSX_DEPLOYMENT_TARGET=14.0`, bundle `com.keithah.wattline.mac`, app group `group.com.keithah.wattline`, sandbox client networking/Bluetooth entitlement only as required, and embeds the existing widget target. Exclude mac-only and iOS-only files from the opposite synchronized roots explicitly.

```swift
@main struct WattlineMacApp: App {
    @State private var model = MacAppModel.production()
    var body: some Scene {
        MenuBarExtra("Wattline", systemImage: "bolt.fill") {
            MacMenuBarView(model: model)
        }
        WindowGroup("Wattline") {
            MacRootView(model: model)
        }
    }
}

@MainActor @Observable final class MacAppModel {
    typealias TransportFactory = @MainActor () -> any DeviceTransport
    private let transportFactory: TransportFactory
    private var transport: (any DeviceTransport)?
    private var session: DeviceSession?
    let routerConnections: RouterConnectionModel
    let routerAdministration: RouterAdministrationModel
    private(set) var started = false
    var isDemo = true
    func start() {
        guard !started else { return }
        started = true
        let owner = transportFactory()
        transport = owner
        session = DeviceSession(transport: owner)
    }
}
```

Only the two lines above in `MacAppModel` may construct transport/session. Administration receives the existing HTTP clients. `MacRootView` uses `NavigationSplitView` with Home, Shortcuts, Settings, and Router Administration; Demo shows `DemoBadge` and “Connect a real device.” `MacRouterAdministrationView` reuses the shared model and shared/pure presentations; mac adapters use pasteboard and `NSOpenPanel` plus existing QR recognition protocol. No camera plist key or camera source exists.

- [ ] **Step 4: Apply the optional M4 running-mode cleanup under its existing tests.**

Add `supportedRunningModes: Set<UInt8>` to the advanced capability input/value and validate membership in `RouterAdvancedControls.setRunningMode`, defaulting the BP4SL3V2 capability to `[0, 1]`. RED proves mode `2` is accepted when injected capability includes `2` and rejected otherwise. Do not use `factory_mode` gating or change `DeviceCommand`.

- [ ] **Step 5: Run Task 22 GREEN and commit.**

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/wattline-m5-task22-green.log
xcodebuild build -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineMac -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination "platform=iOS Simulator,name=${WATTLINE_SIMULATOR_NAME:-Wattline-Tests-2}" CODE_SIGNING_ALLOWED=NO
git diff --check
git add peakdo/apple/Wattline peakdo/apple/WattlineShared peakdo/apple/WattlineNetwork
git commit -m "feat: add Wattline macOS menu bar app"
```

---

### Task 23: Deterministic Demo, accessibility, and cross-platform composition

**Files:**
- Create: `peakdo/apple/WattlineShared/RouterAdministration/RouterAdministrationDemo.swift`
- Create: `peakdo/apple/Wattline/WattlineTests/RouterAdministrationDemoTests.swift`
- Modify: `peakdo/apple/Wattline/WattlineMacTests/MacRouterAdministrationTests.swift`
- Modify: iOS/macOS router administration views and roots touched by Tasks 21–22.

**Interfaces:**
- Consumes: shared model and all M1–M5 administration value types.
- Produces: deterministic `RouterAdministrationDemo.fixture`, a no-write injected service boundary, complete iOS/mac navigation, DEMO affordances, and semantic identifiers/labels for secrets/charts/toggles/destructive/stale/unavailable.

- [ ] **Step 1: Write Demo/accessibility RED tests.**

```swift
@MainActor func testDemoFixtureContainsEveryAdministrationSurface() {
    let demo = RouterAdministrationDemo.fixture(now: Date(timeIntervalSince1970: 1_721_260_800))
    XCTAssertFalse(demo.history.isEmpty)
    XCTAssertNotNil(demo.settings)
    XCTAssertNotNil(demo.pairingMode)
    XCTAssertFalse(demo.tokens.isEmpty)
    XCTAssertNotNil(demo.devicePairingStatus)
    XCTAssertFalse(demo.advancedVisibility.surfaces.isEmpty)
    XCTAssertFalse(demo.rules.isEmpty)
}

@MainActor func testDemoNeverTouchesCredentialOrHostPersistence() async throws {
    let credential = RecordingCredentialBackend()
    let hosts = RecordingHostStore()
    _ = RouterAdministrationModel.demo(credentials: credential, hosts: hosts)
    XCTAssertTrue(await credential.calls.isEmpty)
    XCTAssertTrue(await hosts.calls.isEmpty)
}

func testRequiredAccessibilityIdentifiersAreInSharedAndPlatformViews() throws {
    let text = try administrationSources()
    for identifier in ["admin.secret", "history.chart", "rule.toggle", "action.destructive",
                       "state.stale", "state.unavailable", "demo.badge", "connect.real-device"] {
        XCTAssertTrue(text.contains(identifier), "missing \(identifier)")
    }
}

func testBothPlatformsNavigateEveryAdministrationSection() throws {
    for text in [try source("Wattline/RouterAdministration/RouterAdministrationView.swift"),
                 try source("WattlineMac/RouterAdministration/MacRouterAdministrationView.swift")] {
        for label in ["History", "Client enrollment", "API clients", "Router Configuration",
                      "Link-Power pairing", "Advanced device", "Automation Rules"] {
            XCTAssertTrue(text.contains(label), "missing \(label)")
        }
    }
}
```

- [ ] **Step 2: Run focused iOS/mac RED.**

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination "platform=iOS Simulator,name=${WATTLINE_SIMULATOR_NAME:-Wattline-Tests-2}" CODE_SIGNING_ALLOWED=NO -only-testing:WattlineTests/RouterAdministrationDemoTests 2>&1 | tee /tmp/wattline-m5-task23-ios-red.log
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:WattlineMacTests/MacRouterAdministrationTests 2>&1 | tee /tmp/wattline-m5-task23-mac-red.log
```

Expected: missing fixture and semantic/composition assertions.

- [ ] **Step 3: Implement deterministic no-write Demo and accessibility semantics.**

`RouterAdministrationDemo.fixture(now:)` supplies fixed router/identity, at least 24 history samples, open pairing state with redacted/no persisted PIN, client metadata, complete settings, BlueZ devices, advanced values, one known rule, one unknown raw rule, and compatible `no_input_shutdown`. The model’s `.demo` factory accepts in-memory/no-op stores and never calls production Keychain, `RouterHostStore`, app-group defaults, discovery, or HTTP factories. Demo mutations alter only in-memory fixture state.

Apply identifiers and useful spoken labels at the real semantic controls/states: secret fields (`admin.secret`), chart (`history.chart`), rule/preset toggles (`rule.toggle`), destructive controls (`action.destructive` plus purpose label), stale banners (`state.stale`), unavailable states (`state.unavailable`), Demo badge (`demo.badge`), and real-device exit (`connect.real-device`). Preserve shared charge/discharge/idle colors and monospaced numerals; do not encode meaning using color alone.

- [ ] **Step 4: Run Task 23 GREEN and commit.**

```bash
swift test --package-path peakdo/apple/WattlineUI
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination "platform=iOS Simulator,name=${WATTLINE_SIMULATOR_NAME:-Wattline-Tests-2}" CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/wattline-m5-task23-ios-green.log
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/wattline-m5-task23-mac-green.log
git diff --check
git add peakdo/apple/Wattline peakdo/apple/WattlineShared peakdo/apple/WattlineUI
git commit -m "feat: complete router administration demo"
```

---

### Task 24: Final verification, audit transcript, and handoff

**Files:**
- Create: `peakdo/apple/docs/superpowers/sdd/task-24-report.md`
- Modify optionally: `peakdo/apple/docs/superpowers/sdd/task-19-report.md` only to correct `292`/`277+16` to the reviewed `293/293` facts.

**Interfaces:**
- Consumes: committed Tasks 20–23 and fresh build products/xcresults.
- Produces: exact count/evidence report and no production changes.

- [ ] **Step 1: Run every required gate with durable logs/result bundles.**

```bash
cd /Users/keith/.codex/worktrees/wattline-phase-2
swift test --package-path peakdo/apple/WattlineCore 2>&1 | tee /tmp/wattline-m5-core.log
swift test --package-path peakdo/apple/WattlineUI 2>&1 | tee /tmp/wattline-m5-ui.log
swift test --package-path peakdo/apple/WattlineNetwork 2>&1 | tee /tmp/wattline-m5-network.log
WATTLINE_SIMULATOR_NAME=${WATTLINE_SIMULATOR_NAME:-Wattline-Tests-2}
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination "platform=iOS Simulator,name=${WATTLINE_SIMULATOR_NAME}" CODE_SIGNING_ALLOWED=NO -resultBundlePath /tmp/Wattline-M5.xcresult 2>&1 | tee /tmp/wattline-m5-ios.log
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineWidgets -destination "platform=iOS Simulator,name=${WATTLINE_SIMULATOR_NAME}" CODE_SIGNING_ALLOWED=NO -resultBundlePath /tmp/WattlineWidgets-M5.xcresult 2>&1 | tee /tmp/wattline-m5-widgets.log
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -resultBundlePath /tmp/WattlineMac-M5.xcresult 2>&1 | tee /tmp/wattline-m5-mac.log
xcodebuild build -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/wattline-m5-ios-build.log
xcodebuild build -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineMac -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/wattline-m5-mac-build.log
```

Delete preexisting result paths before each command only when they are verified `/tmp/Wattline*-M5.xcresult` paths. Extract `testsCount`, failures, skips, expected failures, simulator/mac identity, OS and architecture using `xcresulttool get test-results summary` and `xcresulttool get test-results test-details`; do not infer counts from the scheme overlap. Core must remain exactly 156; all other suites may grow only through M5 tests.

- [ ] **Step 2: Run and record audits with explicit exit codes.**

```bash
rg -n 'URLSession|NWBrowser|NWConnection|import Network|import Security' peakdo/apple/WattlineCore/Sources peakdo/apple/WattlineUI/Sources; echo "boundary=$?"
rg -n 'import WattlineNetwork' peakdo/apple/WattlineUI/Sources; echo "ui_source_dependency=$?"
rg -n 'WattlineNetwork' peakdo/apple/WattlineUI/Package.swift; echo "ui_manifest_dependency=$?"
rg -n '/device/action|/device/usbc-limit|/device/bypass-threshold|/device/schedules' peakdo/apple/WattlineCore/Sources peakdo/apple/WattlineUI/Sources peakdo/apple/WattlineNetwork/Sources peakdo/apple/Wattline/Wattline peakdo/apple/Wattline/WattlineMac peakdo/apple/WattlineShared; echo "deprecated_routes=$?"
rg -n 'BLETransport|DeviceSession\(|DeviceOperationBroker' peakdo/apple/WattlineNetwork/Sources peakdo/apple/WattlineShared/RouterAdministration peakdo/apple/Wattline/WattlineMac; echo "admin_ble_owner=$?"
rg -n 'URLSession|data\(from:|data\(for:|upload\(|download\(' peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterRules.swift peakdo/apple/WattlineShared/RouterAdministration peakdo/apple/Wattline/WattlineMac; echo "app_webhook=$?"
rg -n 'api/v1/device/ota|/device/timers|/device/schedules' peakdo/apple/WattlineCore/Sources peakdo/apple/WattlineUI/Sources peakdo/apple/WattlineNetwork/Sources peakdo/apple/Wattline/Wattline peakdo/apple/Wattline/WattlineMac peakdo/apple/WattlineShared; echo "ota_timer_scope=$?"
rg -n 'print\(|debugPrint\(|dump\(|Logger\(|os_log|NSLog|token|pin|privateKey|private_key|Fingerprint\(' peakdo/apple/WattlineNetwork/Sources peakdo/apple/Wattline/Wattline peakdo/apple/Wattline/WattlineMac peakdo/apple/WattlineShared; echo "logging_scan=$?"
git diff --check 845d8529..HEAD; echo "diff_check=$?"
git status --short; echo "status=$?"
git diff --name-only 845d8529..HEAD -- peakdo/Wattline-SPEC.md peakdo/API.md peakdo/src scan.py verify.py; echo "forbidden_files=$?"
git diff 845d8529..HEAD -- peakdo/apple/WattlineCore/Sources/WattlineCore/DeviceCommand.swift peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterTransport.swift
```

No-match audits exit 1. Inspect and classify `Fingerprint(` as semantic false positives; inspect every logging/secret match individually. Confirm rule URLs only appear in the canonical CRUD client/tests and no app-originated webhook request exists.

- [ ] **Step 3: Verify ABI symbol and report.**

Locate the freshly built WattlineNetwork binary under DerivedData, then:

```bash
nm -gU "$WATTLINE_NETWORK_BINARY" | swift demangle | rg 'RouterTransport.*init.*RouterEndpoint.*RouterCredentialProvider.*RouterHTTPClient.*RouterSSEClient.*RouterConnectionClock.*RouterConnectionTiming'
```

Record the resolved binary path, matching symbol, command exit, all suite counts/identities, every Task 20–23 RED→GREEN log excerpt, commit hashes, full audit transcript, and every deviation from this plan with reason in `task-24-report.md`. Correct the optional M4 count typo in the same documentation-only report commit if touched.

- [ ] **Step 4: Commit only the verification report and stop.**

```bash
git add peakdo/apple/docs/superpowers/sdd/task-24-report.md peakdo/apple/docs/superpowers/sdd/task-19-report.md
git commit -m "docs: finalize router administration milestone 5 verification"
git status --short
```

The handoff must explicitly list live checks unit tests cannot prove: rules firing on real telemetry; router-originated webhook delivery; power-loss shutdown across real input loss/recovery; macOS Bonjour/LAN permission, launch-at-login, signing and installed widget behavior; physical BlueZ; plus all M1–M4 carried-forward unverified hardware/network checks. Stop for final review and do not start OTA or Timers.

## Plan self-review

- Spec §10 maps to Tasks 20–21; §12 milestone 5 maps to Tasks 20–24; §§2.3, 3, and 11 remain binding in the actor/model/view steps.
- Exact API fixtures, role/route semantics, mutation relists, URL-name precedence, DELETE response validation, unknown preservation, checked overflow, webhook ownership, and compatible/reset preset behavior have non-vacuous RED coverage.
- The real iOS-local model path is moved only during Task 22 into the already-existing synchronized shared root; the new mac target does not assume a nonexistent group layout.
- Every later type/signature is introduced in the preceding Interfaces/implementation block. Placeholder scan contains no deferred implementation marker.
- Task 22 has exactly one mac transport owner and no administration/BLE owner; Task 23 Demo uses injected no-op/in-memory stores; Task 24 audits these invariants and stops.

## Planned deviations from the compressed master plan

1. The widget target already supports macOS 14 and already selects `com.keithah.wattline.mac.widgets`; Task 22 embeds that existing target instead of creating or cloning a widget target.
2. `WattlineShared` already exists. Task 22 moves only the now-cross-platform administration model and adds shared Demo data there; platform views/adapters remain in their app roots.
3. The power-loss preservation guarantee is implemented in `WattlineNetwork` policy, then consumed by the app model, so no view can accidentally reconstruct and drop fields.
4. The optional running-mode P3 is capability-driven in Task 22 only if the nearby shared advanced capability input can express the device enum without changing router contracts or `DeviceCommand`.
5. The Task 19 count typo is corrected only in Task 24’s documentation-only report commit.
