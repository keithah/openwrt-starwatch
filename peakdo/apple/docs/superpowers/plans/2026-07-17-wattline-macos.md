# Wattline macOS Application Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a macOS 14+ menu-bar-first Wattline app with one transport owner, compact confirmed controls, an optional main window, Demo/Bluetooth/Router routes, and the existing snapshot-only widget.

**Architecture:** Add a dedicated macOS app/test target that consumes the reviewed packages, app-shared catalog, operation broker, and snapshot coordinator. MacAppModel owns one transport/session; MenuBarExtra and the optional NavigationSplitView observe that owner and never create their own connection path.

**Tech Stack:** Swift 6, SwiftUI MenuBarExtra, AppKit activation policy, ServiceManagement SMAppService, OSLog signposts, WidgetKit, CoreBluetooth through WattlineCore, XCTest.

## Global Constraints

- Inherit every constraint from `2026-07-17-wattline-completion.md`.
- Milestones 1–2 must be green before this plan starts.
- macOS bundle ID is `com.keithah.wattline.mac`; deployment floor is 14.0; app group is `group.com.keithah.wattline`.
- Launch as menu-bar-only/accessory by default; “Open Wattline” opens the optional window; closing it does not terminate the process.
- ServiceManagement and AppKit imports stay in the macOS app target.
- Reuse committed `CompactBatteryHero` and `CompactPortCard`; do not fork semantic colors, number formatting, telemetry, or mutation rules.
- Demo, Bluetooth, and Router must all be navigable; no Timers destination.

---

### Task 1: Add the macOS target and single-owner runtime

**Files:**
- Modify: `peakdo/apple/Wattline/Wattline.xcodeproj/project.pbxproj`
- Create: `peakdo/apple/WattlineMac/Info.plist`
- Create: `peakdo/apple/WattlineMac/WattlineMac.entitlements`
- Create: `peakdo/apple/WattlineMac/WattlineMacApp.swift`
- Create: `peakdo/apple/WattlineMac/MacAppModel.swift`
- Create: `peakdo/apple/WattlineMacTests/MacAppModelTests.swift`
- Create: `peakdo/apple/WattlineMacTests/MacDemoModeTests.swift`
- Modify: `peakdo/apple/Wattline/WattlineTests/Phase2ProjectConfigurationTests.swift`

**Interfaces:**
- Produces: `MacAppModel.start()`, `select(deviceID:route:)`, `enterDemo()`, `connectRealDevice()`, `setDC`, `setTypeCOutput`, `setBypass`, and the macOS app/test schemes.
- Consumes: device catalog milestone interfaces, `DeviceSession`, `DeviceOperationBroker`, `SnapshotCoordinator`, and `AppTransportFactories`.

- [ ] **Step 1: Write failing configuration and owner tests**

Extend project configuration tests to assert a macOS app target, macOS test target, deployment 14.0, exact bundle ID, app group, `LSUIElement = true`, WattlineCore/UI/Network dependencies, WattlineAppShared membership, and no Timers source/navigation.

```swift
func testMacModelOwnsExactlyOneSessionAcrossRouteSwitches() async throws {
    let stationA = PhysicalDeviceID(rawValue: "station-a")
    let stationB = PhysicalDeviceID(rawValue: "station-b")
    let bluetoothA = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
    let routerB = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    let factories = RecordingTransportFactories()
    let model = MacAppModel(factories: factories, catalogStore: catalogStore)
    await model.select(deviceID: stationA, route: .bluetooth(peripheralID: bluetoothA))
    await model.select(deviceID: stationB, route: .router(hostID: routerB))
    XCTAssertEqual(factories.maximumLiveTransportCount, 1)
    XCTAssertEqual(factories.connectCallers, [.macAppModel, .macAppModel])
}

func testMacDemoDrivesTelemetryAndExitsThroughOwnerTransition() async throws {
    model.enterDemo()
    try await waitUntil { model.state.battery?.level != nil }
    XCTAssertTrue(model.isDemo)
    await model.connectRealDevice()
    XCTAssertFalse(model.isDemo)
    XCTAssertEqual(factory.demoDisconnectCount, 1)
}
```

