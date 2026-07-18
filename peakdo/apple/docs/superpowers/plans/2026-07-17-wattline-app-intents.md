# Wattline App Intents and Shortcuts Gallery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Toggle DC Port, Get Battery Level, and Set USB-C Limit App Intents plus honest capability-gated galleries on iOS and macOS.

**Architecture:** Keep operation projection and telemetry confirmation in AppIntents-free app-shared services. OS-instantiated intent structs resolve a launch-time registry containing the exact broker/catalog/snapshot objects owned by the active app process; they never construct transports, sessions, brokers, or reconnect loops.

**Tech Stack:** Swift 6, Foundation, AppIntents, SwiftUI, DeviceOperationBroker, SharedSnapshotStore, XCTest, Shortcuts/Siri integration.

## Global Constraints

- Inherit every constraint from `2026-07-17-wattline-completion.md`.
- Milestones 1–3 must be green before this plan starts.
- The iOS 17 floor forbids `@Dependency`/`AppDependencyManager`; use the approved launch-time registry.
- Every live operation uses the existing generation-tokened `withConnection(to:timeout:.seconds(10))` route.
- Toggle DC and Set Limit never return stale success. Get Battery alone may return a stale app-group snapshot with wall-clock age.
- DC completes only after `dcEnabled(target)` telemetry; limits complete only from the GET readback following SET.
- Unsupported intents are absent from entity/gallery composition and also reject direct invocation clearly.

---

### Task 1: Add pure intent operation results and telemetry-confirmed service

**Files:**
- Create: `peakdo/apple/WattlineAppShared/Intents/IntentOperationModels.swift`
- Create: `peakdo/apple/WattlineAppShared/Intents/IntentOperationService.swift`
- Create: `peakdo/apple/WattlineAppShared/Intents/IntentRuntimeRegistry.swift`
- Create: `peakdo/apple/Wattline/WattlineTests/IntentOperationServiceTests.swift`
- Modify: `peakdo/apple/WattlineShared/Operations/DeviceOperationBroker.swift`

**Interfaces:**
- Produces: `IntentOperationService.toggleDC`, `battery`, `setLimit`, result models, and `IntentRuntimeRegistry.register/resolve`.
- Consumes: DeviceOperationBroker, DeviceCatalogStore, SharedSnapshotStore, DeviceSession state, DeviceCommand factories.

- [ ] **Step 1: Write failing service and identity tests**

Cover on/off/toggle target derivation, unsupported capability without reconnect, write ACK without telemetry, matching DC telemetry, 10-second timeout, live battery, stale snapshot age, corrupt/absent snapshot, limit SET-then-GET, and confirmed readback differing from requested value.

```swift
let stationA = PhysicalDeviceID(rawValue: "station-a")
let completion = AsyncResultRecorder<ConfirmedDCResult>()
let task = Task {
    do {
        await completion.record(.success(try await service.toggleDC(deviceID: stationA, mode: .on)))
    } catch {
        await completion.record(.failure(error))
    }
}
try await transport.waitForCommand(.setDC(true))
XCTAssertNil(await completion.value, "write acknowledgement is not confirmation")
await transport.emit(
    .dc(try DCPortStatus(frame: Data([0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])),
    timestamp: .seconds(1)
)
try await waitUntil { await completion.value != nil }
guard case let .success(result)? = await completion.value else {
    return XCTFail("Expected telemetry-confirmed success")
}
XCTAssertTrue(result.enabled)
task.cancel()

let limit = try await service.setLimit(
    deviceID: stationA,
    type: .global,
    level: .watts140
)
XCTAssertEqual(await transport.commandBytes, [Data([0x02, 0x01, 0x01, 0x05]), Data([0x02, 0x00, 0x01])])
XCTAssertEqual(limit.confirmedLevel, .watts100)
```

Define `AsyncResultRecorder` as a private test actor holding an optional `Result<Value, Error>`;
its nil-before-telemetry assertion is the falsifiability check for ACK-only regressions.

Register the app-owned broker and assert `resolved.broker === appModel.deviceOperationBroker`. Register a second owner for a new test process context and prove replacement is explicit rather than silently constructing another broker.

