# Wattline Baseline Health Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every existing Wattline package, app-unit, UI, and widget test deterministic, non-vacuous, and green before feature work resumes.

**Architecture:** Repair test resource lookup and asynchronous readiness first, then enforce the production invariant that connected presentation is published only after the app-owned broker is attached and marked connected. Preserve existing transport and reconciliation behavior; do not weaken assertions or increase arbitrary sleeps.

**Tech Stack:** Swift 6, XCTest, CoreBluetooth test transports, Xcode simulator test runner.

## Global Constraints

- Inherit every constraint from `2026-07-17-wattline-completion.md`.
- Existing failures are RED evidence; each repair must make a named failure green without deleting its behavioral assertion.
- Replace fixed sleeps/yield counts with bounded condition waits or injected clocks.
- Tests must resolve repository files from `#filePath`, never the process working directory.
- Do not add any product feature in this milestone.

---

### Task 1: Make app tests independent of working directory and fixed delays

**Files:**
- Create: `peakdo/apple/Wattline/WattlineTests/TestSupport/TestProjectFiles.swift`
- Create: `peakdo/apple/Wattline/WattlineTests/TestSupport/AsyncTestWait.swift`
- Modify: `peakdo/apple/Wattline/WattlineTests/SnapshotCoordinatorTests.swift`
- Modify: `peakdo/apple/Wattline/WattlineTests/Phase2ProjectConfigurationTests.swift`
- Modify: `peakdo/apple/Wattline/WattlineTests/RouterAppWiringTests.swift`

**Interfaces:**
- Produces: `TestProjectFiles.url(_:)` and `waitUntil(timeout:condition:)` for deterministic app-target tests.
- Consumes: no production interface.

- [ ] **Step 1: Preserve and extend the failing tests**

Replace relative file reads and fixed `Task.sleep` assertions with the following test support calls. Keep the existing entitlement, plist, Live Activity request/update, app-group, and no-network assertions intact.

```swift
enum TestProjectFiles {
    static let projectDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // TestSupport
        .deletingLastPathComponent() // WattlineTests
        .deletingLastPathComponent() // Wattline

    static func url(_ relativePath: String) -> URL {
        projectDirectory.appending(path: relativePath)
    }
}

enum AsyncTestWaitError: Error { case timedOut }

func waitUntil(
    timeout: Duration = .seconds(3),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
        guard clock.now < deadline else { throw AsyncTestWaitError.timedOut }
        try await clock.sleep(for: .milliseconds(10))
    }
}

actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
```

Use `String(contentsOf: TestProjectFiles.url("Wattline/Wattline.entitlements"))` and the equivalent Info.plist/project paths. In the Live Activity fan-out test, wait until the recorder contains two events and then assert the exact sequence remains `[.request, .update]`.

- [ ] **Step 2: Run the focused tests and verify current RED**

Run:

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination "platform=iOS Simulator,id=$WATTLINE_SIMULATOR_ID" \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:WattlineTests/SnapshotCoordinatorTests \
  -only-testing:WattlineTests/Phase2ProjectConfigurationTests \
  -only-testing:WattlineTests/RouterAppWiringTests
```

Expected before the edits: the relative entitlement/plist tests fail outside `peakdo/apple/Wattline`, and the fixed-delay Live Activity assertion is timing-sensitive. Expected after only adding the new assertions but before call-site edits: compile failures for missing `TestProjectFiles`/`waitUntil` use.

- [ ] **Step 3: Implement the test infrastructure and qualify production types**

Add the two test-support files. Where `WattlineShared` sources are also test-target members, qualify the implementation under test as `Wattline.SnapshotCoordinator`, `Wattline.WidgetReloadAdapter`, and other duplicated names so tests cannot accidentally exercise a test-module copy.

- [ ] **Step 4: Run focused tests GREEN**

Run the Step 2 command. Expected: all selected tests pass, with the Live Activity test still proving one request followed by one material update.

- [ ] **Step 5: Commit**

```bash
git add peakdo/apple/Wattline/WattlineTests
git commit -m "test: make Wattline app tests deterministic"
```

### Task 2: Publish broker readiness before connected UI state

**Files:**
- Modify: `peakdo/apple/Wattline/Wattline/AppModel.swift`
- Modify: `peakdo/apple/Wattline/WattlineTests/AppModelReconnectTests.swift`
- Modify: `peakdo/apple/Wattline/WattlineTests/SettingsOperationTests.swift`

**Interfaces:**
- Consumes: `DeviceOperationBroker.attach(_:)`, `markConnected(peripheralID:generation:)`, and `DeviceConnectionScope`.
- Produces: the invariant `connectionStatus == .connected` implies the current broker context is attached and marked connected.

- [ ] **Step 1: Write a failing ordering regression test**

Add a controllable publication gate to an `AppModelReconnectTests` direct-connect fixture. Before releasing the gate, assert the model has not exposed connected presentation; after release, assert both presentation and broker state are connected.

```swift
let gate = AsyncGate()
let model = AppModel(
    persistence: persistence,
    transportFactory: { transport },
    brokerPublicationBarrier: { await gate.wait() }
)
model.requestBluetoothAfterPriming()
model.choose(device)
try await waitUntil { await transport.connectCount == 1 }
XCTAssertNotEqual(model.connectionStatus, .connected)
await gate.open()
try await waitUntil { model.connectionStatus == .connected }
XCTAssertTrue(await model.deviceOperationBroker.hasConnectedContext)
```

Keep the existing bypass test proving a nonstandard ACK cannot change telemetry and the DC test proving pending state matches the requested target.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination "platform=iOS Simulator,id=$WATTLINE_SIMULATOR_ID" \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:WattlineTests/AppModelReconnectTests \
  -only-testing:WattlineTests/SettingsOperationTests
```

