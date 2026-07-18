# Wattline Completion Design

**Date:** 2026-07-17
**Branch:** `codex/wattline-phase-2`
**Status:** Approved 2026-07-17; implementation plans prepared

## 1. Objective

Finish Wattline's remaining non-OTA roadmap on top of the reviewed Phase 1, Phase 2 system-surface, and optional router-transport work. The result is a native iOS 17+ and macOS 14+ companion with one active device at a time, Demo/Bluetooth/router routes, LAN discovery, native macOS surfaces, App Intents, Expert controls, and multiple saved devices.

`peakdo/Wattline-SPEC.md` remains the product contract and `peakdo/API.md` remains protocol truth. This document records the approved completion scope and resolves choices the product spec leaves open. Existing reviewed transport, reconciliation, capability, snapshot, and generation-quarantine behavior is reused rather than rebuilt.

## 2. Scope

### 2.1 Included

- Phase 2 F13–F15 completion: native macOS menu-bar app, optional main window, macOS Notification Center widget embedding, App Intents, and Shortcuts gallery.
- Phase 3 F18 and F19: Expert BLE PIN/factory-mode controls and multiple saved devices with a one-active-device switcher.
- Optional network-source completion: activate `_wattline._tcp` LAN discovery and support Demo, Bluetooth, and Router routes in both iOS and macOS apps.
- Baseline test repair required to make the current app suite deterministic and non-vacuous before adding features.
- Final iOS/macOS/widget/intent/privacy verification for the implemented scope.

### 2.2 Excluded

- F17 OTA, firmware CDN access, programming, recovery, or firmware UI. OTA remains a separately approved, sacrificial-hardware-gated project.
- F10 timers/schedules UI, BLE timer codec, Demo timer behavior, and Timers navigation. The prior product-owner removal remains in force.
- Simultaneous monitoring or connections to multiple stations.
- Automatic Bluetooth-to-router or router-to-Bluetooth failover.
- Local history charts, watchOS, barrier-free mode, DC-bypass threshold controls, and other §11 backlog items that are not F18/F19.
- Undocumented router or BLE commands. Unsupported features remain structurally absent.

## 3. Product Decisions

- macOS launches menu-bar-only by default and offers an optional full window through “Open Wattline.”
- “Show in Dock” is an opt-in persisted preference; closing the main window does not terminate the menu-bar app.
- Multiple saved devices use exactly one active transport/session per app process.
- Each saved physical device retains its own auto-reconnect preference. Only the selected active device is eligible to reconnect; enabling auto-reconnect on an inactive record does not create a background connection or cycle through candidates.
- Bluetooth is the preferred route when the same physical device is reachable through Bluetooth and a router. Router use remains an explicit Advanced choice; no automatic failover ships in this scope.
- `_wattline._tcp` discovery is active only while a Devices/Scan surface is active. Manual host entry remains available for VPN/Tailscale/WAN use.
- Expert controls are available only on a connected application-mode Bluetooth route. Router and Demo routes omit them unless a future documented protocol endpoint explicitly supports them.
- The formal Phase 2 and Phase 3 work is ordered by dependency rather than feature number: the shared device catalog precedes macOS and App Intents so both consume one identity model.

## 4. Delivery Milestones

1. **Baseline health:** make all current app tests execute deterministically and green; eliminate duplicate/vacuous test behavior.
2. **Device catalog and discovery:** saved-device records, identity correlation, active LAN discovery, manual routes, and one-active-device switching.
3. **macOS:** single-owner runtime, menu bar, popover, optional window, Dock/login settings, Demo/BT/Router selection, and widget embedding.
4. **App Intents:** Toggle DC, Get Battery, Set USB-C Limit, eligible-device entities, production broker registration, and Shortcuts galleries.
5. **Expert controls:** BLE PIN setting and factory mode with protocol-accurate safety copy and structural route gating.
6. **Release verification:** all deterministic suites/builds/audits plus an explicit external-evidence matrix.

Every milestone begins with failing non-vacuous tests, ends with focused and regression suites, commits independently, and stops for review before the next milestone.

## 5. Architecture

### 5.1 Existing package boundaries