- [ ] **Step 2: Run focused tests and verify RED**

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination "platform=iOS Simulator,id=$WATTLINE_SIMULATOR_ID" CODE_SIGNING_ALLOWED=NO \
  -only-testing:WattlineTests/IntentOperationServiceTests
```

Expected: missing service/models/registry.

- [ ] **Step 3: Implement result models and registry**

```swift
enum DCToggleMode: String, Codable, CaseIterable, Sendable { case on, off, toggle }

struct ConfirmedDCResult: Equatable, Sendable {
    let deviceID: PhysicalDeviceID
    let enabled: Bool
    let isSimulated: Bool
}

struct BatteryIntentResult: Equatable, Sendable {
    let deviceID: PhysicalDeviceID
    let level: UInt8
    let status: PowerFlow
    let remainingMinutes: UInt16
    let isStale: Bool
    let age: TimeInterval
    let isSimulated: Bool
}

struct ConfirmedLimitResult: Equatable, Sendable {
    let deviceID: PhysicalDeviceID
    let type: PowerLimitType
    let confirmedLevel: PowerLimitLevel
    let isSimulated: Bool
}

enum IntentRequiredCapability: Equatable, Sendable {
    case dcControl, battery, usbPowerLimit
}

struct IntentDeviceRecord: Equatable, Sendable {
    let id: PhysicalDeviceID
    let displayName: String
    let peripheralID: UUID
    let capabilities: DeviceCapabilities
    let route: TransportRoute
    let isDemo: Bool
}

protocol IntentDeviceCatalogProviding: Sendable {
    func activeDevice() async -> IntentDeviceRecord?
    func device(id: PhysicalDeviceID) async -> IntentDeviceRecord?
    func eligibleDevices(for capability: IntentRequiredCapability) async -> [IntentDeviceRecord]
}
```

`@MainActor final class IntentRuntimeRegistry` stores one `IntentRuntime` containing the app-owned broker, catalog provider, snapshot store, and wall clock. `resolve()` throws `.notRegistered` when the app has not registered; it never creates defaults.

```swift
struct IntentRuntime: Sendable {
    let broker: DeviceOperationBroker
    let catalog: any IntentDeviceCatalogProviding
    let snapshotStore: SharedSnapshotStore
    let now: @Sendable () -> Date
}

@MainActor
final class IntentRuntimeRegistry {
    static let shared = IntentRuntimeRegistry()
    private var runtime: IntentRuntime?
    func register(_ runtime: IntentRuntime)
    func resolve() throws -> IntentRuntime
    func resetForTesting()
}
```

- [ ] **Step 4: Implement the service on the existing broker**

```swift
struct IntentOperationService: Sendable {
    init(runtime: IntentRuntime)
    func toggleDC(
        deviceID: PhysicalDeviceID,
        mode: DCToggleMode
    ) async throws -> ConfirmedDCResult

    func battery(deviceID: PhysicalDeviceID) async throws -> BatteryIntentResult

    func setLimit(
        deviceID: PhysicalDeviceID,
        type: PowerLimitType,
        level: PowerLimitLevel
    ) async throws -> ConfirmedLimitResult
}
```

Resolve the selected record and capability before `withConnection`. Inside its operation closure, read `context.session.state`; perform on the same session; for DC, await matching authoritative state with a bounded continuation fed by `session.states`; for limits, decode the follow-up GET `CommandOutcome.reply.payload` and return that value. Battery first attempts live state; on connection timeout/unavailable only, read SharedSnapshotStore and compute `max(0, now.timeIntervalSince(observedAt))`.

For DC, create the generation-scoped state iterator before sending the command, then inspect
`session.state` immediately after `perform` returns before awaiting the iterator. Bound the confirmation
wait to three seconds. This ordering closes the telemetry-during-write race without accepting a write
acknowledgement as confirmation.

Add a broker helper only if needed to expose the already-owned context inside `withConnection`; do not add a second waiter registry.

- [ ] **Step 5: Run service, broker, and quirk suites GREEN**

Run Step 2 plus DeviceOperationBrokerTests and Core QuirkRegressionTests. Expected: telemetry-confirmed outcomes, exactly one broker registry, and existing quirks green.

- [ ] **Step 6: Commit**

```bash
git add peakdo/apple/WattlineAppShared/Intents peakdo/apple/WattlineShared/Operations/DeviceOperationBroker.swift \
  peakdo/apple/Wattline/WattlineTests/IntentOperationServiceTests.swift
