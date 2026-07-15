# Wattline Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Build Wattline Phase 2 F9 and F11–F16 across iOS 17+, macOS 14+, widgets, Live Activities, App Intents, and low-battery notifications while explicitly removing F10 Schedules and the Timers tab.

**Architecture:** Extend the Phase 1 engine with pure policies and a versioned app-group snapshot in WattlineCore, reusable presentation components in WattlineUI, and thin platform coordinators in the iOS app, macOS app, and WidgetKit extension. Each app process owns one BLE transport/session; widgets are read-only, and intents plus notification actions enter through one actor-isolated operation broker.

**Tech Stack:** Swift 6, SwiftUI, CoreBluetooth, ActivityKit, WidgetKit, AppIntents, UserNotifications, ServiceManagement, XCTest, Swift Package Manager, Xcode 17.

## Global Constraints

- Read /Users/keith/src/peakdo/Wattline-SPEC.md and /Users/keith/src/peakdo/API.md as authoritative; never edit them or /Users/keith/src/peakdo/src.
- F10 Schedules and the Timers tab are removed. Do not add timer codec, CRUD, UI, Demo behavior, or tests.
- Reuse DeviceTransport, DeviceSession, SerializedTransactions, MutationReconciler, DemoTransport, and ReplayTransport. Do not create a second BLE stack.
- WattlineCore must not import SwiftUI, UIKit, ActivityKit, WidgetKit, AppIntents, UserNotifications, or ServiceManagement.
- Add no networking, URLSession, web sockets, CDN calls, ATS exceptions, or OTA installation code.
- Keep iOS at 17.0+ and set macOS to 14.0+.
- Use app IDs com.keithah.wattline and com.keithah.wattline.mac. The shared widget target uses com.keithah.wattline.widgets on iOS and com.keithah.wattline.mac.widgets on macOS. Use app group group.com.keithah.wattline.
- Telemetry or confirmed readback is authoritative. Never update device state or snapshots optimistically.
- Preserve bypass's 10-second reconciliation, Type-C mode reconciliation, power-limit readback, and disconnect-as-success including write-error-while-disconnecting.
- Unsupported capability UI must be absent from composition, not disabled or hidden.
- Use green for charging, orange for discharging, neutral for idle, and monospaced numeric telemetry.
- Run focused red/green tests for every task. Run complete clean suites and audits after each milestone.
- Stop after each milestone handoff and ask permission before starting the next milestone.

## File and Interface Map

WattlineCore additions:

- Codec/CurrentTimeCodec.swift: verified 10-byte encode and optional standard decode.
- Snapshot/SharedDeviceSnapshot.swift: versioned cross-process model.
- Snapshot/SharedSnapshotStore.swift: actor store over an injected key-value backend.
- Snapshot/SnapshotPolicies.swift: material-change, staleness, and reload-throttle decisions.
- SystemSurfaces/LiveActivityPolicy.swift: pure lifecycle state machine.
- SystemSurfaces/LowBatteryPolicy.swift: pure threshold/hysteresis state machine.

WattlineUI additions:

- SettingsSections.swift: capability-composed Settings descriptors.
- CompactDeviceViews.swift: compact macOS hero and port presentation.
- SystemSurfacePresentation.swift: shared runtime, status, and staleness formatting.
- ShortcutsGallery.swift: capability-composed gallery cards.

Shared app-source additions with explicit membership in the iOS and macOS apps:

- WattlineShared/Operations/DeviceOperationBroker.swift: sole command/reconnect entry for Settings, notification actions, and intents.
- WattlineShared/Snapshots/SnapshotCoordinator.swift: session-to-app-group reducer and fan-out source.

iOS-only app additions:

- Settings/SettingsView.swift and SettingsPresentation.swift.
- Notifications/LowBatteryNotificationCoordinator.swift.
- Activities/LiveActivityCoordinator.swift.
- Intents/WattlineIntents.swift, WattlineIntentEntities.swift, and ShortcutsView.swift.

New targets:

- WattlineWidgets: iOS/macOS WidgetKit extension plus iOS ActivityConfiguration.
- WattlineMac: macOS MenuBarExtra app, popover, optional window, and system adapters.

---

# Milestone 1 — Settings (F9)

### Task 1: Optional Current Time read and manual sync

**Files:**
- Create: peakdo/apple/WattlineCore/Sources/WattlineCore/Codec/CurrentTimeCodec.swift
- Modify: peakdo/apple/WattlineCore/Sources/WattlineCore/Device/Handshake.swift
- Modify: peakdo/apple/WattlineCore/Sources/WattlineCore/Transport/DeviceTransport.swift
- Modify: peakdo/apple/WattlineCore/Sources/WattlineCore/BLE/BLETransport.swift
- Modify: peakdo/apple/WattlineCore/Sources/WattlineCore/BLE/BluetoothDelegateBridge.swift
- Modify: peakdo/apple/WattlineCore/Sources/WattlineCore/Transport/DemoTransport.swift
- Modify: peakdo/apple/WattlineCore/Sources/WattlineCore/Transport/ReplayTransport.swift
- Test: peakdo/apple/WattlineCore/Tests/WattlineCoreTests/CurrentTimeCodecTests.swift
- Test: peakdo/apple/WattlineCore/Tests/WattlineCoreTests/ReplayTransportTests.swift

**Interfaces:**
- Produces CurrentTimeCodec.encode, CurrentTimeCodec.decode, DeviceTransport.synchronizeDeviceTime, and DeviceTransport.readDeviceTimeIfSupported.
- Uses the existing SerializedTransactions queue and bridge read/write primitives.

