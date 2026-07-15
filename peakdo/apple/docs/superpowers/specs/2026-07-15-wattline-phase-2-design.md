# Wattline Phase 2 Design

**Date:** 2026-07-15  
**Branch:** `codex/wattline-phase-2`  
**Base:** `codex/wattline-phase-1` at `36108f38`  
**Status:** Approved design

## 1. Objective

Phase 2 turns the iOS MVP into a private, cross-platform companion with device settings, system surfaces, macOS access, App Intents, and low-battery automation. It reuses the Phase 1 BLE engine and preserves its invariants: one transport owner per app process, one serialized transaction in flight per device, telemetry-is-truth reconciliation, capability-driven composition, generation-tokened callback quarantine, and no networking.

The authoritative product contract remains `peakdo/Wattline-SPEC.md`, especially F9 and F11–F16 in §2, capability gating in §5.6, quirks in §5.7, system surfaces in §6, macOS in §7, Demo Mode in §10, and the Phase 2 exit criteria in §12. `peakdo/API.md` remains authoritative for protocol behavior. Neither contract document nor the OEM reference sources are modified.

## 2. Approved Scope Decision

F10 Schedules is removed from this implementation by explicit product-owner direction. Wattline will not add the timer codec, timer CRUD, timer UI, Demo timer behavior, or timer tests. The existing Timers tab is removed entirely from iOS and is not added to macOS.

This is a scoped deviation from the written Phase 2 feature list; the contract document itself remains unchanged. All other Phase 2 work covers F9 and F11–F16. Phase 3 features remain excluded: OTA installation/CDN access, BLE PIN, factory mode, widgets beyond the specified small/medium families, and later automation or history work.

## 3. Approved Product Decisions

- Use a shared-domain-kernel architecture in `WattlineCore` with thin platform coordinators. Do not add another SPM package.
- Bundle identifiers:
  - iOS app: `com.keithah.wattline`
  - macOS app: `com.keithah.wattline.mac`
  - widget extension: `com.keithah.wattline.widgets`
  - app group: `group.com.keithah.wattline`
- Restart is available for every connected application-mode Link-Power device. Only Shut Down is gated by `FF_SHUTDOWN`, because the protocol defines no restart feature bit.
- Low-battery alerts are opt-in, default to a 20% threshold, fire once per downward crossing during discharge, and re-arm after the battery rises three percentage points above the threshold.
- Both charging and discharging Live Activity preferences default on, subject to system Activity authorization.
- Current Time drift uses a standard `0x2A2B` read only when CoreBluetooth reports the characteristic as readable. Otherwise Settings honestly reports that drift is unavailable.
- macOS launches menu-bar-only by default. Showing the Dock icon is an opt-in persisted preference.

## 4. Milestones

Phase 2 is delivered through five approval-gated vertical milestones:

1. Settings
2. Shared snapshot and low-battery policy
3. iOS Live Activities and widgets
4. macOS menu-bar app and Notification Center widget
5. App Intents gallery

Each milestone starts with failing, non-vacuous tests, ends with all Core/UI/app suites green, includes relevant platform builds and audits, and stops for product-owner approval before the next milestone begins.

## 5. Architecture

### 5.1 WattlineCore

`WattlineCore` remains free of SwiftUI, UIKit, ActivityKit, WidgetKit, AppIntents, UserNotifications, and ServiceManagement. It may use Foundation. Phase 2 adds focused domain types and policies:

- A versioned `SharedDeviceSnapshot` containing device identity, resolved feature bits, battery level/status/runtime, DC and USB-C power and port state, connection state, and a wall-clock observation timestamp.
- Snapshot encoding/decoding and an actor-isolated app-group store suitable for app and extension consumers.
- A pure material-change policy that separates snapshot persistence, Live Activity updates, and throttled widget reload decisions.
- Pure snapshot staleness and direction-aware runtime presentation inputs.
- Pure Live Activity lifecycle decisions for start, update, idle end, disconnected end, and lifetime renewal.
- A low-battery threshold state machine with edge triggering and 3% hysteresis.
- Platform-neutral operation results used by notification actions and intents.
- Optional standard Current Time decoding/read support without inventing a proprietary command.

The existing `DeviceTransport`, `DeviceSession`, `SerializedTransactions`, `MutationReconciler`, `DemoTransport`, `ReplayTransport`, feature resolver, and verified command factories remain the execution foundation. Phase 2 extends them only where an approved surface needs a missing capability; it does not rebuild them.

### 5.2 WattlineUI

`WattlineUI` supplies reusable, capability-composed views and presentation models:

- Device-information and maintenance Settings sections.
- Compact `BatteryHero` and `PortCard` variants for macOS popover use.
- Shared snapshot/status presentation inputs for widgets and Live Activities where framework boundaries allow reuse.
- Shortcuts gallery cards and low-battery preference controls.
- The existing semantic theme on every surface: green charging, orange discharging, neutral idle, monospaced numerals.

WidgetKit `Widget` declarations, ActivityKit attributes/configuration, App Intent declarations, and operating-system coordinators remain in their owning app or extension targets.

### 5.3 App and Extension Targets

The Xcode project contains:

- The existing iOS 17+ app, expanded with Settings, snapshot fan-out, notifications, Live Activity coordination, and in-process App Intents.
- A macOS 14+ app with `MenuBarExtra`, optional main `NavigationSplitView` window, launch-at-login support, and menu-bar-only default behavior.
- One iOS/macOS WidgetKit extension with small and medium widgets. On iOS it also hosts `ActivityConfiguration` for the Live Activity.

The iOS app and macOS app each own exactly one BLE transport/session within their own process. Widgets never construct or import a BLE transport. In-process intents and notification actions enter through the app's actor-isolated device-operation broker rather than creating a competing owner.

## 6. Capability Composition

Capability gating remains FEATURES → CID → model string. Unsupported features are absent from the composed view tree and gallery rather than disabled or visually hidden.

| Capability | Phase 2 surfaces |
|---|---|
| `FF_BATTERY_CAPACITY` | snapshot battery fields, Live Activity, widgets, Get Battery Level intent, low-battery preference/notification |
| `FF_DC_OUT_PORT` | Settings DC status, snapshot DC fields, compact DC card |
| `FF_DC_OUT_CONTROL` | Settings/popover DC toggle, Toggle DC intent, notification action eligibility |
| `FF_USB_PORT` | snapshot USB-C fields, compact USB-C card |
| `FF_USB_POWER_LIMIT` | Set USB-C Limit intent and gallery card |
| `FF_USB_OUTPUT_CONTROL` | macOS popover USB-C toggle |
| `FF_DC_BYPASS` | Settings bypass status |
| `FF_DC_BYPASS_CONTROL` | Settings bypass toggle |
| `FF_SHUTDOWN` | Shut Down row |

Restart has no feature bit and is available for connected application-mode devices. OTA-mode discoveries do not enter Settings. A supported action may be temporarily disabled while disconnected; that is connection-state handling, not capability hiding.

## 7. Settings (F9)

Settings replaces the Phase 1 placeholder and removes the Timers tab from the connected shell.

### 7.1 Device Information

The screen renders model, parsed hardware/variant, app firmware, OTA bootloader, and MAC from the active handshake snapshot. Persisted identity is used while disconnected and rendered with the existing stale treatment. No identity is synthesized from a control response.

### 7.2 Clock Sync

The existing handshake continues writing the verified ten-byte Current Time value on every connection. Settings exposes “Sync now,” records the wall-clock time of a successful write, and optionally re-reads `0x2A2B` only if the characteristic reports read support. A valid standard Current Time value yields phone-versus-device drift. Unsupported reads and read failures yield “Drift unavailable,” not an estimated value. Drift over two minutes renders a warning.

### 7.3 DC and Bypass

DC and bypass controls call the existing `.setDC` and `.setBypass` commands through `DeviceSession`. The UI renders pending state without changing telemetry. DC resolves from `DcPortStatus.enabled` within the existing 3-second window. Bypass ignores its nonstandard reply result and resolves only from `DcPortStatus.bypassOn` within ten seconds.

### 7.4 Restart

Restart presents confirmation, performs `.restart`, and uses the existing disconnect-as-success policy including write-error-while-disconnecting behavior. The app enters a “Restarting…” presentation state and retries the stored peripheral for up to 30 seconds, accommodating the observed approximately 15-second reboot. Exhausting that window leaves a visible Retry action. An ordinary write failure or unrelated disconnect remains a failure.

### 7.5 Shut Down

Shut Down is structurally present only with `FF_SHUTDOWN`. Its destructive confirmation states that the physical device button is required to turn the station back on. The action sends the existing `"FM"` write, treats the expected disconnect as success, disarms automatic reconnect, clears active presentation state, and returns to scan.

### 7.6 Demo Mode

Demo Mode exposes all supported Settings rows, simulates clock sync, DC/bypass confirmation, restart/reconnect, and shutdown-to-scan, and retains the persistent DEMO badge. It never constructs CoreBluetooth state.

## 8. Shared Snapshot and Fan-out

