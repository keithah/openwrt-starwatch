# Wattline Device Catalog and Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give iOS a persistent physical-device catalog that correlates Bluetooth and router routes, actively discovers `_wattline._tcp`, and switches exactly one active device/session at a time.

**Architecture:** Add Foundation-only app-shared catalog models and persistence compiled into app/test targets but excluded from widgets. Extend the existing injected router discovery seam with connectable metadata, then make AppModel the sole route-switch owner and render one deduplicated Devices surface with Bluetooth preferred and Router under Advanced.

**Tech Stack:** Swift 6, Foundation, Observation, CoreBluetooth through WattlineCore, Network.framework through WattlineNetwork, SwiftUI, XCTest.

## Global Constraints

- Inherit every constraint from `2026-07-17-wattline-completion.md`.
- Milestone 1 baseline must be green before this plan starts.
- Identity is MAC-first; CID is fallback only when MAC cannot be compared; different valid MACs never merge.
- One physical record may contain multiple route descriptors, but AppModel owns one active transport/session.
- Bluetooth is selected by default when currently available; Router is explicit under Advanced; no automatic failover.
- Discovery starts only while Devices/Scan is in the view tree and never calls `connect()`.
- Tokens remain only in Keychain; catalog persistence contains no bearer token.

---

### Task 1: Add app-shared physical-device models and versioned persistence

**Files:**
- Create: `peakdo/apple/WattlineAppShared/Devices/ConnectionCatalogModels.swift`
- Create: `peakdo/apple/WattlineAppShared/Devices/ConnectionCatalogReducer.swift`
- Create: `peakdo/apple/WattlineAppShared/Devices/DeviceCatalogStore.swift`
- Create: `peakdo/apple/WattlineAppShared/Devices/DevicePersistenceModels.swift`
- Create: `peakdo/apple/Wattline/WattlineTests/ConnectionCatalogTests.swift`
- Modify: `peakdo/apple/Wattline/Wattline/AppModel.swift`
- Modify: `peakdo/apple/Wattline/Wattline/AppPersistence.swift`
- Modify: `peakdo/apple/Wattline/Wattline.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `PhysicalDeviceID`, `TransportRoute`, `SavedDeviceIdentity`, `SavedPhysicalDevice`, `PhysicalDeviceRecord`, `ConnectionCatalogReducer.merge`, and `DeviceCatalogStore`.
- Consumes: `DeviceIdentitySnapshot`, `DiscoveredDevice`, `RouterHostMetadata`, and `DeviceIdentityDeduplicator`.

- [ ] **Step 1: Write failing catalog and persistence tests**

Cover normalized MAC merge, CID fallback when one side lacks MAC, distinct valid MAC separation, Bluetooth preference, Demo isolation, auto-reconnect persistence, corrupt-record dropping, and token absence.

```swift
func testMACFirstMergePrefersBluetoothButRetainsRouterRoute() throws {
    let bluetoothID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
    let routerHostID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    let bluetooth = BluetoothDeviceCandidate(
        discovery: DiscoveredDevice(
            id: bluetoothID,
            localName: "PeakDo Link-Power",
            rssi: -48,
            mode: .application
        ),
        identity: makeIdentity(
            peripheralID: bluetoothID,
            mac: "DC:04:5A:EB:72:2B",
            cid: 0x0101
        )
    )
    let router = RouterDeviceCandidate(
        identity: makeIdentity(
            peripheralID: routerHostID,
            mac: "dc-04-5a-eb-72-2b",
            cid: 0x0101
        ),
        host: makeRouterHost(id: routerHostID),
        discovered: nil
    )
    let records = ConnectionCatalogReducer.merge(
        saved: [],
        bluetooth: [bluetooth],
        routers: [router]
    )
    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(records[0].preferredAvailableRoute, .bluetooth(peripheralID: bluetoothID))
    XCTAssertEqual(Set(records[0].routes.map(\.kind)), [.bluetooth, .router])
}

