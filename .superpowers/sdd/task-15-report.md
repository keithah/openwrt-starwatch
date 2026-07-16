# Task 15 report — Live Activities

Implemented the ActivityKit adapter boundary and Live Activity surfaces.

## Changes

- Added `LiveActivityAdapter` and main-actor `LiveActivityCoordinator`; pure `LiveActivityPolicy` commands translate to request/update/end and ActivityKit errors are isolated.
- Added shared `WattlineActivityAttributes` content state with level, status, runtime, aggregate output, observedAt, and connection fields.
- Added Lock Screen, compact, and minimal Dynamic Island views with charging/discharging/neutral semantic colors and monospaced numerals.
- Added target membership for activity attributes in the iOS app and widget extension; the activity view remains extension-only.
- Added fake adapter tests covering start/update and disconnect-end/error isolation.

## Verification

- Generic iOS simulator build-for-testing: **succeeded** (`/tmp/t15-build.log`).
- `git diff --check`: **passed**.
- Runtime `xcodebuild test-without-building` could not launch because the available device is passcode protected; no runtime pass claim is made (`/tmp/t15-test.log`).
- ActivityKit is confined to app/extension files; WattlineCore remains free of ActivityKit/WidgetKit/UI imports.

No macOS app or Tasks 16–18 work was started.
