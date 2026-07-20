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

The original direct widget attempt exposed an auto-generated-scheme host-intersection problem: once `WattlineMacTests` existed, Xcode resolved the multi-platform widget scheme against an incompatible test surface and rejected the requested iOS destination. Local locked-device `notification_proxy` messages also appeared during that investigation, but they were environmental noise rather than the widget failure. The review fix replaces that unstable auto scheme with an explicit shared `WattlineWidgets` scheme; its passing exact iOS gate is recorded below.

Final audits:

- `git diff --check`: exit 0, no output.
- `plutil -lint` for the mac plist, entitlements, and project: all `OK`.
- Transport-owner search: exactly one `BLETransport(` and one `DeviceSession(`, both in `MacAppModel`; none in shared/mac administration and no `DeviceOperationBroker` there.
- Mac camera search: no `AVCapture` or `NSCameraUsageDescription` in `WattlineMac`.
- UI layering search: no `WattlineNetwork` source import or package dependency in `WattlineUI`.
- Forbidden endpoint search: no `/device/action`, `/device/usbc-limit`, `/device/bypass-threshold`, or `/device/schedules` in the Task 22 app/shared scope.
- Forbidden-file diff from the Task 21 base: empty.
- No PIN, token, or private key persistence/logging was added.

## Review remediation

The initial Task 22 commit was `11a4edadf87255d897176f28c82fbe9f146fc9df`. The review fix addresses all four Important findings without beginning Task 23:

- Added explicit shared `WattlineWidgets`, `Wattline`, and `WattlineMac` schemes. The widget and iOS schemes retain only `WattlineTests` plus `WattlineUITests`; the Mac scheme retains only `WattlineMacTests`. Explicit app schemes were necessary because adding any shared project scheme suppresses Xcode's auto-generated project schemes.
- Relocated the seven existing router-administration controls into `WattlineShared` and made their text input and QR rendering platform-aware. macOS now consumes the same functional history, Link-Power pairing, pairing-window/QR, token, settings/TLS, advanced, rule CRUD, and power-loss controls as iOS instead of count/label placeholders.
- Made nearby-router rows actionable with a six-digit numeric PIN and client label. Submission goes through `RouterEnrollmentCoordinator`; source clearing and saved-host selection are atomic, and the PIN is cleared at submission, completion, scene deactivation, and disappearance. No PIN is persisted or logged.
- Pairing URLs now select Router Administration at the root. URL, paste, and imported-image payloads take precedence over saved-host detail and show the enrollment form even when saved hosts exist.

Review RED evidence:

- `/tmp/wattline-m5-task22-controller-widgets.log`: the controller's exact widget command exited 70 because of the auto-scheme destination intersection.
- `/tmp/wattline-m5-task22-review-red.log`: the three new Mac administration regressions failed against the placeholder/non-actionable implementation.
- `/tmp/wattline-m5-task22-widget-scheme-test-red.log`: the widget scheme configuration regression failed because no shared widget scheme existed.
- `/tmp/wattline-m5-task22-explicit-app-schemes-red.log`: after adding only the widget scheme, Xcode reported that the project no longer contained a `Wattline` scheme, establishing the need to preserve all three project schemes explicitly.
- `/tmp/wattline-m5-task22-selection-red.log`: the focused direct-selection regression failed before enrollment-source clearing was made atomic with host selection.

Final GREEN gates:

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -resultBundlePath /tmp/WattlineMac-Task22-Fix4.xcresult
```

Result: `** TEST SUCCEEDED **`; `/tmp/WattlineMac-Task22-Fix4.xcresult` reports 7 total, 7 passed, 0 failed, 0 skipped, and 0 expected failures on My Mac, arm64, macOS 26.5.2 (25F84).

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineWidgets -destination 'platform=iOS Simulator,name=Wattline-Tests-2' CODE_SIGNING_ALLOWED=NO -resultBundlePath /tmp/WattlineWidgets-M5.xcresult
```

