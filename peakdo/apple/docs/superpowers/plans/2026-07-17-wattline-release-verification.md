# Wattline Non-OTA Release Verification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the completed non-OTA Wattline roadmap builds, executes, respects package/ownership/privacy boundaries, and clearly separates deterministic passes from signed OS/hardware evidence.

**Architecture:** Verify from fresh package build directories and fresh Xcode DerivedData, then execute simulator/macOS Demo journeys and static boundary audits. Record exact commands, counts, destinations, evidence, and external gaps in one durable report; do not change feature behavior during this milestone except for a test-backed defect discovered by verification.

**Tech Stack:** SwiftPM, xcodebuild, XCTest/XCUITest, simctl, codesign/plutil, rg, git, macOS Console/Instruments network/signpost inspection.

## Global Constraints

- Inherit every constraint from `2026-07-17-wattline-completion.md`.
- Milestones 1–5 must be approved and green before this plan starts.
- Build-for-testing is not an executed test result.
- A simulator install/launch failure before XCTest begins is environment evidence, not a pass or a code failure.
- Optional router networking is allowed only through WattlineNetwork to user-selected LAN/VPN/WAN endpoints; no Wattline cloud, OTA CDN, analytics, or third-party network path exists.
- Do not edit contracts/OEM references, add OTA/Timers, or waive a failed invariant to finish the report.

---

### Task 1: Run fresh package and source-boundary verification

**Files:**
- Create: `peakdo/apple/docs/superpowers/reports/2026-07-17-wattline-non-ota-verification.md`

**Interfaces:**
- Produces: package counts and static-boundary evidence in the final report.
- Consumes: approved Milestones 1–5.

- [ ] **Step 1: Create the report skeleton**

```markdown
# Wattline Non-OTA Verification Report

## Environment
- Commit:
- Xcode / Swift:
- macOS:
- iOS simulator UUID/runtime:

## Executed tests
| Suite | Command | Tests | Failures | Evidence |
|---|---|---:|---:|---|

## Builds and configuration
## Demo journeys
## Boundary and privacy audits
## External evidence matrix
## Verdict
```

Fill every field from actual command output; do not pre-populate pass claims.

- [ ] **Step 2: Run package suites from clean scratch paths**

```bash
set -o pipefail
swift test --package-path peakdo/apple/WattlineCore --scratch-path /tmp/wattline-core-release | tee /tmp/wattline-core-release.log
swift test --package-path peakdo/apple/WattlineUI --scratch-path /tmp/wattline-ui-release | tee /tmp/wattline-ui-release.log
swift test --package-path peakdo/apple/WattlineNetwork --scratch-path /tmp/wattline-network-release | tee /tmp/wattline-network-release.log
```

Use new scratch-directory names if those paths already exist; do not delete unrelated `/tmp` content. Expected: zero failures. Record exact test counts and elapsed times.

- [ ] **Step 3: Run package boundary audits**

```bash
rg -n '^import (SwiftUI|UIKit|AppKit|ActivityKit|WidgetKit|AppIntents|UserNotifications|ServiceManagement|Network|Security)$|URLSession|NWBrowser|NWConnection' \
  peakdo/apple/WattlineCore/Sources
rg -n '^import (UIKit|AppKit|ActivityKit|WidgetKit|AppIntents|UserNotifications|ServiceManagement|Network|Security)$|URLSession|NWBrowser|NWConnection' \
  peakdo/apple/WattlineUI/Sources
rg -n '^import (Network|Security)$|URLSession|NWBrowser|NWConnection' \
  peakdo/apple/WattlineNetwork/Sources
```

Expected: first two commands return no matches; the third lists only WattlineNetwork files. Paste actual output into the report.

- [ ] **Step 4: Commit the report scaffold and package evidence**

```bash
git add peakdo/apple/docs/superpowers/reports/2026-07-17-wattline-non-ota-verification.md
git commit -m "test: record Wattline package verification"
```

### Task 2: Execute complete iOS app, widget, and UI coverage

**Files:**
- Modify: `peakdo/apple/docs/superpowers/reports/2026-07-17-wattline-non-ota-verification.md`

**Interfaces:**
- Produces: real iOS XCTest/XCUITest counts and generic build evidence.

- [ ] **Step 1: Confirm a clean installed simulator**

```bash
xcrun simctl list devices available
xcrun simctl bootstatus "$WATTLINE_SIMULATOR_ID" -b
xcrun simctl uninstall "$WATTLINE_SIMULATOR_ID" com.keithah.wattline || true
```