- [ ] **Step 1: Write the failing codec tests**

    func testCurrentTimeRoundTripsTenByteStandardValue() throws {
        let calendar = Calendar(identifier: .gregorian)
        let date = Date(timeIntervalSince1970: 1_720_951_445.5)
        let bytes = CurrentTimeCodec.encode(date, calendar: calendar, adjustReason: 0)
        XCTAssertEqual(bytes.count, 10)
        XCTAssertEqual(
            try CurrentTimeCodec.decode(bytes, calendar: calendar).timeIntervalSince1970,
            date.timeIntervalSince1970,
            accuracy: 1.0 / 256.0
        )
    }

    func testCurrentTimeDecodeRejectsEveryTruncatedPrefix() {
        let valid = Data([0xEA, 0x07, 7, 15, 12, 34, 5, 2, 128, 0])
        for length in 0..<10 {
            XCTAssertThrowsError(try CurrentTimeCodec.decode(valid.prefix(length)))
        }
    }

- [ ] **Step 2: Run the focused test and verify RED**

Run:

    swift test --package-path peakdo/apple/WattlineCore --filter CurrentTimeCodecTests

Expected: compilation fails because the public codec API is absent.

- [ ] **Step 3: Implement the exact interfaces**

    public enum CurrentTimeCodec {
        public static func encode(
            _ date: Date,
            calendar: Calendar = defaultCalendar(),
            adjustReason: UInt8
        ) -> Data

        public static func decode(
            _ data: Data,
            calendar: Calendar = defaultCalendar()
        ) throws -> Date
    }

    public protocol DeviceTransport: Sendable {
        func synchronizeDeviceTime() async throws
        func readDeviceTimeIfSupported() async throws -> Date?
    }

Move the handshake encoder into this type without changing its live vector. BLE methods must use SerializedTransactions. The bridge returns nil without issuing a read when 0x2A2B lacks the read property. Demo returns simulated time. Replay consumes explicit deviceTime(Date?) and timeSync steps so wrong order fails.

- [ ] **Step 4: Run focused tests and verify GREEN**

    swift test --package-path peakdo/apple/WattlineCore --filter 'CurrentTimeCodecTests|ReplayTransportTests'

Expected: round-trip, truncation, optional-read, and serialization assertions pass.

- [ ] **Step 5: Run Core and commit**

    swift test --package-path peakdo/apple/WattlineCore
    git add peakdo/apple/WattlineCore
    git commit -m "feat: add manual device clock sync"

### Task 2: Shared device operation broker

**Files:**
- Create: peakdo/apple/WattlineShared/Operations/DeviceOperationBroker.swift
- Modify: peakdo/apple/Wattline/Wattline.xcodeproj/project.pbxproj
- Modify: peakdo/apple/Wattline/Wattline/AppModel.swift
- Test: peakdo/apple/Wattline/WattlineTests/DeviceOperationBrokerTests.swift

**Interfaces:**
- Consumes one attached DeviceSession, DeviceTransport, peripheral UUID, and AppModel generation.
- Produces attach, detach, perform, syncClock, and readClock without constructing a transport.

- [ ] **Step 1: Write ownership and stale-generation tests**

    func testBrokerUsesAttachedSessionAndRejectsStaleGeneration() async throws {
        let replay = ReplayTransport(steps: [.reply(bytes: Data([0x01, 0x81, 0x00]))])
        let session = DeviceSession(transport: replay)
        let broker = DeviceOperationBroker()
        await broker.attach(.init(
            generation: 4,
            peripheralID: UUID(),
            transport: replay,
            session: session
        ))
        _ = try await broker.perform(.setDC(true), generation: 4)
        await assertThrows { try await broker.perform(.setDC(false), generation: 3) }
        XCTAssertEqual(await replay.maximumConcurrentTransactions, 1)
    }

- [ ] **Step 2: Run and verify RED**

    xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WattlineTests/DeviceOperationBrokerTests

Expected: DeviceOperationBroker is undefined.

- [ ] **Step 3: Implement the actor**

    actor DeviceOperationBroker {
        struct Context: Sendable {
            let generation: UInt
            let peripheralID: UUID
            let transport: any DeviceTransport
            let session: DeviceSession
        }

        enum BrokerError: Error, Equatable {
            case unavailable
            case superseded
        }

        private var context: Context?

        func attach(_ context: Context) {
            self.context = context
        }

        func detach(generation: UInt) {
            if context?.generation == generation {
                context = nil
            }
        }

        func perform(
            _ command: DeviceCommand,
            generation: UInt
        ) async throws -> CommandOutcome {
            guard let context else { throw BrokerError.unavailable }
            guard context.generation == generation else { throw BrokerError.superseded }
            return try await context.session.perform(command)
        }
    }

AppModel.attach supplies the existing transport/session. Teardown detaches only the matching generation. Add the WattlineShared synchronized source group to the iOS app and iOS unit-test targets; Milestone 4 adds the same group to macOS.

- [ ] **Step 4: Run broker and reconnect tests GREEN**

    xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WattlineTests/DeviceOperationBrokerTests -only-testing:WattlineTests/AppModelReconnectTests

- [ ] **Step 5: Commit**

    git add peakdo/apple/WattlineShared peakdo/apple/Wattline/Wattline.xcodeproj/project.pbxproj peakdo/apple/Wattline/Wattline/AppModel.swift peakdo/apple/Wattline/WattlineTests
    git commit -m "refactor: centralize device operations"

### Task 3: Settings composition and navigation

**Files:**
- Create: peakdo/apple/WattlineUI/Sources/WattlineUI/SettingsSections.swift
- Create: peakdo/apple/Wattline/Wattline/Settings/SettingsPresentation.swift
- Create: peakdo/apple/Wattline/Wattline/Settings/SettingsView.swift
- Modify: peakdo/apple/Wattline/Wattline/RootView.swift
- Test: peakdo/apple/WattlineUI/Tests/WattlineUITests/SettingsCompositionTests.swift
- Test: peakdo/apple/Wattline/WattlineTests/SettingsPresentationTests.swift

**Interfaces:**
- Consumes DeviceIdentitySnapshot, DeviceCapabilities, DeviceState, connection state, and Demo state.
- Produces SettingsComposition, SettingsIdentityPresentation, and a real Settings tab. Removes Timers.