git commit -m "feat: add Wattline intent operation service"
```

### Task 2: Add system-instantiated intents, entities, and App Shortcuts

**Files:**
- Create: `peakdo/apple/WattlineIntentSurfaces/WattlineIntentEntities.swift`
- Create: `peakdo/apple/WattlineIntentSurfaces/WattlineIntents.swift`
- Create: `peakdo/apple/WattlineIntentSurfaces/WattlineAppShortcuts.swift`
- Modify: `peakdo/apple/Wattline/Wattline.xcodeproj/project.pbxproj`
- Modify: `peakdo/apple/Wattline/Wattline/WattlineApp.swift`
- Modify: `peakdo/apple/WattlineMac/WattlineMacApp.swift`
- Create: `peakdo/apple/Wattline/WattlineTests/WattlineIntentTests.swift`
- Create: `peakdo/apple/WattlineMacTests/WattlineMacIntentRegistrationTests.swift`

**Interfaces:**
- Produces: `WattlineDeviceEntity`, entity query, three AppIntent types, and `WattlineAppShortcuts`.
- Consumes: Task 1 registry/service and device catalog eligibility.

- [ ] **Step 1: Write failing production-resolution and entity tests**

System-construct each intent with its default initializer after app startup registration and prove it resolves the exact app-owned broker object. Test active-device default, name/ID entity resolution, removed device not-found, capability filtering, and direct unsupported invocation.

```swift
let intent = ToggleDCPortIntent()
let runtime = try intent.resolveRuntimeForTesting()
let stationA = PhysicalDeviceID(rawValue: "station-a")
XCTAssertTrue(runtime.broker === model.deviceOperationBroker)
XCTAssertEqual(await query.suggestedEntities().map(\.id), [stationA.rawValue])
```

Repeat the object-identity test for MacAppModel's process registry. Assert neither query nor initializer constructs a transport/session.

- [ ] **Step 2: Run iOS/macOS focused tests and verify RED**

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination "platform=iOS Simulator,id=$WATTLINE_SIMULATOR_ID" CODE_SIGNING_ALLOWED=NO \
  -only-testing:WattlineTests/WattlineIntentTests
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineMac \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:WattlineMacTests/WattlineMacIntentRegistrationTests
```

Expected: missing AppIntent surfaces and startup registration.

- [ ] **Step 3: Implement entities and intent declarations**

```swift
struct WattlineDeviceEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Wattline Device")
    static var defaultQuery = WattlineDeviceQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { .init(title: "\(name)") }
}

enum DCToggleIntentMode: String, AppEnum, CaseIterable {
    case on, off, toggle
}

enum USBLimitTypeIntentValue: String, AppEnum, CaseIterable {
    case global, input, output
}

enum USBLimitWattageIntentValue: Int, AppEnum, CaseIterable {
    case watts30 = 30, watts45 = 45, watts60 = 60
    case watts65 = 65, watts100 = 100, watts140 = 140
}

struct ToggleDCPortIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle DC Port"
    @Parameter(title: "Device") var device: WattlineDeviceEntity?
    @Parameter(title: "State") var mode: DCToggleIntentMode
    func perform() async throws -> some IntentResult & ProvidesDialog
}

struct BatteryIntentOutput: AppEntity, Identifiable {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Battery Reading")
    static var defaultQuery = BatteryIntentOutputQuery()
    let id: String
    @Property(title: "Battery Level") var level: Int
    @Property(title: "Status") var status: String
    @Property(title: "Runtime in Minutes") var remainingMinutes: Int
    @Property(title: "Is Stale") var isStale: Bool
    @Property(title: "Age in Seconds") var age: Double
}

struct GetBatteryLevelIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Battery Level"
    @Parameter(title: "Device") var device: WattlineDeviceEntity?
    func perform() async throws
        -> some IntentResult & ReturnsValue<BatteryIntentOutput> & ProvidesDialog
}

struct SetUSBCPowerLimitIntent: AppIntent {
    static var title: LocalizedStringResource = "Set USB-C Power Limit"
    @Parameter(title: "Device") var device: WattlineDeviceEntity?
    @Parameter(title: "Limit Type") var type: USBLimitTypeIntentValue
    @Parameter(title: "Wattage") var wattage: USBLimitWattageIntentValue
    func perform() async throws -> some IntentResult & ProvidesDialog
}

#if os(iOS)
extension ToggleDCPortIntent: ForegroundContinuableIntent {}
extension SetUSBCPowerLimitIntent: ForegroundContinuableIntent {}
#endif
```