- [ ] **Step 2: Run focused tests and verify RED**

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination "platform=iOS Simulator,id=$WATTLINE_SIMULATOR_ID" CODE_SIGNING_ALLOWED=NO \
  -only-testing:WattlineTests/Phase2ProjectConfigurationTests
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineMac \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: configuration assertions and macOS scheme fail because targets/types do not exist.

- [ ] **Step 3: Add Xcode targets and metadata**

Create `WattlineMac` and `WattlineMacTests` PBXNativeTargets, products, build phases, dependencies, schemes, and target attributes. Use:

```xml
<key>LSUIElement</key><true/>
<key>CFBundleURLTypes</key>
<array><dict><key>CFBundleURLSchemes</key><array><string>wattline</string></array></dict></array>
```

The entitlement contains only the existing application group. Set `PRODUCT_BUNDLE_IDENTIFIER = com.keithah.wattline.mac`, `MACOSX_DEPLOYMENT_TARGET = 14.0`, and `SWIFT_VERSION = 6.0`.

- [ ] **Step 4: Implement MacAppModel as the sole owner**

```swift
@MainActor
@Observable
final class MacAppModel {
    private(set) var state = DeviceState()
    private(set) var capabilities = DeviceCapabilities(features: [])
    private(set) var connectionStatus: MacConnectionStatus = .disconnected(nil)
    private(set) var activeDeviceID: PhysicalDeviceID?
    private(set) var activeRoute: TransportRoute?
    private(set) var isDemo = false
    let operationBroker: DeviceOperationBroker

    static func production() -> MacAppModel
    func start()
    func select(deviceID: PhysicalDeviceID, route: TransportRoute) async
    func enterDemo()
    func connectRealDevice() async
    func setDC(_ enabled: Bool)
    func setTypeCOutput(_ enabled: Bool)
    func setBypass(_ enabled: Bool)
}

enum MacConnectionStatus: Equatable {
    case connected
    case reconnecting
    case disconnected(String?)
}
```

Mirror the reviewed AppModel ownership sequence: retire generation/scope, detach broker, disconnect old transport, attach one replacement session, then call connect only from MacAppModel. Accepted session state fans out through SnapshotCoordinator; pending mutations do not write optimistic snapshots.

- [ ] **Step 5: Run macOS owner/Demo and iOS regression tests GREEN**

Run the Step 2 commands plus `AppModelReconnectTests` and `DeviceOperationBrokerTests`. Expected: one owner per process and no iOS regression.

- [ ] **Step 6: Commit**

```bash
git add peakdo/apple/Wattline/Wattline.xcodeproj/project.pbxproj peakdo/apple/WattlineMac \
  peakdo/apple/WattlineMacTests peakdo/apple/Wattline/WattlineTests/Phase2ProjectConfigurationTests.swift
git commit -m "build: add Wattline macOS app"
```

### Task 2: Add menu title, popover controls, Dock preference, and Launch at Login

**Files:**
- Create: `peakdo/apple/WattlineMac/MenuBarPresentation.swift`
- Create: `peakdo/apple/WattlineMac/MenuBarContent.swift`
- Create: `peakdo/apple/WattlineMac/PopoverView.swift`
- Create: `peakdo/apple/WattlineMac/MacSystemAdapters.swift`
- Modify: `peakdo/apple/WattlineMac/WattlineMacApp.swift`
- Create: `peakdo/apple/WattlineMacTests/MenuBarPresentationTests.swift`
- Create: `peakdo/apple/WattlineMacTests/MacSystemAdapterTests.swift`
- Create: `peakdo/apple/WattlineMacTests/MacPopoverOperationTests.swift`

**Interfaces:**
- Produces: `MenuBarTitle.text(level:status:density:)`, `ActivationPolicyAdapter`, `LaunchAtLoginAdapter`, and popover actions through MacAppModel.
- Consumes: CompactBatteryHero, CompactPortCard, DeviceOperationBroker, authoritative pending mutations, and active catalog selection.

