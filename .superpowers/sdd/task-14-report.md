# Task 14 report — Widget and Activity target configuration

## Changes

- Added the multi-platform `WattlineWidgets` app-extension target to the Xcode project.
- Linked the `WattlineCore` and `WattlineUI` package products.
- Configured iOS 17 and macOS 14 deployment floors and conditional widget bundle IDs:
  `com.keithah.wattline.widgets` on iOS and `com.keithah.wattline.mac.widgets` on macOS.
- Added the widget app-group entitlement (`group.com.keithah.wattline`) and extension Info.plist.
- Embedded the extension in the iOS Wattline app through the existing Embed Foundation Extensions phase.
- Added `NSSupportsLiveActivities = true` to the iOS app Info.plist.
- Added project configuration regression tests covering target type, package products, bundle IDs,
  deployment floors, entitlement, embedding, and Live Activity plist configuration.

## Verification

- Duplicate pbxproj object-ID audit: passed (no duplicate 24-character object IDs).
- `git diff --check`: passed.
- `xcodebuild -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineWidgets -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`: **BUILD SUCCEEDED**.
- `xcodebuild -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineWidgets -sdk macosx -destination 'generic/platform=macOS' build CODE_SIGNING_ALLOWED=NO`: **BUILD SUCCEEDED**.
- `xcodebuild -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineTests -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build-for-testing CODE_SIGNING_ALLOWED=NO`: **TEST BUILD SUCCEEDED**.
- Runtime `test-without-building` was not run because Xcode requires a concrete simulator device; the generic destination is intentionally build-only.

No Tasks 15–18 or macOS app work was included.

## Static-review correction

`Phase2ProjectConfigurationTests` now scopes every assertion to the WattlineWidgets native target and its two build configuration objects. The regression tests explicitly prove that the widget extension alone carries the iOS/macOS floors, conditional bundle identifiers, entitlement/Info.plist paths, and WattlineCore/WattlineUI package dependencies; the iOS Wattline app alone owns the Embed Foundation Extensions phase and is not macOS-capable. This prevents an unrelated target's matching string from making the test pass after a widget configuration mutation.

Verification after correction:

- WattlineTests generic iOS `build-for-testing`: **TEST BUILD SUCCEEDED**.
- WattlineWidgets generic iOS build: **BUILD SUCCEEDED**.
- WattlineWidgets generic macOS build: **BUILD SUCCEEDED**.
- Runtime XCTest was not run because generic destinations do not provide a concrete simulator device.

## Root-path correction

The configuration test now resolves `#filePath` by removing both `WattlineTests` and `Wattline`, then explicitly addresses `Wattline/Wattline.xcodeproj`, `Wattline/Wattline/Info.plist`, and `Wattline/WattlineWidgets/WattlineWidgets.entitlements` from the Apple project root. This matches the checked-in source layout and prevents accidental dependence on the test bundle's intermediate directory.

Verification: generic WattlineTests iOS build-for-testing and generic WattlineWidgets iOS build both succeeded.