- `WattlineCore` owns `DeviceTransport`, `DeviceSession`, `BLETransport`, `DemoTransport`, `ReplayTransport`, protocol codecs/models, serialized transactions, mutation reconciliation, capability resolution, and shared snapshots. It remains free of SwiftUI, UIKit, AppKit, ActivityKit, WidgetKit, AppIntents, UserNotifications, ServiceManagement, Network.framework, Security, and URLSession.
- `WattlineNetwork` remains the only package that imports URLSession, Network.framework, or Security. It owns router HTTP/SSE, TLS pinning, Keychain credentials, router discovery adapters, router host storage, endpoint capability mapping, and router transport behavior.
- `WattlineUI` owns reusable SwiftUI presentation and semantic color/number rules. Shared components contain no AppKit- or UIKit-only behavior.
- Widgets consume only `SharedDeviceSnapshot`; they never construct a transport, broker, session, discovery browser, or credential store.

### 5.2 App-only shared sources

A focused app-only shared source area is compiled into the iOS and macOS apps, but not the widget extension. It may depend on WattlineCore and WattlineNetwork and contains no SwiftUI, UIKit, or AppKit views.

It provides:

- `ConnectionCatalog`: combines saved identities, current Bluetooth discoveries, discovered routers, and manual router hosts into physical-device records.
- `TransportRoute`: Demo, Bluetooth peripheral, or router endpoint.
- `ActiveDeviceSelection`: persisted physical-device selection and chosen route.
- Cross-platform operation and presentation adapters consumed by the two app models and App Intents.

This is a source-membership boundary, not a new transport engine. Platform UI, AppKit, ServiceManagement, ActivityKit, WidgetKit, AppIntents, and UserNotifications remain in their owning targets.

### 5.3 Ownership

- iOS `AppModel` owns exactly one active `DeviceTransport` and `DeviceSession`.
- macOS `MacAppModel` owns exactly one active `DeviceTransport` and `DeviceSession`.
- Only the owning app model calls `connect()`.
- Switching device or route invalidates the broker context, retires the old generation, begins disconnect, creates the replacement transport, attaches the replacement session, and quarantines callbacks from the retired generation.
- `ConnectionCatalog`, discovery, widgets, App Intents, notification actions, and galleries cannot construct BLETransport or call `connect()`.
- Notification actions and App Intents use the exact app-owned `DeviceOperationBroker` instance registered by the app process.

## 6. Device Identity, Discovery, and Switching

### 6.1 Physical identity

Identity correlation is MAC-first. MAC values are normalized across case and separator formats. CID is used only when MAC cannot be compared; different valid MAC values remain distinct even if CID matches. Demo is synthetic and is never merged with real hardware.

A physical record may expose multiple routes while retaining one identity and last-known state. Bluetooth is the preferred route whenever it is currently available. An Advanced route menu permits explicit router selection.

The iOS dashboard navigation bar and macOS popover/window show an active-device picker when more than one physical record is saved. The full Devices surface remains the place to add, remove, discover, and edit routes.

### 6.2 Candidate sources

The Devices surface combines:

- filtered Bluetooth scan results from the app-owned BLE transport;
- `_wattline._tcp` records from an injected `NWBrowser` adapter; and
- saved manual LAN/VPN/WAN router hosts.

Router TXT data supplies normalized device ID, authority, port, and certificate fingerprint. Discovery is read-only and never initiates connection. It starts when the Devices/Scan surface becomes active and stops when the surface leaves the view tree.

Loss of an mDNS advertisement removes only that ephemeral route. It does not delete a saved device, manual host, token, or last-known snapshot.

### 6.3 Security and persistence

- Router bearer tokens remain only in Keychain.
- RouterHostStore persists non-secret route metadata.
- HTTPS command and SSE traffic use the same pinned session policy.
- A discovered HTTPS fingerprint must match the saved/pairing record.
- Plain HTTP WAN requires the existing explicit insecure-WAN confirmation and warning.
- Manual VPN/Tailscale entry remains first-class because mDNS is not assumed to cross a VPN.

### 6.4 Selection behavior

- Tapping a physical row uses Bluetooth when available.
- A router-only saved device can connect through its selected saved route.
- The Advanced menu may force Router even when Bluetooth is present.
- Relaunch reconnects only the last active physical device and route, not every saved device.
- Relaunch reconnects that record only when its persisted auto-reconnect preference is enabled. Auto-reconnect settings on inactive records take effect if that record later becomes active; they never create concurrent sessions.
- Switching does not optimistically retain the old device as live. The old scope is retired before replacement state can become authoritative.
- A failed switch returns to Devices with a clear error and no silent failover.
- Removing a device deletes its saved app identity and route references. Removing a router route also deletes its Keychain token. Neither action sends a destructive station command.

## 7. macOS App

### 7.1 Target and lifecycle

Add a macOS 14+ app target with bundle ID `com.keithah.wattline.mac`, app-group entitlement `group.com.keithah.wattline`, and a macOS test target. It owns one transport/session and supports Demo, Bluetooth, and Router routes.