- [ ] **Step 1: Write failing pure and adapter tests**

```swift
XCTAssertEqual(MenuBarTitle.text(level: 84, status: .charging, density: .always), "⚡︎ 84%")
XCTAssertEqual(MenuBarTitle.text(level: 84, status: .discharging, density: .always), "84%")
XCTAssertEqual(MenuBarTitle.text(level: 84, status: .idle, density: .activeOnly), MenuBarTitle.neutralGlyph)
XCTAssertEqual(MenuBarTitle.text(level: nil, status: .idle, density: .always), MenuBarTitle.neutralGlyph)
```

With fake activation/login adapters, prove menu-only default, persisted Dock opt-in, and surfaced registration error. With a recording transport, prove a toggle shows pending, leaves confirmed telemetry unchanged on ACK, and clears only after matching telemetry.

- [ ] **Step 2: Run macOS tests and verify RED**

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineMac \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:WattlineMacTests/MenuBarPresentationTests \
  -only-testing:WattlineMacTests/MacSystemAdapterTests \
  -only-testing:WattlineMacTests/MacPopoverOperationTests
```

Expected: missing menu presentation/adapters/popover operations.

- [ ] **Step 3: Implement pure presentation and injected system adapters**

```swift
protocol ActivationPolicyAdapter: Sendable {
    @MainActor func setShowsDock(_ showsDock: Bool) -> Bool
}

protocol LaunchAtLoginAdapter: Sendable {
    @MainActor var isEnabled: Bool { get }
    @MainActor func setEnabled(_ enabled: Bool) throws
}

enum MenuBarDensity: String, Codable { case always, activeOnly }

enum MenuBarTitle {
    static let neutralGlyph = "▱"
    static func text(level: Int?, status: PowerFlow, density: MenuBarDensity) -> String
}
```

Production activation wraps `NSApplication.shared.setActivationPolicy`; login wraps `SMAppService.mainApp.register()/unregister()`. Persist Dock/density/login preferences in macOS UserDefaults. Keep adapter errors in a visible Settings string.

- [ ] **Step 4: Implement MenuBarExtra and compact popover**

```swift
@main
struct WattlineMacApp: App {
    @State private var model = MacAppModel.production()

    var body: some Scene {
        MenuBarExtra { PopoverView() } label: { MenuBarContent() }
            .menuBarExtraStyle(.window)
        Window("Wattline", id: "main") { MainWindowView() }
        Settings { MacPreferencesView() }
    }
}
```

Render route badge, active-device picker, freshness, persistent DEMO badge, “Connect a real device,” compact battery/ports, and inline pending controls. Capability-absent ports create no CompactPortCard. Add an `OSSignposter` interval beginning on click and ending only when the matching mutation disappears after authoritative telemetry.

- [ ] **Step 5: Run macOS and Core quirk tests GREEN**

Run the Step 2 command and `swift test --package-path peakdo/apple/WattlineCore --filter QuirkRegressionTests`. Expected: confirmed-only toggles and correct semantic title.

- [ ] **Step 6: Commit**

```bash
git add peakdo/apple/WattlineMac peakdo/apple/WattlineMacTests
git commit -m "feat: add Wattline menu bar controls"
```

### Task 3: Add optional main window with Home, Devices, Shortcuts, and Settings

**Files:**
- Create: `peakdo/apple/WattlineMac/MainWindowView.swift`
- Create: `peakdo/apple/WattlineMac/MacHomeView.swift`
- Create: `peakdo/apple/WattlineMac/MacDevicesView.swift`
- Create: `peakdo/apple/WattlineMac/MacSettingsView.swift`
- Create: `peakdo/apple/WattlineMacTests/MacNavigationTests.swift`
- Create: `peakdo/apple/WattlineMacTests/MacDemoSurfaceTests.swift`

**Interfaces:**
- Produces: `MacDestination.home/devices/shortcuts/settings`, optional window composition, and full macOS Devices/Settings actions.
- Consumes: MacAppModel, device catalog/discovery, shared WattlineUI views, settings presentation, and Task 2 adapters.

- [ ] **Step 1: Write failing navigation and Demo composition tests**

```swift
XCTAssertEqual(MacNavigationComposition.destinations, [.home, .devices, .shortcuts, .settings])
XCTAssertFalse(MacNavigationComposition.destinations.map(\.rawValue).contains("Timers"))
XCTAssertTrue(MacSurfaceComposition(isDemo: true).showsDemoBadge)
XCTAssertTrue(MacSurfaceComposition(isDemo: true).showsConnectRealDevice)
```

Test Devices starts/stops LAN discovery with view lifetime, route selection goes through MacAppModel, Settings omits unsupported controls, and closing window does not call app termination or disconnect.

- [ ] **Step 2: Run macOS tests and verify RED**

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineMac \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:WattlineMacTests/MacNavigationTests \
  -only-testing:WattlineMacTests/MacDemoSurfaceTests
```