Supply the required `typeDisplayRepresentation`, `caseDisplayRepresentations`, entity-query methods,
initializers, and `perform` bodies in the named source files. The bodies resolve
`IntentRuntimeRegistry.shared`, map through `IntentOperationService`, and never instantiate an owner.
Map Global/Input/Output and 30/45/60/65/100/140 W exhaustively. Omitted device resolves the active
catalog selection. On iOS, mutation intents conform to `ForegroundContinuableIntent` and request
foreground continuation only when the existing broker reports it is required. The conditional
extensions keep that iOS-only protocol out of the macOS build; the always-running menu app uses the
same registry without a second process owner.

- [ ] **Step 4: Register runtime at launch and add shortcuts phrases**

WattlineApp and WattlineMacApp register their exact model runtime before enabling intent execution. Add localized titles and phrases such as “Get battery from ${applicationName}”, “Turn off DC with ${applicationName}”, and “Set Wattline USB C limit”. Intent dialogs include “Simulated” for Demo and explicit stale age for battery fallback.

- [ ] **Step 5: Run focused tests and both generic builds GREEN**

Run Step 2 plus generic iOS/macOS builds. Expected: default initializers resolve registered production ownership and AppIntents compile on both platform floors.

- [ ] **Step 6: Commit**

```bash
git add peakdo/apple/WattlineIntentSurfaces peakdo/apple/Wattline/Wattline.xcodeproj/project.pbxproj \
  peakdo/apple/Wattline/Wattline/WattlineApp.swift peakdo/apple/WattlineMac/WattlineMacApp.swift \
  peakdo/apple/Wattline/WattlineTests/WattlineIntentTests.swift \
  peakdo/apple/WattlineMacTests/WattlineMacIntentRegistrationTests.swift
git commit -m "feat: add Wattline app intents"
```

### Task 3: Add capability-gated iOS and macOS Shortcuts galleries

**Files:**
- Create: `peakdo/apple/WattlineUI/Sources/WattlineUI/ShortcutsGalleryPresentation.swift`
- Create: `peakdo/apple/WattlineUI/Tests/WattlineUITests/ShortcutsGalleryPresentationTests.swift`
- Create: `peakdo/apple/Wattline/Wattline/Intents/ShortcutsView.swift`
- Modify: `peakdo/apple/Wattline/Wattline/RootView.swift`
- Create: `peakdo/apple/WattlineMac/MacShortcutsView.swift`
- Modify: `peakdo/apple/WattlineMac/MainWindowView.swift`
- Create: `peakdo/apple/Wattline/WattlineUITests/WattlineShortcutsUITests.swift`
- Create: `peakdo/apple/WattlineMacTests/MacShortcutsCompositionTests.swift`

**Interfaces:**
- Produces: `ShortcutCard`, `ShortcutsGalleryPresentation`, and platform gallery views.
- Consumes: authoritative capabilities, known-device state, and App Shortcuts deep links.

- [ ] **Step 1: Write failing structural-composition tests**

```swift
let allCapabilities = DeviceCapabilities(features: [
    .batteryCapacity, .dcControl, .usbPowerLimit,
])
let batteryCapabilities = DeviceCapabilities(features: [.batteryCapacity])
XCTAssertEqual(
    ShortcutsGalleryPresentation(capabilities: allCapabilities, hasKnownDevice: true).cards,
    [.toggleDC, .getBattery, .setUSBLimit, .lowBatteryRecipe]
)
XCTAssertFalse(
    ShortcutsGalleryPresentation(capabilities: batteryCapabilities, hasKnownDevice: true)
        .cards.contains(.toggleDC)
)
XCTAssertTrue(
    ShortcutsGalleryPresentation(capabilities: nil, hasKnownDevice: false)
        .showsNoDeviceExplanation
)
```