func testInactiveAutoReconnectNeverMakesRouteActive() async throws {
    let stationA = PhysicalDeviceID(rawValue: "station-a")
    let stationB = PhysicalDeviceID(rawValue: "station-b")
    let bluetoothID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
    let store = DeviceCatalogStore(backend: MemoryDeviceCatalogBackend())
    try await store.save(makeSavedDevice(id: stationA, autoReconnect: true))
    try await store.save(makeSavedDevice(id: stationB, autoReconnect: true))
    try await store.select(stationA, route: .bluetooth(peripheralID: bluetoothID))
    let selection = await store.activeSelection()
    XCTAssertEqual(selection?.deviceID, stationA)
}
```

Define `makeIdentity`, `makeRouterHost`, and `makeSavedDevice` as private test helpers in
`ConnectionCatalogTests.swift`. Each helper must call the production initializer with every field
spelled out; no fixture-only production API is added. Encode the store and assert its UTF-8 JSON
contains no test bearer token string.

- [ ] **Step 2: Run focused tests and verify RED**

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination "platform=iOS Simulator,id=$WATTLINE_SIMULATOR_ID" \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:WattlineTests/ConnectionCatalogTests
```

Expected: compile failure because the catalog types do not exist.

- [ ] **Step 3: Implement the models and reducer**

Use these public app-shared shapes:

```swift
struct PhysicalDeviceID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String
}

enum TransportRouteKind: String, Codable, Hashable, Sendable {
    case bluetooth, router, demo
}

enum TransportRoute: Codable, Hashable, Sendable {
    case bluetooth(peripheralID: UUID)
    case router(hostID: UUID)
    case demo

    var kind: TransportRouteKind {
        switch self {
        case .bluetooth: .bluetooth
        case .router: .router
        case .demo: .demo
        }
    }
}

struct SavedDeviceIdentity: Codable, Equatable, Sendable {
    let advertisedName: String
    let deviceInformationName: String?
    let macAddress: String?
    let modelNumber: String?
    let hardwareRevision: String?
    let otaFirmwareRevision: String?
    let appFirmwareRevision: String?
    let cid: UInt16?
    let rawFeatures: UInt32?
    let isOTAMode: Bool?
}

struct SavedPhysicalDevice: Codable, Equatable, Sendable {
    let id: PhysicalDeviceID
    var identity: SavedDeviceIdentity
    var routes: Set<TransportRoute>
    var preferredRoute: TransportRoute?
    var autoReconnect: Bool
    var persistedState: PersistedDeviceState?
}

struct DeviceRouteRecord: Equatable, Sendable {
    let route: TransportRoute
    let isAvailable: Bool
}

struct RouterDeviceCandidate: Equatable, Sendable {
    let identity: DeviceIdentitySnapshot?
    let host: RouterHostMetadata?
    let discovered: DiscoveredRouter?
}

struct BluetoothDeviceCandidate: Equatable, Sendable {
    let discovery: DiscoveredDevice
    let identity: DeviceIdentitySnapshot?
}

struct PhysicalDeviceRecord: Identifiable, Equatable, Sendable {
    let id: PhysicalDeviceID
    let identity: SavedDeviceIdentity
    let routes: [DeviceRouteRecord]
    let preferredAvailableRoute: TransportRoute?
    let autoReconnect: Bool
}

struct ActiveDeviceSelection: Codable, Equatable, Sendable {
    let deviceID: PhysicalDeviceID
    let route: TransportRoute
}

enum ConnectionCatalogReducer {
    static func merge(
        saved: [SavedPhysicalDevice],
        bluetooth: [BluetoothDeviceCandidate],
        routers: [RouterDeviceCandidate]
    ) -> [PhysicalDeviceRecord]
}
```

`ConnectionCatalogReducer.merge` uses `DeviceIdentityDeduplicator.normalizedMAC` and its existing merge rule. Provide `typealias CachedIdentity = SavedDeviceIdentity` inside AppModel during migration so existing settings and row code retain source compatibility.

- [ ] **Step 4: Implement versioned storage and project membership**

`DeviceCatalogStore` is an actor over an injected synchronous `DeviceCatalogKeyValueStore`; schema version is `1`; absent/corrupt/unknown-version data yields an empty catalog. Production uses a UserDefaults backend in the app process. Add `WattlineAppShared` to iOS app/tests, and explicitly exclude it from `WattlineWidgets`.