Expected: missing destinations and views.

- [ ] **Step 3: Implement window navigation and shared surfaces**

Use `NavigationSplitView` with a list selection and detail switch. Home reuses BatteryHero/PortCard/StatTile; Devices reuses catalog presentation and starts RouterDiscoveryController only inside its task; Settings exposes identity, clock sync, DC/bypass, restart/shutdown, Dock/density/login preferences, and a composition slot that remains absent until the route/capability-gated Expert milestone. Shortcuts renders an explanatory destination that Task 3 of the App Intents plan replaces with the shared gallery.

```swift
enum MacDestination: String, CaseIterable, Identifiable {
    case home, devices, shortcuts, settings
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .home: "house"
        case .devices: "bolt.horizontal"
        case .shortcuts: "square.grid.2x2"
        case .settings: "gearshape"
        }
    }
}

enum MacNavigationComposition {
    static let destinations = MacDestination.allCases
}

struct MacSurfaceComposition: Equatable {
    let showsDemoBadge: Bool
    let showsConnectRealDevice: Bool
    init(isDemo: Bool) {
        showsDemoBadge = isDemo
        showsConnectRealDevice = isDemo
    }
}

struct MainWindowView: View {
    @State private var selection: MacDestination? = .home
    var body: some View {
        NavigationSplitView {
            List(MacDestination.allCases, selection: $selection) { destination in
                Label(destination.title, systemImage: destination.symbol)
            }
        } detail: {
            MacDestinationView(destination: selection ?? .home)
        }
    }
}
```

- [ ] **Step 4: Run all macOS tests and generic build GREEN**

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineMac \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineMac \
  -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 5: Commit**

```bash
git add peakdo/apple/WattlineMac peakdo/apple/WattlineMacTests
git commit -m "feat: add Wattline macOS window"
```

### Task 4: Embed and deep-link the existing widget on macOS

**Files:**
- Modify: `peakdo/apple/Wattline/Wattline.xcodeproj/project.pbxproj`
- Modify: `peakdo/apple/Wattline/WattlineWidgets/WattlineWidgetProvider.swift`
- Modify: `peakdo/apple/Wattline/WattlineTests/Phase2ProjectConfigurationTests.swift`
- Modify: `peakdo/apple/Wattline/WattlineTests/WattlineWidgetProviderTests.swift`

**Interfaces:**
- Produces: explicit Mac→WattlineWidgets target dependency/embedding and platform-correct dashboard deep links.
- Consumes: SharedDeviceSnapshot app-group provider; no transport interface.

- [ ] **Step 1: Write failing project and deep-link tests**

```swift
XCTAssertEqual(WattlineDeepLink.dashboard(platform: .iOS).absoluteString, "wattline://dashboard")
XCTAssertEqual(WattlineDeepLink.dashboard(platform: .macOS).absoluteString, "wattline://dashboard")
```