- [ ] **Step 1: Write non-vacuous composition tests**

    func testUnsupportedSettingsControlsAreAbsent() {
        let value = SettingsComposition(
            capabilities: DeviceCapabilities(features: []),
            isApplicationMode: true
        )
        XCTAssertFalse(value.rows.contains(.dcPort))
        XCTAssertFalse(value.rows.contains(.bypass))
        XCTAssertFalse(value.rows.contains(.shutdown))
        XCTAssertTrue(value.rows.contains(.restart))
    }

    func testShutdownBitAddsOnlyShutdown() {
        let value = SettingsComposition(
            capabilities: DeviceCapabilities(features: [.shutdown]),
            isApplicationMode: true
        )
        XCTAssertTrue(value.rows.contains(.shutdown))
        XCTAssertFalse(value.rows.contains(.dcPort))
    }

- [ ] **Step 2: Run and verify RED**

    swift test --package-path peakdo/apple/WattlineUI --filter SettingsCompositionTests

Expected: SettingsComposition is undefined.

- [ ] **Step 3: Implement composition and navigation**

    public enum SettingsRow: Equatable, Sendable {
        case deviceInfo
        case clock
        case dcPort
        case bypass
        case restart
        case shutdown
    }

    public struct SettingsComposition: Equatable, Sendable {
        public let rows: [SettingsRow]

        public init(
            capabilities: DeviceCapabilities,
            isApplicationMode: Bool
        )
    }

ConnectedShellView must contain Home, Shortcuts, and Settings only. Settings renders cached identity while disconnected; capability rows come solely from SettingsComposition.

- [ ] **Step 4: Run tests and generic iOS build GREEN**

    swift test --package-path peakdo/apple/WattlineUI --filter SettingsCompositionTests
    xcodebuild build -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO

- [ ] **Step 5: Commit**

    git add peakdo/apple/WattlineUI peakdo/apple/Wattline/Wattline/RootView.swift peakdo/apple/Wattline/Wattline/Settings peakdo/apple/Wattline/WattlineTests
    git commit -m "feat: add capability-gated settings"

### Task 4: Clock, DC, and bypass Settings behavior

**Files:**
- Modify: peakdo/apple/Wattline/Wattline/AppModel.swift
- Modify: peakdo/apple/WattlineShared/Operations/DeviceOperationBroker.swift
- Modify: peakdo/apple/Wattline/Wattline/Settings/SettingsView.swift
- Test: peakdo/apple/Wattline/WattlineTests/SettingsOperationTests.swift

**Interfaces:**
- Produces syncClock, refreshClockDrift, setBypass, deviceClockDrift, lastClockSync, and pending state derived from DeviceSession.

- [ ] **Step 1: Write clock fallback and telemetry-truth tests**

    func testManualSyncShowsUnavailableDriftWhenReadUnsupported() async {
        let model = makeModelWithUnsupportedClockRead()
        await model.syncClock()
        XCTAssertNotNil(model.lastClockSync)
        XCTAssertNil(model.deviceClockDrift)
        XCTAssertEqual(model.clockStatusText, "Drift unavailable")
    }

    func testSettingsBypassDoesNotOptimisticallyChangeTelemetry() async {
        let model = makeConnectedModel(
            reply: Data([0x14, 0x81, 0xFD])
        )
        model.setBypass(true)
        await waitForPendingBypass(model)
        XCTAssertFalse(model.state.dc?.bypassOn == true)
    }

- [ ] **Step 2: Run and verify RED**

    xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WattlineTests/SettingsOperationTests

- [ ] **Step 3: Implement through the broker**

    func syncClock() async {
        do {
            try await operationBroker.syncClock(generation: transportGeneration)
            lastClockSync = persistence.currentDate
            await refreshClockDrift()
        } catch {
            showToast(String(describing: error))
        }
    }

    func setBypass(_ enabled: Bool) {
        performBrokerMutation(.setBypass(enabled))
    }

Do not assign DC or bypass telemetry in these methods. Compute drift only after successful standard read.

- [ ] **Step 4: Run Settings and §5.7 regression tests GREEN**

    swift test --package-path peakdo/apple/WattlineCore --filter QuirkRegressionTests
    xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WattlineTests/SettingsOperationTests

- [ ] **Step 5: Commit**

    git add peakdo/apple/Wattline/Wattline peakdo/apple/Wattline/WattlineTests
    git commit -m "feat: wire settings controls"

### Task 5: Restart, shutdown, and Demo lifecycle

**Files:**
- Modify: peakdo/apple/Wattline/Wattline/AppModel.swift
- Modify: peakdo/apple/Wattline/Wattline/Settings/SettingsView.swift
- Modify: peakdo/apple/WattlineCore/Sources/WattlineCore/Transport/DemoTransport.swift
- Test: peakdo/apple/Wattline/WattlineTests/SettingsLifecycleTests.swift
- Test: peakdo/apple/Wattline/WattlineUITests/WattlineSettingsUITests.swift

**Interfaces:**
- Produces MaintenanceState, restartDevice, retryRestart, shutdownDevice, and 30-second generation-scoped restart recovery.

- [ ] **Step 1: Write lifecycle tests**

    func testRestartRetriesSamePeripheralWithoutScanning() async {
        let model = makeRestartModel(reconnectAt: .seconds(15))
        await model.restartDevice()
        XCTAssertEqual(model.maintenanceState, .restarting)
        await advance(.seconds(15))
        XCTAssertEqual(model.route, .connected)
        XCTAssertEqual(model.scanStartsForTesting, 0)
    }

    func testShutdownDisarmsReconnectAndReturnsToScan() async {
        let model = makeShutdownModel()
        await model.shutdownDevice()
        XCTAssertEqual(model.route, .scan)
        XCTAssertEqual(model.reconnectAttemptsForTesting, 0)
    }