Result: `** TEST SUCCEEDED **`; `/tmp/WattlineWidgets-M5.xcresult` reports 313 total, 313 passed, 0 failed, 0 skipped, and 0 expected failures on Wattline-Tests-2, iPhone 17e, iOS Simulator 26.5 (23F77). The first post-scheme run reached the suite and exposed five stale test source paths after the view relocation (308 passed, 5 failed); repairing those paths produced this clean exact gate.

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination 'platform=iOS Simulator,name=Wattline-Tests-2' CODE_SIGNING_ALLOWED=NO -resultBundlePath /tmp/Wattline-Task22-Fix.xcresult
```

Result: `** TEST SUCCEEDED **`; `/tmp/Wattline-Task22-Fix.xcresult` reports 313 total, 313 passed, 0 failed, 0 skipped, and 0 expected failures on the same simulator.

```bash
xcodebuild build -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineMac -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Result from the final shared-view state: `** BUILD SUCCEEDED **`; `/tmp/wattline-m5-task22-mac-build-green-final.log` records the universal arm64/x86_64 app build and embedded `WattlineWidgets.appex` validation.

Review-fix audits:

- `git diff --check`: exit 0 with no output.
- Project and Info plist lint: all `OK`; `xcodebuild -list` parses the shared schemes and lists `Wattline`, `WattlineMac`, and `WattlineWidgets`.
- Transport ownership remains exactly one `BLETransport(` and one `DeviceSession(`, both in `MacAppModel`; administration contains neither and contains no `DeviceOperationBroker`.
- No Mac camera capture or camera usage description was added. `WattlineUI` still has no `WattlineNetwork` import or dependency.
- No forbidden device endpoints were introduced. Searches found no secret logging or persistence; all new PIN and administrator-token state is transient and explicitly cleared.
- The fix diff is limited to project schemes/configuration, shared administration view relocation/platform adaptation, Mac administration/root navigation, and their regression tests/report.

## Enrollment lifecycle hardening re-review

The second re-review found two lifecycle races in the Mac enrollment composition. Local cleanup did not remove the URL PIN retained by `RouterEnrollmentRoute`, and both enrollment submission and QR-image recognition used unowned tasks whose stale completions could publish after a source change, host selection, scene transition, or disappearance.

The remediation is intentionally Mac-only:

- Added an observable `MacRouterEnrollmentLifecycle` that owns the current submission or image-import task, cancels it on invalidation, and uses a monotonic generation to reject stale coordinator callbacks and success/failure publication.
- Split local-entry cleanup from destructive lifecycle exit. Replacing a payload clears transient local entry without destroying the new route; background, disappearance, saved-host selection, or a new discovered-router source cancels work and clears the route payload (including its PIN).
- Observed the complete `RouterPairingPayload` in both the root and administration views, so a replacement link for the same device still navigates and refreshes the enrollment form.
- Changed image import to return parsed input without mutating the route. Only the current, non-cancelled source generation may publish that input.
- Disabled source/navigation and editable enrollment controls while a submission is active. The discovered Bonjour service name is now read-only instead of accepting an edit that enrollment ignored.

Lifecycle RED evidence:

- `/tmp/wattline-m5-task22-lifecycle-red.log`: the behavioral suite failed to compile before `MacRouterEnrollmentLifecycle` existed.
- `/tmp/wattline-m5-task22-image-import-red.log`: the expanded suite failed to compile before source-operation generations and non-publishing image parsing existed.

Focused lifecycle GREEN:

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:WattlineMacTests/MacRouterEnrollmentLifecycleTests
```

Result: `** TEST SUCCEEDED **`; `/tmp/wattline-m5-task22-lifecycle-green-final.log` records 5 lifecycle tests passed, 0 failed.

Fresh full Mac gate:

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -resultBundlePath /tmp/WattlineMac-Task22-Lifecycle-Final.xcresult
```

Result: `** TEST SUCCEEDED **`; the result bundle reports 12 total, 12 passed, 0 failed, 0 skipped, and 0 expected failures on My Mac, arm64, macOS 26.5.2 (25F84). The command output is recorded in `/tmp/wattline-m5-task22-lifecycle-full-green-final.log`.

Fresh generic Mac build:

```bash
xcodebuild build -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineMac -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Result: `** BUILD SUCCEEDED **`; `/tmp/wattline-m5-task22-lifecycle-mac-build-final.log` records the universal arm64/x86_64 app build and embedded widget validation.

This lifecycle diff changes only Mac sources, Mac tests, and this report. Shared, widget, iOS, and project configuration sources are unchanged, so the prior exact `WattlineWidgets` and `Wattline` iOS gates remain applicable at 313/313 each and were not rerun. Final audits remained clean: no Mac camera capture or permission, extra transport/session/broker ownership, forbidden endpoints, PIN/token persistence, or secret logging was introduced.