Expected: the new gate test observes `.connected` before broker publication; the existing bypass/DC tests can time out because they act during the same readiness gap.

- [ ] **Step 3: Reorder direct connection completion**

In `completeConnectionOperation(_:)`, keep the scope guards, but attach and mark the broker before calling `establishConnectedPresentation(scope:)`:

```swift
activeConnectionScope = key.scope
connectionOperationKey = nil
if let session { await session.receive(.connected(key.scope)) }

let context = prepareBrokerContext(
    peripheralID: key.peripheralID,
    generation: key.transportGeneration
)
await publishBrokerContext(context)
guard isCurrent(key) else { return }
await deviceOperationBroker.markConnected(
    peripheralID: key.peripheralID,
    generation: key.transportGeneration
)
guard isCurrent(key) else { return }
establishConnectedPresentation(scope: key.scope)
```

Implement the repeated guards as a private `isCurrent(_ key: ConnectionOperationKey) -> Bool` using the existing generation, operation, selected-peripheral, active-scope, and retired-scope checks. Do not publish optimistic port or battery state.

- [ ] **Step 4: Run focused and broker tests GREEN**

Run the Step 2 command plus:

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination "platform=iOS Simulator,id=$WATTLINE_SIMULATOR_ID" \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:WattlineTests/DeviceOperationBrokerTests
```

Expected: direct connection exposes `.connected` only after broker readiness; bypass remains pending until matching telemetry; DC confirmed telemetry remains unchanged while the requested mutation is pending.

- [ ] **Step 5: Commit**

```bash
git add peakdo/apple/Wattline/Wattline/AppModel.swift \
  peakdo/apple/Wattline/WattlineTests/AppModelReconnectTests.swift \
  peakdo/apple/Wattline/WattlineTests/SettingsOperationTests.swift
git commit -m "fix: publish broker readiness before connected state"
```

### Task 3: Harden restart lifecycle fixtures without weakening semantics

**Files:**
- Modify: `peakdo/apple/Wattline/WattlineTests/SettingsLifecycleTests.swift`
- Modify only if a focused test proves a production defect: `peakdo/apple/Wattline/Wattline/AppModel.swift`

**Interfaces:**
- Consumes: the connected/broker invariant from Task 2 and existing expected-disconnect restart flow.
- Produces: deterministic coverage of disconnect-as-success, write-error-while-disconnecting, 15-second reconnect, 30-second retry, and stale-scope quarantine.

- [ ] **Step 1: Make every restart assertion condition-based**

Have `makeConnectedModel` wait for both connected presentation and broker readiness. Replace helper functions that call `XCTFail` and return with throwing bounded waits so a timed-out readiness condition cannot let the test continue vacuously.

```swift
try await waitUntil {
    model.connectionStatus == .connected
        && (await model.deviceOperationBroker.hasConnectedContext)
}

try await waitUntil { await transport.reconnectIsWaiting }
await clock.advance(by: .seconds(15))
await transport.releaseReconnect()
try await waitUntil {
    model.connectionStatus == .connected && model.maintenanceState == .idle
}
```

For asynchronous disconnect-after-write-error, retain the delayed scoped disconnect and assert `reconnectAttemptsForTesting == 0` before that exact disconnect is emitted. For stale-scope quarantine, assert the old scope differs from the recovered scope before emitting it.

- [ ] **Step 2: Run the complete lifecycle class and verify RED/GREEN transition**

Run:

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination "platform=iOS Simulator,id=$WATTLINE_SIMULATOR_ID" \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:WattlineTests/SettingsLifecycleTests
```