- [ ] **Step 2: Run and verify RED**

    xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WattlineTests/SettingsLifecycleTests

- [ ] **Step 3: Implement exact states and flows**

    enum MaintenanceState: Equatable {
        case idle
        case restarting
        case restartFailed(String)
        case shuttingDown
    }

    func restartDevice() async
    func retryRestart() async
    func shutdownDevice() async

Restart retries only the same peripheral until 30 seconds and then exposes Retry. Shutdown clears selection only after expected-disconnect success and returns to scan without arming reconnect. Demo emits deterministic disconnect/reconnect or shutdown-to-scan events.

- [ ] **Step 4: Run unit and UI tests GREEN**

    xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WattlineTests/SettingsLifecycleTests -only-testing:WattlineUITests/WattlineSettingsUITests

- [ ] **Step 5: Commit**

    git add peakdo/apple/WattlineCore peakdo/apple/Wattline
    git commit -m "feat: add restart and shutdown flows"

### Task 6: Milestone 1 verification and handoff

- [ ] Run Core, UI, iOS unit, and iOS UI suites from fresh scratch/DerivedData paths with pipefail.
- [ ] Build the generic iOS Simulator product for arm64 and x86_64.
- [ ] Run diff, scope, forbidden-import, zero-network, and contract/reference unchanged audits.
- [ ] Record exact logs, diff stat, Demo evidence, and remaining hardware/macOS checks.
- [ ] Commit only focused verification corrections, deliver the handoff, and stop for Milestone 2 approval.

---

# Milestone 2 — Shared Snapshot and Low-Battery Policy

### Task 7: Versioned snapshot model and store

**Files:**
- Create: peakdo/apple/WattlineCore/Sources/WattlineCore/Snapshot/SharedDeviceSnapshot.swift
- Create: peakdo/apple/WattlineCore/Sources/WattlineCore/Snapshot/SharedSnapshotStore.swift
- Test: peakdo/apple/WattlineCore/Tests/WattlineCoreTests/SharedSnapshotStoreTests.swift

**Interfaces:**
- Produces SharedDeviceSnapshot, SharedSnapshotEnvelope, SnapshotKeyValueStore, read, write, and clear.

- [ ] Write failing tests for complete round-trip, unknown schema, corrupt bytes, NaN power, and atomic replacement.
- [ ] Run the focused test; expect missing snapshot types.
- [ ] Implement schema version 1 with identity, features, battery/status/runtime, DC/USB power and state, connection, and Date observedAt. Return nil for corrupt or unknown data.

    public struct SharedDeviceSnapshot: Codable, Equatable, Sendable {
        public let peripheralID: UUID
        public let featuresRawValue: UInt32
        public let battery: SharedBatterySnapshot?
        public let dc: SharedPortSnapshot?
        public let typeC: SharedPortSnapshot?
        public let connection: SharedConnectionState
        public let observedAt: Date
    }

    public actor SharedSnapshotStore {
        public func read() -> SharedDeviceSnapshot?
        public func write(_ snapshot: SharedDeviceSnapshot) throws
        public func clear()
    }
- [ ] Re-run focused and all Core tests GREEN; prove no unavailable field becomes numeric zero.
- [ ] Commit with message feat: add shared device snapshots.

### Task 8: Material-change, staleness, and reload policies

**Files:**
- Create: peakdo/apple/WattlineCore/Sources/WattlineCore/Snapshot/SnapshotPolicies.swift
- Test: peakdo/apple/WattlineCore/Tests/WattlineCoreTests/SnapshotPolicyTests.swift

**Interfaces:**
- Produces SnapshotFanOutDecision, SnapshotMaterialChangePolicy.evaluate, and SharedDeviceSnapshot.age.

- [ ] Write a failing table test covering one-percent battery change, status/connection/port flips, material power change, noise, immediate status reload, and 15-minute steady reload.
- [ ] Run focused tests; expect missing policy.
- [ ] Implement independent persist, updateActivity, and reloadWidgets decisions with injected Date values.

    public struct SnapshotFanOutDecision: Equatable, Sendable {
        public let persist: Bool
        public let updateActivity: Bool
        public let reloadWidgets: Bool
    }

    public enum SnapshotMaterialChangePolicy {
        public static func evaluate(
            previous: SharedDeviceSnapshot?,
            next: SharedDeviceSnapshot,
            lastWidgetReloadAt: Date?,
            now: Date
        ) -> SnapshotFanOutDecision
    }
- [ ] Re-run focused tests and prove no BLE monotonic timestamp participates.
- [ ] Run Core and commit feat: add snapshot fan-out policy.

### Task 9: Low-battery state machine

**Files:**
- Create: peakdo/apple/WattlineCore/Sources/WattlineCore/SystemSurfaces/LowBatteryPolicy.swift
- Test: peakdo/apple/WattlineCore/Tests/WattlineCoreTests/LowBatteryPolicyTests.swift

**Interfaces:**
- Produces LowBatteryPolicy, LowBatteryState, and evaluate(level:status:enabled:hasBattery:).

- [ ] Write sequence tests for 21→20 alert, repeated 19/18 silence, charging/idle silence, preference/capability gates, 23% re-arm, and a later 20% alert.
- [ ] Run focused tests; expect missing policy.
- [ ] Implement downward crossing with default threshold 20 and hysteresis 3.

    public struct LowBatteryPolicy: Equatable, Sendable {
        public init(threshold: Int = 20, hysteresis: Int = 3)
        public mutating func evaluate(
            level: Int,
            status: PowerFlow,
            enabled: Bool,
            hasBattery: Bool
        ) -> LowBatteryEvent?
    }
- [ ] Mutate the comparison to prove the test goes RED, restore it, then run all Core tests GREEN.
- [ ] Commit feat: add low battery policy.

### Task 10: iOS snapshot coordinator and app group