The app starts as an LSUIElement-style accessory with a `MenuBarExtra`. “Show in Dock” is off by default and uses an injected activation-policy adapter. Launch at Login uses an injected SMAppService adapter; registration failures remain visible in Settings.

### 7.2 Menu title and popover

The title is monochrome and monospaced:

- `⚡︎ 84%` while charging;
- `84%` while discharging or idle; and
- a neutral device/bolt glyph when level is unavailable.

A density preference may suppress the percentage while the device is idle; charging/discharging presentation always follows the same semantic state and never changes the one-owner model.

The popover reuses compact WattlineUI battery and port views. It shows authoritative freshness, pending mutation state, route badge, active device switcher, persistent DEMO badge, and “Connect a real device.” DC and USB-C toggles use the same commands, operation broker, and telemetry reconciliation as iOS. An `os_signpost` interval measures user action to authoritative confirmation.

### 7.3 Optional main window

“Open Wattline” opens a `NavigationSplitView` with Home, Devices, Shortcuts, and Settings. It has no Timers destination. Closing the window leaves the menu-bar app running.

Devices exposes saved-device switching, Bluetooth/LAN discovery, and manual router setup. Settings exposes device identity, clock sync, DC/bypass, restart/shutdown, macOS app preferences, and the capability/route-gated Expert disclosure.

### 7.4 Widget

The existing multi-platform WidgetKit extension is explicitly embedded in the macOS app and uses bundle ID `com.keithah.wattline.mac.widgets` on macOS. Small and medium families read the same app-group snapshot and deep-link to the macOS main window. The extension remains read-only and transport-free.

### 7.5 Demo

Demo Mode navigates every macOS P1 surface, drives compact telemetry and confirmed controls, writes only the Demo-scoped snapshot behavior already approved, shows DEMO persistently, and exits through the same single-owner transition used for a real route.

## 8. App Intents and Shortcuts Galleries

### 8.1 Production dependency resolution

iOS 17 system-instantiated intents resolve a launch-time shared accessor holding the exact `DeviceOperationBroker` owned by `WattlineApp`/`AppModel`. The accessor is a reference registry and cannot construct a broker, transport, session, or reconnect owner. Foreground-continuable and background intent paths resolve the same object identity.

Intent entities come from the saved-device catalog and include only eligible devices. If the parameter is omitted, the active device is selected. A live operation uses the existing generation-tokened `withConnection(to:timeout:operation:)` path with a ten-second bound.

### 8.2 Toggle DC Port

Accept on, off, or toggle. Toggle derives its target from authoritative DC telemetry. Require DC output control. Perform `.setDC` and return success only after authoritative telemetry confirms the target.

### 8.3 Get Battery Level

Require battery capacity. Return percentage, status, direction-aware runtime, freshness, and wall-clock age. If reconnect fails, the last valid app-group snapshot may be returned with `isStale = true`. With no valid snapshot, fail clearly. This is the only intent allowed to return stale data.

### 8.4 Set USB-C Limit

Support Global, Input, and Output and exactly 30/45/60/65/100/140 W. Require USB power-limit capability. Perform SET followed by GET and speak/return only the confirmed device value.

### 8.5 Capability and route behavior

The iOS and macOS galleries reuse one composition model. Once authoritative capabilities are known, unsupported cards are structurally absent. Before any known device exists, the gallery shows the explanatory empty state. Direct Shortcuts invocation repeats capability validation and returns an explicit unsupported-device error. Demo results are labeled simulated.

Router-backed intent operations use the app's current active session and broker. They do not create a separate HTTP shortcut path.

## 9. Expert Controls

Expert Settings is behind a disclosure and an “I understand” interstitial. It is structurally present only for a connected application-mode Bluetooth route.

### 9.1 BLE PIN

- Accept two matching decimal values from 0 through 999999.
- Encode the PIN as u32 little-endian in the documented BLE_PIN SET command.
- Require the encrypted/bonded GATT path expected by the protocol. An insufficient-encryption failure invokes the existing OS-pairing explainer and retry path; Wattline never captures the pairing PIN.
- Do not read, delete, log, persist, or redisplay the PIN.
- State plainly that the PIN cannot be read or deleted over BLE and loss may require physical reset.
- Validation failure produces no write.

### 9.2 Factory mode

- Send the documented RUNNING_MODE SET command.
- Read and validate the device reply; do not copy the OEM PWA's fire-and-forget behavior.
- Render only confirmed operation outcome.

