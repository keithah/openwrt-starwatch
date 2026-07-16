# Task 11 report

Commits: `593b02b0..ea938479`

Added an injected `NotificationCenterAdapter` and `LowBatteryNotificationCoordinator` in the iOS app target. Authorization is requested only on the first enable transition; category registration includes the DC action only when `FF_DC_OUT_CONTROL` resolves. Snapshot battery events feed the Core `LowBatteryPolicy`, preserving already-low and hysteresis behavior. The DC action uses the existing `DeviceOperationBroker.withConnection(to:timeout:)` and `DeviceCommand.setDC(false)`, then waits for authoritative `dcEnabled == false` telemetry before success.

Tests cover authorization denial/retry, persisted threshold/enable behavior, structural action absence without capability, broker result mapping, already-low behavior, and authoritative telemetry success. Generic iOS build-for-testing passed with `CODE_SIGNING_ALLOWED=NO`; runtime XCTest requires a booted/unlocked simulator and signing.