**Files:**
- Create: peakdo/apple/WattlineShared/Snapshots/SnapshotCoordinator.swift
- Modify: peakdo/apple/Wattline/Wattline/AppModel.swift
- Modify: peakdo/apple/Wattline/Wattline/Wattline.entitlements
- Test: peakdo/apple/Wattline/WattlineTests/SnapshotCoordinatorTests.swift

**Interfaces:**
- Consumes accepted DeviceState, identity, capabilities, wall clock, and generation.
- Produces app-group writes and SnapshotFanOutEvent; imports neither WidgetKit nor ActivityKit.

- [ ] Write failing tests proving pending mutations do not alter snapshots, confirmed telemetry does, status flip fans out immediately, and stale generations are ignored.
- [ ] Run focused app tests; expect missing coordinator.
- [ ] Implement a MainActor coordinator injected with SharedSnapshotStore and clock. Call it only from accepted session state.

    @MainActor
    final class SnapshotCoordinator {
        func receive(
            state: DeviceState,
            identity: DeviceIdentitySnapshot?,
            capabilities: DeviceCapabilities,
            generation: UInt
        ) async -> SnapshotFanOutEvent?
    }
- [ ] Add group.com.keithah.wattline entitlement and assert the plist value in a test.
- [ ] Run app/Core suites and commit feat: persist app group snapshots.

### Task 11: Notification authorization and DC-off action

**Files:**
- Create: peakdo/apple/Wattline/Wattline/Notifications/LowBatteryNotificationCoordinator.swift
- Modify: peakdo/apple/Wattline/Wattline/WattlineApp.swift
- Modify: peakdo/apple/Wattline/Wattline/AppPersistence.swift
- Modify: peakdo/apple/Wattline/Wattline/Settings/SettingsView.swift
- Test: peakdo/apple/Wattline/WattlineTests/LowBatteryNotificationTests.swift

**Interfaces:**
- Produces lowBatteryEnabled, lowBatteryThreshold, NotificationCenterAdapter, category WATTLINE_LOW_BATTERY, and action WATTLINE_TURN_OFF_DC.

- [ ] Write failing tests proving no permission request at launch, one request when enabled, action absence without DC control, and action success only after dcEnabled(false) telemetry.
- [ ] Run focused app tests; expect missing coordinator and preferences.
- [ ] Implement an injected UserNotifications adapter; production wraps UNUserNotificationCenter and tests use a recorder.

    protocol NotificationCenterAdapter: Sendable {
        func requestAuthorization() async throws -> Bool
        func registerLowBatteryCategory(includeDCAction: Bool) async
        func postLowBattery(level: Int, threshold: Int) async throws
    }

    @MainActor
    final class LowBatteryNotificationCoordinator {
        func setEnabled(_ enabled: Bool) async
        func receive(_ snapshot: SharedDeviceSnapshot) async
        func handleAction(identifier: String) async -> NotificationActionResult
    }
- [ ] Route the action through DeviceOperationBroker with a 10-second timeout and no write-ack success.
- [ ] Run app/UI tests and commit feat: add low battery notifications.

### Task 12: Milestone 2 verification and handoff

- [ ] Run fresh Core, UI, and iOS suites plus generic iOS build.
- [ ] Audit app-group entitlement, notification category/action, no networking, no forbidden Core imports, and no timer artifacts.
- [ ] Exercise Demo threshold crossing and action flow where simulator notification authorization permits.
- [ ] Deliver diff/logs and identify real background wake plus hardware confirmation as external.
- [ ] Stop for Milestone 3 approval.

---

# Milestone 3 — iOS Live Activities and Widgets

### Task 13: Pure Live Activity lifecycle

**Files:**
- Create: peakdo/apple/WattlineCore/Sources/WattlineCore/SystemSurfaces/LiveActivityPolicy.swift
- Test: peakdo/apple/WattlineCore/Tests/WattlineCoreTests/LiveActivityPolicyTests.swift

**Interfaces:**
- Produces LiveActivityPreferences, LiveActivityLifecycleState, LiveActivityCommand, and evaluate.

- [ ] Write failing tables for charging/discharging preference gates, material update, 4:59 and 5:00 idle, 14:59 and 15:00 disconnect, and near-eight-hour renewal.
- [ ] Run focused test; expect missing policy.
- [ ] Implement none, start, update, end, and renew decisions using injected wall-clock dates.

    public enum LiveActivityCommand: Equatable, Sendable {
        case none
        case start(SharedDeviceSnapshot)
        case update(SharedDeviceSnapshot)
        case end
        case renew(SharedDeviceSnapshot)
    }

    public struct LiveActivityPolicy: Sendable {
        public mutating func evaluate(
            snapshot: SharedDeviceSnapshot,
            now: Date,
            preferences: LiveActivityPreferences
        ) -> LiveActivityCommand
    }
- [ ] Run focused and all Core tests GREEN.
- [ ] Commit feat: add live activity lifecycle policy.

### Task 14: Widget and Activity target configuration

**Files:**
- Modify: peakdo/apple/Wattline/Wattline.xcodeproj/project.pbxproj
- Modify: peakdo/apple/Wattline/Wattline/Info.plist
- Create: peakdo/apple/WattlineWidgets/WattlineWidgets.entitlements
- Create: peakdo/apple/WattlineWidgets/Info.plist
- Create: peakdo/apple/WattlineWidgets/WattlineWidgetsBundle.swift
- Test: peakdo/apple/Wattline/WattlineTests/Phase2ProjectConfigurationTests.swift

**Interfaces:**
- Produces a multi-platform WattlineWidgets target, app group, and NSSupportsLiveActivities.