Assert the low-battery card says iOS does not provide a third-party event trigger and describes the existing notification/time-based recipe honestly.

- [ ] **Step 2: Run UI/macOS tests and verify RED**

```bash
swift test --package-path peakdo/apple/WattlineUI --filter ShortcutsGalleryPresentationTests
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineMac \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:WattlineMacTests/MacShortcutsCompositionTests
```

Expected: missing gallery types and macOS view composition.

- [ ] **Step 3: Implement shared presentation and platform views**

```swift
public enum ShortcutCard: Equatable, Sendable {
    case toggleDC, getBattery, setUSBLimit, lowBatteryRecipe
}

public struct ShortcutsGalleryPresentation: Equatable, Sendable {
    public let cards: [ShortcutCard]
    public let showsNoDeviceExplanation: Bool
    public init(capabilities: DeviceCapabilities?, hasKnownDevice: Bool)
}
```

When no known device exists, show explanation/connection guidance. Once capabilities are known, omit unsupported cards from the ForEach data. Cards open the OS Shortcuts surface or expose the registered App Shortcut; no card directly calls a transport. Demo copy says simulated.

- [ ] **Step 4: Replace placeholders and drive Demo UI**

Replace the iOS Shortcuts PlaceholderView and macOS empty detail with the galleries. Add UI launch fixtures for full, battery-only, and Demo capabilities. Assert no Timers tab/destination appears.

- [ ] **Step 5: Run UI, app, macOS, and package suites GREEN**

Run Step 2, the full WattlineUI suite, full iOS app scheme, and full macOS scheme.

- [ ] **Step 6: Commit**

```bash
git add peakdo/apple/WattlineUI peakdo/apple/Wattline/Wattline/Intents \
  peakdo/apple/Wattline/Wattline/RootView.swift peakdo/apple/WattlineMac \
  peakdo/apple/Wattline/WattlineUITests/WattlineShortcutsUITests.swift
git commit -m "feat: add Wattline Shortcuts galleries"
```

### Task 4: App Intents verification and handoff

**Files:**
- Modify: `peakdo/apple/docs/superpowers/plans/2026-07-17-wattline-app-intents.md` only to record evidence.

**Interfaces:**
- Produces: reviewed intents and gallery surfaces required by final verification.

- [ ] **Step 1: Run all deterministic suites and builds**

Run all three package suites, full iOS/macOS/widget tests, and generic iOS/macOS builds using the commands from prior milestone handoffs. Record exact counts.

- [ ] **Step 2: Run ownership and boundary audits**

```bash
rg -n 'BLETransport\(|RouterTransport\(|DeviceSession\(|func connect\(' \
  peakdo/apple/WattlineIntentSurfaces peakdo/apple/WattlineAppShared/Intents peakdo/apple/WattlineUI
rg -n '^import AppIntents$' peakdo/apple/WattlineCore peakdo/apple/WattlineUI peakdo/apple/WattlineNetwork
rg -n 'URLSession|NWBrowser|NWConnection' peakdo/apple/WattlineIntentSurfaces peakdo/apple/WattlineAppShared/Intents
git diff --check
```

Expected: no intent-owned transport/connect/network path and no forbidden package import.

- [ ] **Step 3: Exercise Demo intents where the OS permits**

Install the app, enter Demo, run all three shortcuts, and verify simulated labels plus telemetry-confirmed DC/limit outcomes. Capture Shortcuts output or state why OS integration was unavailable.

- [ ] **Step 4: Commit evidence and stop**

```bash
git add peakdo/apple/docs/superpowers/plans/2026-07-17-wattline-app-intents.md
git commit -m "test: verify Wattline app intents"
```

Report exact counts and classify signed Shortcuts-app discovery, Siri phrases, foreground continuation, and real out-of-range 10-second reconnect as external. Stop for Milestone 5 approval.