Expected before Tasks 1–2: six named restart tests time out or operate before broker attachment. Expected after the fixture changes: every lifecycle case passes without increasing real-time sleep windows.

- [ ] **Step 3: Apply a production change only for an observed lifecycle failure**

If the focused test still shows a real AppModel race, add a generation-keyed restart-disconnect signal that is resumed only by `.disconnected(scope, ...)` for the active scope. Its timeout uses the injected `DeviceClock`, removes the registry entry exactly once, and cannot be resumed by an old scope. Do not treat a write ACK as restart success.

```swift
private struct RestartDisconnectKey: Equatable {
    let generation: UInt
    let scope: DeviceConnectionScope
}
```

The regression test must fail when the scope comparison or generation comparison is removed. If the focused suite is green after Tasks 1–2, leave production restart code unchanged and commit only the non-vacuous fixture changes.

- [ ] **Step 4: Run lifecycle, reconnect, and quirk suites GREEN**

Run the Step 2 command, then:

```bash
swift test --package-path peakdo/apple/WattlineCore --filter QuirkRegressionTests
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination "platform=iOS Simulator,id=$WATTLINE_SIMULATOR_ID" \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:WattlineTests/AppModelReconnectTests
```

- [ ] **Step 5: Commit**

```bash
git add peakdo/apple/Wattline/WattlineTests/SettingsLifecycleTests.swift peakdo/apple/Wattline/Wattline/AppModel.swift
git commit -m "test: harden restart lifecycle coverage"
```

### Task 4: Baseline verification and handoff

**Files:**
- Modify: `peakdo/apple/docs/superpowers/plans/2026-07-17-wattline-baseline-health.md` only to check completed boxes and record actual counts.

**Interfaces:**
- Produces: a green baseline required by every later plan.

- [x] **Step 1: Run all package suites**

```bash
swift test --package-path peakdo/apple/WattlineCore
swift test --package-path peakdo/apple/WattlineUI
swift test --package-path peakdo/apple/WattlineNetwork
```

Expected: zero failures; record exact executed counts.

- [x] **Step 2: Run app, widget, and UI suites for real**

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination "platform=iOS Simulator,id=$WATTLINE_SIMULATOR_ID" \
  CODE_SIGNING_ALLOWED=NO
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineWidgets \
  -destination "platform=iOS Simulator,id=$WATTLINE_SIMULATOR_ID" \
  CODE_SIGNING_ALLOWED=NO
```

Expected: real XCTest execution with zero failures, not build-for-testing output.

- [x] **Step 3: Run baseline audits**

```bash
rg -n 'URLSession|NWBrowser|NWConnection|import Network|import Security' \
  peakdo/apple/WattlineCore/Sources peakdo/apple/WattlineUI/Sources
rg -n 'api\.peakdo\.ca|scheduledOnOff|TimerRow|Timers' \
  peakdo/apple/Wattline peakdo/apple/WattlineShared peakdo/apple/WattlineUI/Sources
git diff --check
```

Expected: no Core/UI networking hits, no new OTA/Timer surface, and no whitespace errors.

- [x] **Step 4: Commit verification evidence and stop**

```bash
git add peakdo/apple/docs/superpowers/plans/2026-07-17-wattline-baseline-health.md
git commit -m "test: verify Wattline completion baseline"
```

Report the unique pre-fix failures, exact post-fix counts, simulator UUID/runtime, environment launch errors encountered, and any external-only checks. Stop for Milestone 2 approval.

**Verification evidence (2026-07-18):** package suites: WattlineCore 156/156, WattlineUI 26/26, and WattlineNetwork 97/97. Full real `Wattline` XCTest (result bundle `/tmp/wattline-task4-full-portable.xcresult`) passed 148/148 with 0 failed/skipped; the real `WattlineWidgets` XCTest rerun passed 148/148 with 0 failed/skipped (`/tmp/wattline-task4-widgets.xcresult`). Destination: `Wattline-Tests` iPhone 17e, UUID `81744CE3-2DBE-4986-9B27-D61D1E10A63D`, iOS 26.5 / build 23F77. Core/UI networking audit had no matches. OTA/Timer audit had only six existing UI-test negative assertions/test names containing `Timers`; it had no `api.peakdo.ca`, `scheduledOnOff`, or `TimerRow` matches. `git diff --check` passed. The original timeout/UI blockers were fixed and reviewed in approved range `4021b5fb..2f720163` (including `925790f1` and `2f720163`); unused-clone/debugger-version diagnostics remain non-fatal simulator environment noise.