- [ ] Write failing project/plist tests for target product type, bundle ID, deployment floors, app group, and Live Activity key.
- [ ] Run the test; expect missing target/config assertions fail.
- [ ] Add the extension, WattlineCore/WattlineUI products, iOS-conditional Activity code, and iOS embedding.

    PRODUCT_BUNDLE_IDENTIFIER[sdk=iphoneos*] = com.keithah.wattline.widgets
    PRODUCT_BUNDLE_IDENTIFIER[sdk=iphonesimulator*] = com.keithah.wattline.widgets
    PRODUCT_BUNDLE_IDENTIFIER[sdk=macosx*] = com.keithah.wattline.mac.widgets
    IPHONEOS_DEPLOYMENT_TARGET = 17.0
    MACOSX_DEPLOYMENT_TARGET = 14.0
    CODE_SIGN_ENTITLEMENTS = WattlineWidgets/WattlineWidgets.entitlements

The iOS app Info.plist must contain NSSupportsLiveActivities as Boolean true.
- [ ] Build WattlineWidgets for generic iOS Simulator and generic macOS.
- [ ] Commit build: add Wattline widget extension.

### Task 15: ActivityKit adapter and views

**Files:**
- Create: peakdo/apple/Wattline/Wattline/Activities/LiveActivityCoordinator.swift
- Create: peakdo/apple/WattlineWidgets/WattlineActivityAttributes.swift
- Create: peakdo/apple/WattlineWidgets/WattlineLiveActivity.swift
- Modify: peakdo/apple/Wattline/Wattline.xcodeproj/project.pbxproj
- Modify: peakdo/apple/WattlineShared/Snapshots/SnapshotCoordinator.swift
- Test: peakdo/apple/Wattline/WattlineTests/LiveActivityCoordinatorTests.swift

**Interfaces:**
- Produces LiveActivityAdapter and translates pure commands into ActivityKit request, update, and end.

- [ ] Write fake-adapter tests for start, semantic update, disconnected timestamp, idle/disconnect end, authorization denial, and adapter error isolation.
- [ ] Run focused app tests; expect missing coordinator.
- [ ] Implement ActivityKit only in the production adapter. Content state carries level, status, runtime, aggregate output, observedAt, and connection.

    protocol LiveActivityAdapter: Sendable {
        func request(state: WattlineActivityAttributes.ContentState) async throws
        func update(state: WattlineActivityAttributes.ContentState) async throws
        func end() async
    }

Give WattlineActivityAttributes.swift explicit target membership in both the iOS app and WattlineWidgets extension. Give WattlineLiveActivity.swift membership only in the extension.

    struct WattlineActivityAttributes: ActivityAttributes {
        struct ContentState: Codable, Hashable {
            let level: Int
            let status: Int8
            let runtimeSeconds: Int?
            let aggregateOutputWatts: Double
            let observedAt: Date
            let isConnected: Bool
        }
    }
- [ ] Implement Lock Screen, compact, and minimal Dynamic Island views with semantic color and monospaced digits.
- [ ] Run app tests and extension build; commit feat: add Wattline live activities.

### Task 16: Small and medium widgets

**Files:**
- Create: peakdo/apple/WattlineWidgets/WattlineWidgetProvider.swift
- Create: peakdo/apple/WattlineWidgets/WattlineWidgets.swift
- Create: peakdo/apple/WattlineWidgetsTests/WattlineWidgetProviderTests.swift
- Modify: peakdo/apple/WattlineShared/Snapshots/SnapshotCoordinator.swift

**Interfaces:**
- Produces snapshot-only timeline provider, small/medium families, dashboard deep link, and WidgetReloadAdapter.

- [ ] Write failing provider tests for fresh, stale as-of, unavailable, charging, discharging, and an initializer with no transport dependency.
- [ ] Run extension tests; expect missing provider.
- [ ] Implement entries from SharedSnapshotStore.read only. Do not import CoreBluetooth or construct DeviceTransport.

    struct WattlineWidgetProvider: TimelineProvider {
        let snapshots: SharedSnapshotStore
        func placeholder(in context: Context) -> WattlineWidgetEntry
        func getSnapshot(in context: Context, completion: @escaping (WattlineWidgetEntry) -> Void)
        func getTimeline(in context: Context, completion: @escaping (Timeline<WattlineWidgetEntry>) -> Void)
    }
- [ ] Add app-side WidgetCenter adapter driven by Task 8 decisions.
- [ ] Run extension/app tests and commit feat: add Wattline widgets.

### Task 17: Preferences and iOS acceptance

**Files:**
- Create: peakdo/apple/WattlineUI/Sources/WattlineUI/SystemSurfacePresentation.swift
- Modify: peakdo/apple/Wattline/Wattline/Settings/SettingsView.swift
- Modify: peakdo/apple/Wattline/Wattline/AppPersistence.swift
- Create: peakdo/apple/Wattline/WattlineUITests/WattlineSystemSurfaceUITests.swift

- [ ] Write failing tests for both Live Activity defaults on, independent toggles, low-battery default off/20%, capability-absent sections, and semantic presentation.
- [ ] Run UI/app tests; expect missing preference behavior.
- [ ] Implement persistence and structurally compose battery-only sections.

    struct SystemSurfacePreferences: Codable, Equatable {
        var liveActivityCharging = true
        var liveActivityDischarging = true
        var lowBatteryEnabled = false
        var lowBatteryThreshold = 20
    }
- [ ] Drive Settings and Demo states in UI tests; assert DEMO and no Timers tab.
- [ ] Run all suites and commit feat: add system surface preferences.

### Task 18: Milestone 3 verification and handoff

- [ ] Run fresh Core, UI, iOS unit/UI, and widget extension suites.
- [ ] Build generic iOS app and extension; verify entitlements and Info.plist.
- [ ] Audit widget source for transport use and all sources for networking.
- [ ] Capture simulator surfaces where supported; leave full-cycle locked/background longevity external.
- [ ] Stop for Milestone 4 approval.

---

# Milestone 4 — macOS Menu Bar and Notification Center Widget

### Task 19: Compact cross-platform UI

