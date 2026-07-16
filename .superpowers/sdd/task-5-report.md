# Task 5 report

Added non-vacuous restart/shutdown lifecycle unit coverage and Settings UI coverage. Unit tests exercise restarting presentation, same-peripheral reconnect without a scan, successful shutdown-to-scan, ordinary FM write failure retention, and Demo restart/shutdown behavior. UI tests verify Restart/Shut Down controls, destructive confirmation, cancellation, and the absent Timers tab.

`xcodebuild build-for-testing` succeeds for the iOS Simulator destination (`502D4725-7917-40BE-8DE3-9FDE7BBE61F2`). Runtime XCTest execution was not available in this environment, so no runtime pass claim is made.

The pre-existing Task 5 production edits in `AppModel.swift`, `SettingsView.swift`, and `DemoTransport.swift` are preserved and included with the lifecycle tests. No contract, OEM, source, or F10 timer files were edited.

## Task 5 review fixes

Restart recovery is now explicitly scoped to the saved peripheral and transport generation. It drives reconnect through `DeviceOperationBroker`, retries until a 30-second deadline using an injected `DeviceClock`, and quarantines stale completion/timer work. Restart write errors during an expected disconnect still enter recovery. Settings now uses destructive restart confirmation and renders restarting, shutdown, failure, and Retry states. Demo mode retains its persistent badge and real-device affordance while returning to scan.

Verification: `swift test` in WattlineCore passes 142 tests; iOS Simulator app build succeeds. XCTest runtime execution remains unavailable in this environment (the `xcodebuild test` invocation built test bundles but emitted no runtime results).

## Follow-up fix report

Restart recovery now records only the matching generation/peripheral scoped disconnect and refuses the broker connected fast path until that disconnect has occurred. An ordinary restart write error therefore transitions to `restartFailed` with Retry, while a write error accompanying the expected disconnect continues through fresh reconnect recovery. Demo restart no longer self-reconnects outside the broker scope. Stale generation and scope guards remain intact.

Verification: WattlineCore `swift test` passes all 142 tests; iOS Simulator `build-for-testing` succeeds. No simulator runtime was started.

## Task 5 lifecycle test hardening

Added controllable-clock lifecycle coverage for ordinary restart write failure (Retry without recovery), expected-disconnect write-error recovery, deterministic reconnect after a simulated 15 seconds without scan, timeout/Retry at simulated 30 seconds, and quarantine of a late old-scope disconnect. The test transport now gates broker reconnects and records scopes so tests exercise AppModel/Broker recovery rather than transport self-connect.