Every authoritative session update is reduced to a `SharedDeviceSnapshot`. A control request alone never changes it. Material changes are:

- battery level change of at least one percentage point;
- charging/discharging/idle status change;
- connection-state change;
- confirmed DC or USB-C port-state change; or
- confirmed material port-power change used by a system surface.

The app persists snapshots atomically to the app group. Snapshot writes and Live Activity updates may happen more often than widget reloads. `WidgetCenter.reloadTimelines` is requested immediately for status flips and otherwise no more than once per fifteen minutes during steady operation. The last reload time is stored independently from the telemetry timestamp.

Staleness is computed by each reader from `observedAt` and the current wall clock. A corrupt, unknown-version, or absent snapshot produces an unavailable state; it never produces fabricated zero telemetry.

## 9. Low-battery Notification (F16)

The preference defaults off with a 20% threshold. Wattline requests notification authorization only when the user enables it. While battery capability exists, the pure policy emits once when discharging telemetry crosses downward through the threshold. It re-arms when level reaches threshold + 3 percentage points, allowing a later genuine discharge episode without repeated notifications around the boundary.

The notification includes “Turn off DC Port” only when `FF_DC_OUT_CONTROL` is resolved. Selecting it wakes/opens Wattline as required, enters the shared operation broker, allows at most ten seconds to reconnect, performs `.setDC(false)`, and reports success only after authoritative DC telemetry confirms off. Timeout, denial, unsupported capability, and unavailable device states produce clear outcomes.

## 10. iOS System Surfaces (F11–F12)

### 10.1 Live Activity

Charging and discharging auto-start preferences default on. A Live Activity exists only for a battery-capable device and only when Activity authorization permits it. It shows percentage, direction-aware runtime, aggregate DC plus USB-C output power, semantic charging/discharging color, and last-update honesty.

The pure lifecycle policy directs the coordinator to:

- start on status `1` or `-1` when the corresponding preference is enabled;
- update on material fresh snapshots;
- retain an honest last-seen state during a short disconnect;
- end five minutes after sustained idle;
- end after more than fifteen minutes disconnected; and
- renew near ActivityKit's lifetime limit only when a significant fresh update exists.

ActivityKit request/update/end failures do not affect BLE state or snapshot persistence.

### 10.2 Widgets

Small and medium widgets deep-link to the dashboard and read only the app-group snapshot. Small shows battery level/state and staleness. Medium adds direction-aware runtime plus DC and USB-C power. Both render “as of” information when data is no longer live. When no eligible snapshot exists, they render an unavailable setup state rather than attempting BLE.

## 11. macOS Surfaces (F13–F14)

The macOS app starts as a menu-bar-only accessory. Its title is monochrome and monospaced: `⚡︎ 84%` while charging and `84%` otherwise. If level is unknown, it uses a neutral device/bolt glyph instead of inventing a percentage.

The popover reuses compact `BatteryHero` and `PortCard` variants. Supported DC and USB-C toggles call the same commands and reconciliation machinery as iOS and render pending state inline. The optional main window uses `NavigationSplitView` with Home, Shortcuts, and Settings destinations; there is no Timers destination.

“Show in Dock” is off by default and persists a runtime activation-policy choice. Launch at login uses `SMAppService`; registration failures are visible in Settings. The macOS app owns BLE and app-group snapshot writes. The shared WidgetKit extension supplies Notification Center widgets and remains read-only.

Deterministic tests cover command-to-confirmation behavior. Signposts record actual popover command-to-confirmation duration for the Phase 2 `<1.5 s` hardware criterion.

## 12. App Intents and Gallery (F15)

An actor-isolated device-operation broker serializes intent and notification-action access to the app's active transport/session. It reuses an existing connection or performs a generation-tokened reconnect for at most ten seconds. It never creates a second simultaneous BLE owner.

### 12.1 Toggle DC Port

The intent accepts on, off, or toggle. It requires `FF_DC_OUT_CONTROL`; toggle derives its target from authoritative DC telemetry. It performs `.setDC` and returns only after telemetry confirmation.

### 12.2 Get Battery Level

The intent requires `FF_BATTERY_CAPACITY`. A live result includes percentage, status, and direction-aware runtime. If reconnection fails, the last valid snapshot is returned with `isStale = true` and wall-clock age. With no valid snapshot, the intent fails clearly.

### 12.3 Set USB-C Limit

The intent supports Global, Input, and Output with exactly 30/45/60/65/100/140 W. It requires `FF_USB_POWER_LIMIT`, performs SET followed by GET through the existing factory/follow-up path, and speaks/returns only the confirmed device value.

### 12.4 Discovery and Capability Behavior