**Files:**
- Create: peakdo/apple/WattlineUI/Sources/WattlineUI/CompactDeviceViews.swift
- Modify: peakdo/apple/WattlineUI/Sources/WattlineUI/BatteryHero.swift
- Modify: peakdo/apple/WattlineUI/Sources/WattlineUI/PortCard.swift
- Test: peakdo/apple/WattlineUI/Tests/WattlineUITests/CompactDeviceViewTests.swift

- [ ] Write failing API/composition tests for compact stale, pending, capability-absent, and callback behavior.
- [ ] Run focused UI tests; expect missing compact API.
- [ ] Implement compact variants without forking telemetry or semantic-color rules.

    public struct CompactBatteryHero: View {
        public init(snapshot: SharedDeviceSnapshot, freshness: TelemetryFreshness)
    }

    public struct CompactPortCard: View {
        public init(
            presentation: PortCardPresentation,
            isPending: Bool,
            onToggle: (() -> Void)?
        )
    }
- [ ] Run all UI tests and generic iOS build.
- [ ] Commit feat: add compact device views.

### Task 20: macOS target and single-owner shell

**Files:**
- Modify: peakdo/apple/Wattline/Wattline.xcodeproj/project.pbxproj
- Create: peakdo/apple/WattlineMac/Info.plist
- Create: peakdo/apple/WattlineMac/WattlineMac.entitlements
- Create: peakdo/apple/WattlineMac/WattlineMacApp.swift
- Create: peakdo/apple/WattlineMac/MacAppModel.swift
- Create: peakdo/apple/WattlineMac/MainWindowView.swift
- Create: peakdo/apple/WattlineMacTests/MacAppModelTests.swift

- [ ] Extend configuration tests for macOS 14, bundle ID, app group, LSUIElement, packages, tests, and widget embedding.
- [ ] Run tests; expect missing target failures.
- [ ] Add macOS app/test targets, add the WattlineShared synchronized source group to both, and create one MacAppModel owning one BLE transport/session and snapshot coordinator.

    @MainActor
    @Observable
    final class MacAppModel {
        let operationBroker: DeviceOperationBroker
        private(set) var state = DeviceState()
        private(set) var capabilities = DeviceCapabilities(features: [])
        func start()
        func setDC(_ enabled: Bool)
        func setTypeCOutput(_ enabled: Bool)
    }
- [ ] Implement menu-bar-only launch and Home/Shortcuts/Settings NavigationSplitView with no Timers.
- [ ] Build/test macOS and commit build: add Wattline macOS app.

### Task 21: Menu bar, popover, Dock, and launch at login

**Files:**
- Create: peakdo/apple/WattlineMac/MenuBarContent.swift
- Create: peakdo/apple/WattlineMac/PopoverView.swift
- Create: peakdo/apple/WattlineMac/MacSystemAdapters.swift
- Modify: peakdo/apple/WattlineMac/WattlineMacApp.swift
- Test: peakdo/apple/WattlineMacTests/MacSystemSurfaceTests.swift

**Interfaces:**
- Produces pure menu-title presentation, ActivationPolicyAdapter, LaunchAtLoginAdapter, and popover actions through the macOS session.

- [ ] Write failing tests for charging title ⚡︎ 84%, noncharging 84%, unknown glyph, menu-only default, persisted Dock opt-in, login errors, and confirmed toggles.
- [ ] Run macOS tests; expect missing surfaces.
- [ ] Implement MenuBarExtra, compact popover, injected NSApplication activation adapter, and injected SMAppService adapter.

    protocol ActivationPolicyAdapter {
        func setShowsDock(_ showsDock: Bool) -> Bool
    }

    protocol LaunchAtLoginAdapter {
        var isEnabled: Bool { get }
        func setEnabled(_ enabled: Bool) throws
    }

    enum MenuBarTitle {
        static func text(level: Int?, status: PowerFlow) -> String
    }
- [ ] Add an os_signpost interval from user toggle to telemetry confirmation; keep popover open and responsive while pending.
- [ ] Run macOS/Core quirk tests and commit feat: add Wattline menu bar controls.

### Task 22: macOS widget integration

**Files:**
- Modify: peakdo/apple/WattlineWidgets/WattlineWidgets.swift
- Modify: peakdo/apple/Wattline/Wattline.xcodeproj/project.pbxproj
- Test: peakdo/apple/WattlineWidgetsTests/WattlineWidgetProviderTests.swift

- [ ] Add a failing test that macOS entries match iOS snapshot semantics and deep-link to the macOS window.
- [ ] Run extension tests; expect missing macOS configuration.
- [ ] Add conditional deep links and embed the same extension without BLE construction.

    enum WattlineDeepLink {
        static func dashboard(platform: WidgetPlatform) -> URL
    }
- [ ] Build the extension and macOS app for generic macOS.
- [ ] Commit feat: add macOS Wattline widgets.

### Task 23: Milestone 4 verification and handoff

- [ ] Run fresh Core/UI/iOS/macOS/widget tests and generic builds.
- [ ] Launch macOS, verify accessory default, Dock toggle, popover persistence, and login error UI.
- [ ] Audit one BLE owner, app-group consistency, zero networking, and no Timers.
- [ ] Provide signpost measurement instructions; leave real-hardware <1.5-second evidence external when unavailable.
- [ ] Stop for Milestone 5 approval.

---

# Milestone 5 — App Intents and Gallery

### Task 24: Generation-tokened 10-second broker connection

**Files:**
- Modify: peakdo/apple/WattlineShared/Operations/DeviceOperationBroker.swift
- Modify: peakdo/apple/Wattline/Wattline/AppModel.swift
- Test: peakdo/apple/Wattline/WattlineTests/DeviceOperationBrokerTests.swift

**Interfaces:**
- Produces withConnection(to:timeout:operation:), stale-snapshot access, and DeviceOperationResult.