```swift
protocol DeviceCatalogKeyValueStore: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data, forKey key: String)
    func removeValue(forKey key: String)
}

actor DeviceCatalogStore {
    func devices() -> [SavedPhysicalDevice]
    func activeSelection() -> ActiveDeviceSelection?
    func save(_ device: SavedPhysicalDevice) throws
    func select(_ id: PhysicalDeviceID, route: TransportRoute) throws
    func remove(_ id: PhysicalDeviceID) throws
}
```

Migrate legacy AppPersistence device envelopes lossily into the catalog and keep NaN/Infinity telemetry strategies. Do not delete router credentials during migration.

Move `PersistedObservation` and `PersistedDeviceState` from the iOS-only AppPersistence file into `DevicePersistenceModels.swift` so both iOS and macOS catalog records compile against the same Codable telemetry envelope. The move preserves field names and custom floating-point behavior; do not duplicate the types in two targets.

- [ ] **Step 5: Run focused and persistence suites GREEN**

Run the Step 2 command plus `AppModelReconnectTests`. Expected: catalog tests pass and legacy known-device decoding remains green.

- [ ] **Step 6: Commit**

```bash
git add peakdo/apple/WattlineAppShared peakdo/apple/Wattline/Wattline.xcodeproj/project.pbxproj \
  peakdo/apple/Wattline/Wattline/AppModel.swift peakdo/apple/Wattline/Wattline/AppPersistence.swift \
  peakdo/apple/Wattline/WattlineTests/ConnectionCatalogTests.swift
git commit -m "feat: add Wattline device catalog"
```

### Task 2: Make router discovery produce safe connectable candidates

**Files:**
- Modify: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterDiscovery.swift`
- Modify: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/DiscoveryAndCredentialsTests.swift`
- Create: `peakdo/apple/WattlineAppShared/Devices/RouterDiscoveryController.swift`
- Create: `peakdo/apple/Wattline/WattlineTests/RouterDiscoveryControllerTests.swift`

**Interfaces:**
- Produces: `DiscoveredRouter.authority`, `scheme`, `port`, `certificateFingerprint`, and `RouterDiscoveryController.start()/stop()`.
- Consumes: `RouterDiscovery.routers()` and `RouterHostValidator`.

- [ ] **Step 1: Write failing parser and lifecycle tests**

Add vectors with TXT keys `id`, `authority`, `scheme`, `port`, and `fingerprint`. Prove malformed port/scheme/authority produces a visible but non-connectable discovery record, duplicate normalized IDs collapse, and stopping the controller cancels the injected source exactly once.

```swift
XCTAssertEqual(router.deviceID, "DC045AEB722B")
XCTAssertEqual(router.authority, "wattline-router.local")
XCTAssertEqual(router.port, 8377)
XCTAssertEqual(router.scheme, "http")
XCTAssertNotNil(router.endpoint)

controller.start()
await source.yield([record])
try await waitUntil { controller.routers.count == 1 }
controller.stop()
XCTAssertEqual(await source.cancellationCount, 1)
XCTAssertEqual(await source.connectionCount, 0)
```

- [ ] **Step 2: Run focused tests and verify RED**

```bash
swift test --package-path peakdo/apple/WattlineNetwork --filter RouterDiscoveryTests
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination "platform=iOS Simulator,id=$WATTLINE_SIMULATOR_ID" CODE_SIGNING_ALLOWED=NO \
  -only-testing:WattlineTests/RouterDiscoveryControllerTests
```

Expected: missing discovery metadata and controller compile failures.

- [ ] **Step 3: Extend the injected discovery mapping**

Add optional fields so older advertisements remain listable without guessing a destination:

```swift
public struct DiscoveredRouter: Equatable, Sendable, Identifiable {
    public let deviceID: String
    public let serviceName: String
    public let domain: String
    public let authority: String?
    public let scheme: String?
    public let port: Int?
    public let certificateFingerprint: String?
    public var endpoint: RouterEndpoint? {
        guard let authority, let scheme, let port else { return nil }
        return RouterEndpoint(
            scheme: scheme,
            host: authority,
            port: port,
            certificateFingerprint: certificateFingerprint,
            allowsInsecureWAN: false
        )
    }
}
```

Only `http` and `https` are accepted. A missing connectable authority/scheme/port never falls back to an invented address; the UI will offer manual setup. `NWBrowserRouterDiscoverySource` continues to browse `_wattline._tcp` and parses only documented TXT metadata.