Record the UUID and runtime. If launch service is unhealthy, create or select another installed iOS 17+ simulator and rerun; do not use a simulator occupied by another test job.

- [ ] **Step 2: Execute full iOS scheme tests**

```bash
set -o pipefail
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination "platform=iOS Simulator,id=$WATTLINE_SIMULATOR_ID" \
  -derivedDataPath /tmp/wattline-ios-release \
  CODE_SIGNING_ALLOWED=NO | tee /tmp/wattline-ios-release.log
```

Expected: WattlineTests and WattlineUITests both execute with zero failures. Record per-bundle counts and any skipped OS-only cases.

- [ ] **Step 3: Execute widget tests and generic build**

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineWidgets \
  -destination "platform=iOS Simulator,id=$WATTLINE_SIMULATOR_ID" \
  -derivedDataPath /tmp/wattline-ios-widget-release CODE_SIGNING_ALLOWED=NO
xcodebuild build -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/wattline-ios-generic-release CODE_SIGNING_ALLOWED=NO
```

Expected: executed widget provider/config tests and successful generic build.

- [ ] **Step 4: Record evidence and commit**

```bash
git add peakdo/apple/docs/superpowers/reports/2026-07-17-wattline-non-ota-verification.md
git commit -m "test: record Wattline iOS verification"
```

### Task 3: Execute complete macOS app and widget coverage

**Files:**
- Modify: `peakdo/apple/docs/superpowers/reports/2026-07-17-wattline-non-ota-verification.md`

**Interfaces:**
- Produces: real macOS XCTest and generic build evidence.

- [ ] **Step 1: Execute macOS app tests**

```bash
set -o pipefail
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineMac \
  -destination 'platform=macOS' -derivedDataPath /tmp/wattline-mac-release \
  CODE_SIGNING_ALLOWED=NO | tee /tmp/wattline-mac-release.log
```

Expected: MacAppModel, Demo, menu title, system adapter, popover, navigation, intents, and Expert tests execute with zero failures.

- [ ] **Step 2: Execute macOS widget tests and generic build**

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineWidgets \
  -destination 'platform=macOS' -derivedDataPath /tmp/wattline-mac-widget-release \
  CODE_SIGNING_ALLOWED=NO
xcodebuild build -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineMac \
  -destination 'generic/platform=macOS' -derivedDataPath /tmp/wattline-mac-generic-release \
  CODE_SIGNING_ALLOWED=NO
```

Expected: widget executes where the scheme provides tests and macOS app/embedded extension build successfully.

- [ ] **Step 3: Inspect built metadata and dependency graph**

```bash
plutil -p /tmp/wattline-mac-generic-release/Build/Products/Debug/WattlineMac.app/Contents/Info.plist
codesign -d --entitlements :- /tmp/wattline-mac-generic-release/Build/Products/Debug/WattlineMac.app 2>&1 || true
xcodebuild -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineMac \
  -destination 'generic/platform=macOS' -showBuildSettings
```

Confirm LSUIElement default, macOS 14 floor, bundle ID, widget embedding, and app group from actual products/settings. Unsigned entitlement inspection may be unavailable; record that rather than claiming success.

- [ ] **Step 4: Record evidence and commit**

```bash
git add peakdo/apple/docs/superpowers/reports/2026-07-17-wattline-non-ota-verification.md
git commit -m "test: record Wattline macOS verification"
```

### Task 4: Execute Demo journeys and ownership/reconciliation probes

**Files:**
- Modify: `peakdo/apple/docs/superpowers/reports/2026-07-17-wattline-non-ota-verification.md`

**Interfaces:**
- Produces: simulator/local macOS proof that every implemented P1 surface is navigable without hardware.

- [ ] **Step 1: Run the iOS Demo journey**

Use XCUITest launch arguments/fixtures to perform: onboarding → Demo → Home telemetry → DC/USB confirmed toggles → Limits SET/GET → Shortcuts gallery → Settings/system surfaces → Devices → two-device switcher → Connect a real device. Assert persistent DEMO badge and no Timers destination.

- [ ] **Step 2: Run the macOS Demo journey**

Launch WattlineMac and verify: menu title changes with charging state; popover remains open during pending controls; confirmed telemetry clears pending; active-device picker; optional Home/Devices/Shortcuts/Settings window; Dock preference; visible launch-at-login error from injected test mode; Connect a real device exits Demo without a second owner.