- [ ] Write failing tests for connected reuse, reconnect at 9.9 seconds, timeout at 10 seconds, cancellation, stale callback quarantine, and no second transport construction.
- [ ] Run broker tests; expect missing reconnect API.
- [ ] Implement reconnect through AppModel lifecycle callbacks and a continuation registry keyed by generation; resume exactly once on every terminal path.

    func withConnection<T: Sendable>(
        to peripheralID: UUID,
        timeout: Duration = .seconds(10),
        operation: @Sendable (Context) async throws -> T
    ) async throws -> T
- [ ] Run broker, reconnect, serialization, and expected-disconnect suites GREEN.
- [ ] Commit feat: add bounded intent connections.

### Task 25: Three App Intents

**Files:**
- Create: peakdo/apple/Wattline/Wattline/Intents/WattlineIntents.swift
- Create: peakdo/apple/Wattline/Wattline/Intents/WattlineIntentEntities.swift
- Test: peakdo/apple/Wattline/WattlineTests/WattlineIntentTests.swift

**Interfaces:**
- Produces ToggleDCPortIntent, GetBatteryLevelIntent, SetUSBCPowerLimitIntent, parameter entities, and IntentOperationAdapter.

- [ ] Write failing adapter tests for toggle truth, DC confirmation, unsupported capability, live battery, stale snapshot plus age after timeout, no-snapshot failure, and SET-then-GET limit.
- [ ] Run app tests; expect missing intent types.
- [ ] Implement AppIntent declarations and use ForegroundContinuableIntent only when app resume is required. Test the injected adapter without requiring Shortcuts runtime.

    protocol IntentOperationAdapter: Sendable {
        func toggleDC(deviceID: UUID, mode: DCToggleMode) async throws -> ConfirmedDCResult
        func battery(deviceID: UUID) async throws -> BatteryIntentResult
        func setLimit(
            deviceID: UUID,
            type: PowerLimitType,
            level: PowerLimitLevel
        ) async throws -> ConfirmedLimitResult
    }

    struct ToggleDCPortIntent: AppIntent
    struct GetBatteryLevelIntent: AppIntent
    struct SetUSBCPowerLimitIntent: AppIntent
- [ ] Restrict entity queries to eligible saved devices and repeat capability checks on direct invocation.
- [ ] Run app/Core suites and commit feat: add Wattline app intents.

### Task 26: Shortcuts gallery

**Files:**
- Create: peakdo/apple/WattlineUI/Sources/WattlineUI/ShortcutsGallery.swift
- Create: peakdo/apple/Wattline/Wattline/Intents/ShortcutsView.swift
- Modify: peakdo/apple/Wattline/Wattline/RootView.swift
- Modify: peakdo/apple/WattlineMac/MainWindowView.swift
- Test: peakdo/apple/WattlineUI/Tests/WattlineUITests/ShortcutsCompositionTests.swift
- Test: peakdo/apple/Wattline/WattlineUITests/WattlineShortcutsUITests.swift

- [ ] Write failing composition tests proving each card is absent without its bit and low-battery copy does not claim event triggers.
- [ ] Run UI/app tests; expect missing gallery.
- [ ] Implement Toggle DC, Get Battery, Set USB-C Limit, and honest low-battery recipe cards. Demo results must say simulated.

    public enum ShortcutCard: Equatable, Sendable {
        case toggleDC
        case getBattery
        case setUSBLimit
        case lowBatteryRecipe
    }

    public struct ShortcutsComposition: Equatable, Sendable {
        public init(capabilities: DeviceCapabilities?, hasKnownDevice: Bool)
        public let cards: [ShortcutCard]
        public let showsNoDeviceExplanation: Bool
    }

When no device has connected, show the three device cards disabled with the Screen 8 explanation. When a known device has authoritative capabilities, structurally omit unsupported cards.
- [ ] Drive every card in Demo UI tests and assert no Timers destination.
- [ ] Run all suites and commit feat: add Shortcuts gallery.

### Task 27: Phase 2 final verification

- [ ] Run Core/UI from empty scratch paths with pipefail.
- [ ] Run clean iOS, macOS, widget, UI, and intent-adapter tests from fresh DerivedData.
- [ ] Build every target for generic iOS Simulator and generic macOS.
- [ ] Audit deployment floors, IDs, app group, background BLE, Activity/Widget keys, forbidden Core imports, widget BLE use, zero networking, no OTA install, no timer work, and unchanged contract/OEM files.
- [ ] Run signed Shortcuts integration if credentials/device exist; otherwise classify it as external evidence.
- [ ] Deliver complete diff, full logs, Demo/system-surface evidence, and an exit matrix separating deterministic passes from macOS/hardware checks.
- [ ] Stop for Phase 2 acceptance; do not begin Phase 3.

## Spec Coverage Index

| Requirement | Tasks |
|---|---|
| F9 identity, clock, DC, bypass, restart, shutdown, Demo | 1–6 |
| F10 and Timers removal | 3, 5, 12, 17, 20, 23, 26, 27 |
| Shared app-group snapshot and honest staleness | 7, 8, 10 |
| F16 low-battery threshold, permission, DC action | 9, 11–12 |
| F11 lifecycle, direction/runtime/output, ActivityKit | 13–15, 17–18 |
| F12 iOS small/medium widgets and throttling | 8, 14, 16–18 |
| F13 macOS menu bar, popover, window, Dock/login | 19–21, 23 |
| F14 macOS Notification Center widgets | 14, 16, 22–23 |
| F15 intents, 10-second connection, capability gates, gallery | 24–27 |
| FEATURES → CID → model and structural absence | 3, 11, 17, 21, 25–27 |
| Telemetry truth and §5.7 quirks | 2, 4–5, 10–11, 21, 24–27 |
| Swift 6 ownership, generation quarantine, one continuation resume | 2, 5, 10, 21, 24–25 |
| No networking and Data Not Collected audit | 6, 12, 18, 23, 27 |
| Phase 2 external exit checks | 18, 23, 27 |