- [ ] **Step 4: Implement the controller**

`@MainActor @Observable final class RouterDiscoveryController` owns one cancellable stream task, stores the latest records, clears only ephemeral results on stop, and exposes a distinct discovery error. It does not construct RouterTransport or call connect.

```swift
@MainActor
@Observable
final class RouterDiscoveryController {
    private(set) var routers: [DiscoveredRouter] = []
    private(set) var error: RouterDiscoveryPresentationError?
    private var task: Task<Void, Never>?

    init(discovery: RouterDiscovery)
    func start()
    func stop()
}

enum RouterDiscoveryPresentationError: Error, Equatable {
    case browserStopped
    case permissionDenied
    case failed(String)
}
```

- [ ] **Step 5: Run both focused suites and full WattlineNetwork GREEN**

Run the Step 2 commands and `swift test --package-path peakdo/apple/WattlineNetwork`. Expected: zero failures and no real network access in tests.

- [ ] **Step 6: Commit**

```bash
git add peakdo/apple/WattlineNetwork peakdo/apple/WattlineAppShared/Devices/RouterDiscoveryController.swift \
  peakdo/apple/Wattline/WattlineTests/RouterDiscoveryControllerTests.swift
git commit -m "feat: activate Wattline LAN discovery"
```

### Task 3: Route all device switching through AppModel's single owner

**Files:**
- Create: `peakdo/apple/WattlineAppShared/Devices/AppTransportFactories.swift`
- Modify: `peakdo/apple/Wattline/Wattline/AppModel.swift`
- Modify: `peakdo/apple/Wattline/Wattline/RouterConnectionModel.swift`
- Create: `peakdo/apple/Wattline/WattlineTests/ActiveDeviceSwitchingTests.swift`

**Interfaces:**
- Produces: `AppModel.select(deviceID:route:)`, `removeDevice(_:)`, `setAutoReconnect(_:for:)`, and `catalogRecords`.
- Consumes: Task 1 catalog/store, Task 2 discovery controller, existing `attach(transport:)`, and RouterConnectionModel transport factory.

- [ ] **Step 1: Write failing one-owner and stale-generation tests**

Use recording Demo/Bluetooth/Router transports. Connect A, begin a delayed callback for A, switch to B, then release A. Assert A disconnects once, B connects once, B remains selected/live, and A's callback cannot mutate B.

```swift
let stationA = PhysicalDeviceID(rawValue: "station-a")
let stationB = PhysicalDeviceID(rawValue: "station-b")
let bluetoothA = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
let routerB = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
await model.select(deviceID: stationA, route: .bluetooth(peripheralID: bluetoothA))
try await waitUntil { model.connectionStatus == .connected }
let oldGeneration = model.transportGenerationForTesting
await model.select(deviceID: stationB, route: .router(hostID: routerB))
await transportA.releaseLateBattery()
XCTAssertEqual(model.activeDeviceID, stationB)
XCTAssertNotEqual(model.transportGenerationForTesting, oldGeneration)
XCTAssertEqual(factory.maximumLiveTransportCount, 1)
XCTAssertEqual(model.state.battery?.level, 84)
```

Also prove Router cannot be selected when its discovered record lacks a saved token/host, inactive auto-reconnect never connects, and Demo is never persisted as a real physical record. Add a removal regression: removing a physical record deletes every referenced RouterHost through `RouterConnectionModel.remove(_:)`, which deletes the matching Keychain token, while sending no station command.

- [ ] **Step 2: Run focused tests and verify RED**

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination "platform=iOS Simulator,id=$WATTLINE_SIMULATOR_ID" CODE_SIGNING_ALLOWED=NO \
  -only-testing:WattlineTests/ActiveDeviceSwitchingTests