Project tests assert the macOS app explicitly embeds/dependends on WattlineWidgets, macOS extension bundle ID is `com.keithah.wattline.mac.widgets`, both use the same app group, and extension source contains no DeviceTransport/DeviceSession/BLETransport/RouterTransport construction.

- [ ] **Step 2: Run focused tests and verify RED**

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination "platform=iOS Simulator,id=$WATTLINE_SIMULATOR_ID" CODE_SIGNING_ALLOWED=NO \
  -only-testing:WattlineTests/Phase2ProjectConfigurationTests \
  -only-testing:WattlineTests/WattlineWidgetProviderTests
```

Expected: missing macOS embedding/dependency and platform deep-link type.

- [ ] **Step 3: Add explicit embedding and platform presentation**

Create a Mac app PBXTargetDependency/container proxy and Embed Foundation Extensions build file for the existing extension. Preserve `PRODUCT_BUNDLE_IDENTIFIER[sdk=macosx*] = com.keithah.wattline.mac.widgets` and app-group entitlement. Add:

```swift
enum WidgetPlatform { case iOS, macOS }
enum WattlineDeepLink {
    static func dashboard(platform: WidgetPlatform) -> URL {
        URL(string: "wattline://dashboard")!
    }
}
```

Select the compile-time platform in WattlineWidgetView. The provider still awaits SharedSnapshotStore only from snapshot/timeline methods; placeholder stays synchronous and deterministic.

- [ ] **Step 4: Run widget/macOS tests and builds GREEN**

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineWidgets \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineMac \
  -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 5: Commit**

```bash
git add peakdo/apple/Wattline/Wattline.xcodeproj/project.pbxproj \
  peakdo/apple/Wattline/WattlineWidgets/WattlineWidgetProvider.swift \
  peakdo/apple/Wattline/WattlineTests/Phase2ProjectConfigurationTests.swift \
  peakdo/apple/Wattline/WattlineTests/WattlineWidgetProviderTests.swift
git commit -m "feat: embed Wattline widgets on macOS"
```

### Task 5: macOS verification and handoff

**Files:**
- Modify: `peakdo/apple/docs/superpowers/plans/2026-07-17-wattline-macos.md` only to record evidence.

**Interfaces:**
- Produces: reviewed macOS runtime and surfaces required by galleries and Expert settings.

- [ ] **Step 1: Run all package/iOS/macOS/widget tests**

```bash
swift test --package-path peakdo/apple/WattlineCore
swift test --package-path peakdo/apple/WattlineUI
swift test --package-path peakdo/apple/WattlineNetwork
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination "platform=iOS Simulator,id=$WATTLINE_SIMULATOR_ID" CODE_SIGNING_ALLOWED=NO
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineMac \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineWidgets \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 2: Run generic builds and source audits**

```bash
xcodebuild build -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineMac \
  -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO
rg -n '^import (AppKit|ServiceManagement)$' peakdo/apple/WattlineCore peakdo/apple/WattlineUI peakdo/apple/WattlineNetwork
rg -n 'BLETransport\(|RouterTransport\(|DeviceSession\(' peakdo/apple/Wattline/WattlineWidgets
rg -n 'Timers|TimerRow|scheduledOnOff' peakdo/apple/WattlineMac
git diff --check
```

Expected: platform imports confined, widget transport-free, and no Timers.

- [ ] **Step 3: Execute macOS Demo UX checks**

Launch unsigned where permitted. Verify accessory default, persistent menu item, DEMO badge, compact telemetry, confirmed DC/USB toggles, Connect a real device, optional window navigation, Dock toggle, and visible launch-at-login errors. Closing the window must leave the menu item alive.

- [ ] **Step 4: Commit evidence and stop**

```bash
git add peakdo/apple/docs/superpowers/plans/2026-07-17-wattline-macos.md
git commit -m "test: verify Wattline macOS surfaces"
```

Report exact counts and classify signed Launch at Login, real Bluetooth permissions, real router discovery, macOS widget installation, and the signpost-measured <1.5-second hardware round trip as external. Stop for Milestone 4 approval.
