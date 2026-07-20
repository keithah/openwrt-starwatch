# Task 22 implementation report

## Scope and base

- Branch: `codex/wattline-phase-2`
- Starting HEAD: `2068f4aae286dc6b1fa24a10378e8a728a85c1bc` (approved Task 21 HEAD)
- Scope: Task 22 only. Task 23 was not started.
- The optional M4 running-mode cleanup was deferred because it is unrelated to the macOS composition required by this task.

## TDD evidence

Tests were added before the macOS targets and production sources. The required RED command was:

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/wattline-m5-task22-red.log
```

It failed for the expected reason:

```text
xcodebuild: error: The project named "Wattline" does not contain a scheme named "WattlineMac".
```

The final focused GREEN command was:

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/wattline-m5-task22-green.log
```

Result: `** TEST SUCCEEDED **`. Fresh result bundle:

```text
/Users/keith/Library/Developer/Xcode/DerivedData/Wattline-bllgkpgqobwktoceschihenjdzrq/Logs/Test/Test-WattlineMac-2026.07.20_10-32-29--0700.xcresult
```

`xcresulttool get test-results summary` reports 4 total, 4 passed, 0 failed, 0 skipped, and 0 expected failures on My Mac, arm64, macOS 26.5.2 (25F84).

## Implementation

- Added the native macOS 14 `WattlineMac` application and `WattlineMacTests` targets with synchronized roots, local `WattlineCore`/`WattlineUI`/`WattlineNetwork` products, test-host wiring, entitlements, and the existing widget embedded as `com.keithah.wattline.mac.widgets`.
- Added a `MenuBarExtra`, main window, split navigation for Home, Shortcuts, Settings, and Router Administration, Demo indicators, and a real-device connection affordance.
- Added `MacAppModel` as the sole macOS transport/session owner. Its idempotent `start()` constructs one transport and one `DeviceSession`; administration constructs neither.
- Added saved/nearby router administration, LAN discovery, shared administration sections, URL/paste/image enrollment, `NSPasteboard`, `NSOpenPanel`, and Vision QR recognition without camera permission or capture code.
- Moved `RouterAdministrationModel` into `WattlineShared` unchanged.

## Necessary composition deviations

- `RouterConnectionModel`, `RouterEnrollmentRoute`, and `RouterEnrollmentCoordinator` were also moved into `WattlineShared`, because the mac app must consume these existing thin composition types and cannot compile sources owned only by the iOS synchronized root.
- The pure QR recognition/image-import portion moved with enrollment. The existing iOS camera authorization/controller remains available only under `#if os(iOS)`; macOS has no `AVCapture` import or camera surface.
- The app-owned `AppModel.CachedIdentity` scan projection in `RouterConnectionModel` is guarded for iOS. Cross-platform saved-router, discovery, enrollment, and administration behavior remains shared.
- The shared synchronized root excludes the network/admin/enrollment composition files from the widget and iOS unit-test targets, preventing them from acquiring `WattlineNetwork` or duplicate host declarations.
- The existing widget target now builds on macOS as well as iOS. Its ActivityKit-only declarations are guarded for iOS while the ordinary widget remains cross-platform. This was required for embedding the existing widget in the mac app.

## Verification

Required generic macOS build:

```bash
xcodebuild build -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineMac -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Result: `** BUILD SUCCEEDED **`; the universal arm64/x86_64 app build embedded `WattlineWidgets.appex`.

Required full iOS regression gate:

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination 'platform=iOS Simulator,name=Wattline-Tests-2' CODE_SIGNING_ALLOWED=NO
```

Result: `** TEST SUCCEEDED **`. Result bundle:

```text
/Users/keith/Library/Developer/Xcode/DerivedData/Wattline-bllgkpgqobwktoceschihenjdzrq/Logs/Test/Test-Wattline-2026.07.20_10-26-48--0700.xcresult
```

`xcresulttool get test-results summary` reports 311 total, 311 passed, 0 failed, 0 skipped, and 0 expected failures on Wattline-Tests-2 (iPhone 17e), iOS Simulator 26.5 (23F77). This gate builds and tests the iOS widget sources and widget-provider tests through the host scheme.

A supplemental direct `WattlineWidgets` scheme invocation with the named iOS simulator was attempted. Since the now-multi-platform auto-discovered extension scheme resolves to macOS-only, Xcode rejected the iOS destination before building. A subsequent direct `-target WattlineWidgets -sdk iphonesimulator` attempt was interrupted after local locked-device `notification_proxy` noise and no build completion marker. This supplemental attempt is not a Task 22 required gate; widget compatibility is covered by the passing iOS host test and macOS app test/build gates above.

Final audits:

- `git diff --check`: exit 0, no output.
- `plutil -lint` for the mac plist, entitlements, and project: all `OK`.
- Transport-owner search: exactly one `BLETransport(` and one `DeviceSession(`, both in `MacAppModel`; none in shared/mac administration and no `DeviceOperationBroker` there.
- Mac camera search: no `AVCapture` or `NSCameraUsageDescription` in `WattlineMac`.
- UI layering search: no `WattlineNetwork` source import or package dependency in `WattlineUI`.
- Forbidden endpoint search: no `/device/action`, `/device/usbc-limit`, `/device/bypass-threshold`, or `/device/schedules` in the Task 22 app/shared scope.
- Forbidden-file diff from the Task 21 base: empty.
- No PIN, token, or private key persistence/logging was added.