```

Expected: missing unified selection API and catalog projection.

- [ ] **Step 3: Add the transport factory registry**

```swift
@MainActor
struct AppTransportFactories {
    let bluetooth: () -> any DeviceTransport
    let demo: () -> DemoTransport
    let router: (RouterHostMetadata) throws -> any DeviceTransport
}
```

The registry constructs transports only when AppModel selects a route; it never calls connect and is not available to widgets, intents, discovery, or catalogs.

- [ ] **Step 4: Implement the ordered switch**

`select(deviceID:route:)` performs this exact order: invalidate broker lifecycle; retire the active scope/generation; cancel current operations; request old transport disconnect; construct one replacement transport; call existing `attach`; persist selection; create the new scope; attach broker context; call replacement `connect`; accept only the replacement generation. On failure, return to Devices with an explicit error and do not try another route.

`removeDevice(_:)` first collects the record's router host IDs, removes those hosts through RouterConnectionModel so credentials are deleted, removes the catalog record, and returns to Devices if it was active. `setAutoReconnect(_:for:)` mutates only catalog persistence and never starts a connection.

Keep `enterDemo`, `choose`, and `connectViaRouter` as thin compatibility wrappers that call the unified selector until UI call sites migrate in Task 4.

- [ ] **Step 5: Run switching, reconnect, broker, and router wiring suites GREEN**

Run the Step 2 command plus `AppModelReconnectTests`, `DeviceOperationBrokerTests`, and `RouterAppWiringTests`. Expected: one owner, no stale callback mutation, and no automatic failover.

- [ ] **Step 6: Commit**

```bash
git add peakdo/apple/WattlineAppShared/Devices/AppTransportFactories.swift \
  peakdo/apple/Wattline/Wattline/AppModel.swift peakdo/apple/Wattline/Wattline/RouterConnectionModel.swift \
  peakdo/apple/Wattline/WattlineTests/ActiveDeviceSwitchingTests.swift
git commit -m "feat: switch one active Wattline device"
```

### Task 4: Render the deduplicated iOS Devices surface and active picker

**Files:**
- Create: `peakdo/apple/WattlineAppShared/Devices/DeviceCatalogPresentation.swift`
- Create: `peakdo/apple/Wattline/WattlineTests/DeviceCatalogPresentationTests.swift`
- Modify: `peakdo/apple/Wattline/Wattline/ScanView.swift`
- Modify: `peakdo/apple/Wattline/Wattline/RootView.swift`
- Modify: `peakdo/apple/Wattline/Wattline/DashboardView.swift`
- Create: `peakdo/apple/Wattline/WattlineUITests/WattlineDeviceSwitcherUITests.swift`

**Interfaces:**
- Produces: Devices rows tagged BT/Router/Demo, active-device picker, auto-reconnect toggle, Advanced route menu, and discovered-router manual-save affordance.
- Consumes: `PhysicalDeviceRecord`, AppModel Task 3 selection APIs, and Router setup/Keychain flow.

- [ ] **Step 1: Write failing composition and UI tests**

```swift
let stationA = PhysicalDeviceID(rawValue: "station-a")
let bluetoothA = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
let routerA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
let presentation = DeviceCatalogPresentation(records: [mergedRecord], activeID: stationA)
XCTAssertEqual(presentation.rows.count, 1)
XCTAssertEqual(presentation.rows[0].routeBadges, [.bluetooth, .router])
XCTAssertEqual(presentation.rows[0].primaryAction, .connect(.bluetooth(peripheralID: bluetoothA)))
XCTAssertEqual(presentation.rows[0].advancedActions, [.connect(.router(hostID: routerA))])
```

UI tests must prove the picker is absent for one saved device, present for two, Demo carries a persistent DEMO badge, and a discovered non-connectable router opens prefilled manual setup rather than attempting connection.

- [ ] **Step 2: Run focused UI tests and verify RED**

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination "platform=iOS Simulator,id=$WATTLINE_SIMULATOR_ID" CODE_SIGNING_ALLOWED=NO \
  -only-testing:WattlineTests/DeviceCatalogPresentationTests
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination "platform=iOS Simulator,id=$WATTLINE_SIMULATOR_ID" CODE_SIGNING_ALLOWED=NO \
  -only-testing:WattlineUITests/WattlineDeviceSwitcherUITests
```

Expected: missing presentation and switcher UI.

- [ ] **Step 3: Implement pure presentation composition**

`DeviceCatalogPresentation` sorts active first, then known, then signal/name; emits one row per physical record; chooses Bluetooth for the primary action only when available; and emits Router only in Advanced when Bluetooth is also available. Unsupported actions are omitted from arrays.

