# Task 10 report — iOS snapshot coordinator and app group

Commit: `9bffeccc` (`feat: persist app group snapshots`)

## Changed

- Added `@MainActor SnapshotCoordinator` under `WattlineShared`.
- Accepted telemetry is reduced to the Core `SharedDeviceSnapshot` model; stale generations and pending mutations are rejected.
- Material fan-out decisions are produced by `SnapshotMaterialChangePolicy`; widget reload timestamps are wall-clock `Date` values and are tracked independently.
- Writes are coalesced behind an explicit `flushPendingWrites()` boundary, allowing one store write for a burst. Demo coordinators never write the injected store.
- Added the `group.com.keithah.wattline` application-group entitlement.
- Added iOS tests for authoritative-vs-pending telemetry, stale generation quarantine, Demo no-write behavior, and entitlement declaration.

## Verification

`xcodebuild -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineTests -destination 'generic/platform=iOS Simulator' build-for-testing CODE_SIGNING_ALLOWED=NO`

Result: **TEST BUILD SUCCEEDED**.

Runtime XCTest execution remains subject to the existing local simulator/device launcher limitation; no runtime pass is claimed here.

## External checks

Real app-group persistence under a signed device, background wake, and hardware telemetry confirmation remain macOS/Xcode/device checks.
