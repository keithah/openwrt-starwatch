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

## Static-review corrections

- ContentState `aggregateOutputWatts` now sums authoritative DC and Type-C port output rather than battery net power.
- Added exact ContentState field assertions, including runtime, status, observedAt, connection, and aggregate output.
- Added explicit authorization-denied adapter isolation coverage and idle five-minute end coverage.
- Disconnected activity updates preserve the first disconnected telemetry timestamp through the hold/end window.
- Aggregate output excludes DC input telemetry and Type-C input-only telemetry; Type-C output is counted only for output-capable modes.

Verification after corrections:

- Generic iOS simulator build-for-testing: **succeeded** (`/tmp/t15fix-green.log`).
- Focused runtime test launch was unavailable in this environment because the simulator/app-extension placeholder is rejected and the attached device is passcode protected (`/tmp/t15fix-test.log`).
- `git diff --check`: **passed**.