- [ ] **Step 3: Run focused invariant probes**

```bash
swift test --package-path peakdo/apple/WattlineCore --filter QuirkRegressionTests
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination "platform=iOS Simulator,id=$WATTLINE_SIMULATOR_ID" CODE_SIGNING_ALLOWED=NO \
  -only-testing:WattlineTests/ActiveDeviceSwitchingTests \
  -only-testing:WattlineTests/IntentOperationServiceTests \
  -only-testing:WattlineTests/ExpertOperationTests
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineMac \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:WattlineMacTests/MacPopoverOperationTests \
  -only-testing:WattlineMacTests/MacDemoModeTests
```

Expected: TYPE-C mode, bypass, limits, expected disconnect, generation quarantine, intent confirmation, and one-owner tests all pass.

- [ ] **Step 4: Record evidence and commit**

Attach screenshots/XCResult references where available, then:

```bash
git add peakdo/apple/docs/superpowers/reports/2026-07-17-wattline-non-ota-verification.md
git commit -m "test: record Wattline Demo journeys"
```

### Task 5: Complete privacy, scope, and external-evidence audit

**Files:**
- Modify: `peakdo/apple/docs/superpowers/reports/2026-07-17-wattline-non-ota-verification.md`

**Interfaces:**
- Produces: final deterministic/external matrix and release verdict.

- [ ] **Step 1: Audit network and cloud boundaries**

```bash
rg -n 'URLSession|NWBrowser|NWConnection|import Network|import Security' peakdo/apple \
  -g '*.swift' -g '!WattlineNetwork/**' -g '!**/.build/**' -g '!**/build/**'
rg -n 'api\.peakdo\.ca|fw-api|analytics|telemetry.*upload|CloudKit|Firebase|Sentry' \
  peakdo/apple -g '*.swift' -g '*.plist' -g '*.entitlements' \
  -g '!**/.build/**' -g '!**/build/**'
```

Classify legitimate app-local snapshot “telemetry” strings separately from network upload. Expected: no networking outside WattlineNetwork and no cloud/OTA/analytics endpoint.

- [ ] **Step 2: Audit ownership, widgets, scope, and unchanged references**

```bash
rg -n 'func connect\(|BLETransport\(|RouterTransport\(|DeviceSession\(' \
  peakdo/apple/Wattline peakdo/apple/WattlineMac peakdo/apple/WattlineAppShared \
  peakdo/apple/WattlineIntentSurfaces peakdo/apple/Wattline/WattlineWidgets
rg -n 'Timers|TimerRow|scheduledOnOff|enterOTA|api\.peakdo\.ca' \
  peakdo/apple/Wattline peakdo/apple/WattlineMac peakdo/apple/WattlineUI/Sources \
  peakdo/apple/WattlineAppShared peakdo/apple/WattlineIntentSurfaces
git diff 50e5e8da -- peakdo/Wattline-SPEC.md peakdo/src peakdo/scan.py 'peakdo/verify*.py'
git diff --check
```

Manually classify matches. Expected: AppModel and MacAppModel are the only connect owners; widget/intents/catalog contain none; no Timers/OTA path was added; contract/OEM diff is empty for this completion program.

- [ ] **Step 3: Fill the external-evidence matrix**

Record pass/fail/unverified plus reproduction commands for:

- Bluetooth/router identity correlation against one physical MAC/CID.
- `_wattline._tcp` advertisement authority/port/fingerprint from a real router.
- local-network permission and pinned HTTPS/insecure-WAN warning.
- macOS popover click-to-confirm signpost below 1.5 seconds.
- signed Launch at Login and installed macOS widget.
- Shortcuts app/Siri discovery and 10-second out-of-range execution.
- background Live Activity full discharge and honest disconnect staleness.
- low-battery background wake and notification DC-off confirmation.
- BLE PIN and factory-mode behavior on recoverable hardware.

Unavailable evidence remains `UNVERIFIED (external)` and never becomes a simulated pass.

- [ ] **Step 4: Write the final verdict and commit**

The report verdict is `NON-OTA ROADMAP COMPLETE` only if every deterministic suite/build/audit is green and every unavailable external check is explicitly classified. Otherwise use `BLOCKED: <specific deterministic blocker>`.

```bash
git add peakdo/apple/docs/superpowers/reports/2026-07-17-wattline-non-ota-verification.md
git commit -m "test: complete Wattline non-OTA verification"
```

Stop for final review. Do not start OTA work.