The in-app gallery structurally omits unsupported cards. App Intent types are statically registered by iOS and cannot be dynamically removed, so direct Shortcuts invocations repeat the capability check and return an explicit unsupported-device error. Per-intent device queries list only eligible saved devices.

`ForegroundContinuableIntent` is used when Wattline must open or resume for Bluetooth access. Already-connected operations remain background-capable where the OS permits. Demo execution uses `DemoTransport` and labels its result as simulated. The low-battery gallery card accurately describes local notifications and a time-based Get Battery Level recipe; it does not claim a third-party event trigger.

## 13. Error and Concurrency Model

- Device telemetry or confirmed readback is authoritative for every mutation.
- Expected-disconnect commands retain the Phase 1 restart/shutdown state machine, including the disconnecting write-error path.
- All commands remain serialized through the existing transaction engine.
- App coordinators and the operation broker are actor-isolated under Swift 6.
- Reconnects and long-lived callbacks carry generation tokens; stale generations cannot mutate a newer session.
- Continuations are resumed exactly once on success, failure, timeout, cancellation, or disconnect.
- Snapshot, ActivityKit, WidgetKit, notification, AppIntent, and ServiceManagement errors are isolated from the BLE session and surfaced at the appropriate UI boundary.
- No Phase 2 target contains networking code, URLSession usage, web sockets, or firmware CDN references.

## 14. Testing Strategy

Every behavior is introduced with a failing test that would fail if production behavior regressed.

### 14.1 Core

- Snapshot round-trip, version rejection, corruption handling, and wall-clock staleness.
- Material-change and widget-throttle decision tables with injected clocks.
- Live Activity lifecycle tables covering status transitions, five-minute idle, fifteen-minute disconnect, and renewal.
- Low-battery downward crossing, no-repeat behavior, 3% re-arm, status/capability gating, and preference-disabled behavior.
- Current Time decoding and optional-read policy without assuming unsupported hardware behavior.
- Replay/Demo regression tests proving Settings and broker operations preserve serialization, telemetry reconciliation, and disconnect-as-success quirks.

### 14.2 UI

- Capability composition proves unsupported Settings rows, widgets/activities, gallery cards, and popover controls are absent.
- Stale, unavailable, pending, charging, discharging, and idle presentation assertions.
- Compact component APIs execute callbacks and retain semantic presentation inputs.

### 14.3 Apps and Extensions

- Settings routing, cached identity, optional drift, confirmations, restart, shutdown, and Demo behavior.
- Notification permission timing, category/action registration, broker routing, and confirmed DC-off outcomes.
- Live Activity coordinator commands against a fake adapter.
- Widget provider reads snapshots only and never receives a transport dependency.
- macOS activation-policy and launch-at-login adapters with injected fakes.
- Intent live, reconnect, timeout, stale-snapshot, unsupported, SET-then-GET, and Demo outcomes.
- UI tests for each simulator-accessible Phase 2 surface.

### 14.4 Structural Audits

- iOS remains 17.0+ and macOS is 14.0+.
- App group, ActivityKit, WidgetKit, background BLE, notification, and `NSSupportsLiveActivities` configuration is present only where required.
- `WattlineCore` has no forbidden UI/framework imports.
- Widget extension has no code path that constructs or uses `DeviceTransport`, `DeviceSession`, or CoreBluetooth. A model-only indirect `WattlineCore` package dependency through `WattlineUI` is acceptable.
- Capability-hidden elements are absent from the view tree.
- Contract/OEM reference files remain unchanged.
- No networking APIs, URL literals, ATS exceptions, or later-phase OTA implementation exist.

## 15. Milestone Verification and External Checks

Each milestone runs clean Core and UI package tests, iOS tests and UI tests, relevant macOS/widget tests, generic iOS and macOS builds, diff checks, scope checks, entitlement checks, forbidden-import checks, and a zero-network source audit. The handoff contains the scoped diff, complete logs, and any external checks still open, then waits for approval.

The following Phase 2 exit evidence cannot be established solely by deterministic CI and remains explicitly hardware/platform-gated:

- Live Activity longevity and honest staleness over a complete real discharge cycle while the phone locks and backgrounds the app.
- Real macOS popover command-to-confirmation latency below 1.5 seconds.
- End-to-end Shortcuts-app discovery and execution on signed builds.
- Background notification wake and “Turn off DC Port” action against real hardware.
- Packet-level/network observation supporting the “Data Not Collected” privacy label.

These checks are recorded, not silently treated as passed. Phase 2 is exit-ready only after the deterministic suites and the applicable external acceptance runs succeed.
