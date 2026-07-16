# Task 5 report

Added non-vacuous restart/shutdown lifecycle unit coverage and Settings UI coverage. Unit tests exercise restarting presentation, same-peripheral reconnect without a scan, successful shutdown-to-scan, ordinary FM write failure retention, and Demo restart/shutdown behavior. UI tests verify Restart/Shut Down controls, destructive confirmation, cancellation, and the absent Timers tab.

`xcodebuild build-for-testing` succeeds for the iOS Simulator destination (`502D4725-7917-40BE-8DE3-9FDE7BBE61F2`). Runtime XCTest execution was not available in this environment, so no runtime pass claim is made.

The pre-existing Task 5 production edits in `AppModel.swift`, `SettingsView.swift`, and `DemoTransport.swift` are preserved and included with the lifecycle tests. No contract, OEM, source, or F10 timer files were edited.

## Task 5 review fixes

Restart recovery is now explicitly scoped to the saved peripheral and transport generation. It drives reconnect through `DeviceOperationBroker`, retries until a 30-second deadline using an injected `DeviceClock`, and quarantines stale completion/timer work. Restart write errors during an expected disconnect still enter recovery. Settings now uses destructive restart confirmation and renders restarting, shutdown, failure, and Retry states. Demo mode retains its persistent badge and real-device affordance while returning to scan.

Verification: `swift test` in WattlineCore passes 142 tests; iOS Simulator app build succeeds. XCTest runtime execution remains unavailable in this environment (the `xcodebuild test` invocation built test bundles but emitted no runtime results).