### 9.3 Unsupported routes

Router and Demo routes omit Expert controls because no documented endpoint supports them. A future endpoint requires a separate protocol-backed design; this implementation does not guess.

## 10. Failure and Concurrency Behavior

- Telemetry or confirmed readback remains authoritative for every mutation.
- Connection and operation callbacks carry generation/scope identity; stale callbacks cannot update a replacement device.
- Discovery errors affect discovery presentation only and cannot tear down an active session.
- Route connection failure remains visible and does not trigger silent failover.
- Intent mutation failures never report stale success.
- Keychain denial, missing credentials, TLS mismatch, local-network denial, launch-at-login failure, and unsupported capability each map to distinct user-facing outcomes.
- Expected-disconnect commands preserve the reviewed restart/shutdown semantics, including write-error-while-disconnecting behavior.
- Expert acknowledgement alone never changes telemetry presentation.
- Continuations and timeout registry entries resume/remove exactly once under cancellation, detach, replacement, or timeout.

## 11. Testing Strategy

### 11.1 Baseline health gate

Before new production features:

- Execute all current Wattline app tests and make them green.
- Replace relative working-directory assumptions with paths derived from `#filePath`.
- Remove duplicate nominal production/test types or qualify production types so tests exercise the intended implementation.
- Establish scoped connections in mutation/lifecycle fixtures before broker-routed commands.
- Replace fixed `Task.yield` counts and unbounded waits with condition-based bounded waits.
- Preserve non-vacuous restart, bypass, pending-mutation, Live Activity, and router-owner assertions.

### 11.2 Milestone tests

- ConnectionCatalog: MAC normalization, MAC-first/CID-second correlation, distinct-device separation, route preference, discovery loss, persistence, and switching generation quarantine.
- Saved selection: per-device auto-reconnect persistence, inactive-device non-connection, dashboard/popover picker composition, and one-active-session enforcement.
- Discovery: TXT parsing, start/stop lifecycle, deduplication, permission/error mapping, and zero connection side effects through injected sources.
- macOS: one owner, Demo/BT/Router transitions, menu title, pending/confirmed controls, accessory default, Dock preference, login errors, optional window navigation, no Timers, and widget embedding.
- App Intents: production broker object identity, eligible entities, active-device default, ten-second reconnect, DC telemetry confirmation, battery stale fallback, limit SET-then-GET, capability absence, and Demo labeling.
- Expert: range/matching validation, exact PIN bytes, no persistence/logging, reply-validated factory mode, and structural absence for Router/Demo/unsupported mode.
- Configuration: iOS 17, macOS 14, bundle IDs, app group, entitlements, LSUIElement behavior, ActivityKit/WidgetKit keys, extension dependencies, and target membership.

### 11.3 Full deterministic verification

- Fresh WattlineCore, WattlineUI, and WattlineNetwork package suites.
- Full iOS app, widget, and UI-test execution on an installed iOS 17+ simulator.
- Full macOS app, test, and widget execution/build on macOS 14+.
- Generic iOS Simulator and generic macOS builds from fresh DerivedData.
- Demo journeys on iOS and macOS covering device switching, menu/popover controls, galleries, Settings, and exit to real-device selection.
- Source audits proving Core/UI platform and networking purity, WattlineNetwork confinement, widget transport absence, no OTA/CDN additions, no Timers, and one transport owner per app process.
- `git diff --check` and an unchanged OEM/API reference audit.

## 12. External Evidence

The following require signed OS integration or real hardware and are reported separately from deterministic CI:

- Bluetooth/router identity correlation and route switching against one physical station.
- macOS popover command-to-confirmation latency below 1.5 seconds.
- signed Launch at Login behavior.
- Shortcuts app and Siri invocation.
- BLE PIN and factory-mode behavior on recoverable hardware.
- long-duration Live Activity/background BLE behavior.

Unavailable external evidence does not become a simulated pass. The handoff includes exact reproduction steps and identifies the missing environment.

## 13. Completion Criteria

The non-OTA roadmap is complete when:

- milestones 1–6 are reviewed and merged;
- deterministic suites/builds/audits are green;
- iOS and macOS Demo Mode cover every implemented P1 surface;
- one active device/session and telemetry-is-truth invariants hold across Demo, Bluetooth, and Router routes;
- App Intents and Expert controls obey capability/route gating; and
- every external-only criterion has either recorded evidence or an explicit unverified classification.

No OTA code, firmware-network access, timer UI/codec, simultaneous multi-device monitoring, or automatic transport failover is introduced by this program.