```swift
public enum DeviceCatalogAction: Equatable, Sendable {
    case connect(TransportRoute)
    case configureDiscoveredRouter(deviceID: String)
}

public struct DeviceCatalogRow: Identifiable, Equatable, Sendable {
    public let id: PhysicalDeviceID
    public let title: String
    public let routeBadges: [TransportRouteKind]
    public let primaryAction: DeviceCatalogAction?
    public let advancedActions: [DeviceCatalogAction]
    public let autoReconnect: Bool
}

public struct DeviceCatalogPresentation: Equatable, Sendable {
    public let rows: [DeviceCatalogRow]
    public init(records: [PhysicalDeviceRecord], activeID: PhysicalDeviceID?)
}
```

- [ ] **Step 4: Replace split Bluetooth/router lists with catalog rows**

Start discovery from `ScanView.task` and stop it on task cancellation. Preserve manual VPN/Tailscale/WAN setup, insecure-WAN warning, Keychain token storage, Bluetooth permission explainer, OTA-mode identification copy, and Demo entry. Add per-device removal and auto-reconnect controls.

In the connected dashboard toolbar, show an active-device picker only when `catalogRecords.count > 1`; selecting another record calls Task 3's unified selector.

When manual setup was opened from a discovered router, prefill its normalized ID, authority/port, scheme, and fingerprint. If the user edits a saved HTTPS fingerprint to a value that differs from discovery, call `RouterHostValidator.validateCertificateFingerprint` and reject the save; never silently replace the pin.

- [ ] **Step 5: Run UI, app, and package suites GREEN**

Run the Step 2 commands, all WattlineUI tests, and the full Wattline app scheme. Expected: structurally deduplicated rows, no Timers tab, and existing Demo/Settings UI tests remain green.

- [ ] **Step 6: Commit**

```bash
git add peakdo/apple/WattlineAppShared/Devices/DeviceCatalogPresentation.swift \
  peakdo/apple/Wattline/WattlineTests/DeviceCatalogPresentationTests.swift \
  peakdo/apple/Wattline/Wattline/ScanView.swift \
  peakdo/apple/Wattline/Wattline/RootView.swift peakdo/apple/Wattline/Wattline/DashboardView.swift \
  peakdo/apple/Wattline/WattlineUITests/WattlineDeviceSwitcherUITests.swift
git commit -m "feat: add Wattline device switcher UI"
```

### Task 5: Device catalog verification and handoff

**Files:**
- Modify: `peakdo/apple/docs/superpowers/plans/2026-07-17-wattline-device-catalog.md` only to record counts/evidence.

**Interfaces:**
- Produces: reviewed Milestone 2 interfaces required by macOS and App Intents.

- [ ] **Step 1: Run package and complete iOS suites**

```bash
swift test --package-path peakdo/apple/WattlineCore
swift test --package-path peakdo/apple/WattlineUI
swift test --package-path peakdo/apple/WattlineNetwork
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination "platform=iOS Simulator,id=$WATTLINE_SIMULATOR_ID" CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 2: Run a generic iOS build and boundary audits**

```bash
xcodebuild build -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
rg -n 'URLSession|NWBrowser|NWConnection|import Network|import Security' \
  peakdo/apple/WattlineCore/Sources peakdo/apple/WattlineUI/Sources
rg -n 'BLETransport\(|RouterTransport\(' peakdo/apple/WattlineAppShared peakdo/apple/Wattline/WattlineWidgets
git diff --check
```

Expected: networking boundary clean; no widget/app-shared transport owner; AppModel is the only iOS connect caller.

- [ ] **Step 3: Exercise Demo switching**

On the simulator, save two fixture devices through test launch data, switch real-selection → Demo → saved selection, and confirm stale callbacks do not replace the active name/state. Record screenshots or UI-test attachments.

- [ ] **Step 4: Commit evidence and stop**

```bash
git add peakdo/apple/docs/superpowers/plans/2026-07-17-wattline-device-catalog.md
git commit -m "test: verify Wattline device catalog"
```

Report exact counts and classify real `_wattline._tcp` advertisement metadata, Bluetooth/router correlation against one station, Local Network permission, TLS fingerprint, and real Keychain behavior as external. Stop for Milestone 3 approval.
