# Task 18 report — Milestone 3 verification

Date: 2026-07-15

## Test and build verification

- `peakdo/apple/WattlineCore`: `swift test` — **154 tests, 0 failures**.
- `peakdo/apple/WattlineUI`: `swift test` — **18 tests, 0 failures**.
- `xcodebuild -project Wattline/Wattline.xcodeproj -scheme Wattline -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build-for-testing` — **TEST BUILD SUCCEEDED**.
- `xcodebuild -project Wattline/Wattline.xcodeproj -scheme WattlineWidgets -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build-for-testing` — **TEST BUILD SUCCEEDED**.

The generic iOS builds require `CODE_SIGNING_ALLOWED=NO` in this environment because no development team is configured. A concrete simulator test run is unavailable here (the available device is passcode protected); the package suites above execute locally.

## Static audits

- `WattlineCore` contains no SwiftUI/UIKit/ActivityKit/WidgetKit/AppIntents/UserNotifications/ServiceManagement imports. Its only platform import is the existing CoreBluetooth transport implementation.
- Widget sources contain no transport/session construction, CoreBluetooth, or BLE delegate references; widgets consume the shared snapshot provider only.
- No networking implementation (`URLSession`, `URLRequest`, `NWConnection`, OTA/CDN endpoints) exists in WattlineCore, WattlineUI, WattlineShared, or the app. The only URL values are the local `wattline://dashboard` deep link and system Settings URL.
- No Phase-2 timer surface or timer codec was introduced. Scheduler capability/protocol compatibility references and the Phase-1 “no Timers tab” regression tests remain only.
- `Wattline/Wattline/Wattline.entitlements` includes `group.com.keithah.wattline`; `Info.plist` includes `NSSupportsLiveActivities=true` and the `wattline` URL scheme; widget entitlements use the same app group.

## External checks

Live Activity behavior through a locked-device discharge cycle, background wake/reconnect, and real widget timeline refresh still require macOS/Xcode simulator or a physical iOS device. Authoritative BLE telemetry confirmation likewise requires real hardware; Demo mode remains the deterministic in-process path.
