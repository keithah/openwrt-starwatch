# Wattline Phase 1 Design

## Scope

Build an iOS 17+ native SwiftUI MVP implementing F1–F8 from `Wattline-SPEC.md`: onboarding and permission priming, scan/pair/automatic reconnect, live dashboard telemetry, DC control, USB-C output control, USB-C power limits, capability gating, and Demo Mode.

Phase 2 and Phase 3 product behavior remains out of scope. The Timers, Shortcuts, and Settings tabs are navigable placeholders, but timer CRUD, App Intents, device settings, OTA, widgets, Live Activities, networking, and macOS targets are not implemented.

The specification's cross-phase requirements are resolved as follows:

- `DemoTransport` fully drives every Phase 1 screen and control. Placeholder tabs retain the persistent DEMO badge but do not simulate excluded Phase 2/3 behavior.
- Every quirk in spec §5.7 receives a focused `WattlineCore` regression test. Quirks belonging to later product phases are represented as protocol/transaction policies without shipping their later-phase UI or workflows.
- Wattline contains no networking code or networking entitlements.
- The real-hardware 48-hour soak and reconnect p95 measurement remain hardware exit checks; this environment verifies their supporting state machines, replay cases, simulator behavior, and buildability.

## Project Shape

The repository contains three top-level deliverables:

```text
apple/
├── WattlineCore/        Swift package: protocol, state, BLE, demo, replay, tests
├── WattlineUI/          Swift package: reusable SwiftUI components and theme
└── Wattline/            Xcode iOS app project and application target
```

Both packages are local Swift packages with iOS 17 and macOS 14 platform declarations so their APIs remain reusable for the planned macOS target. `WattlineCore` imports Foundation and CoreBluetooth but never UIKit or SwiftUI. `WattlineUI` depends on `WattlineCore` for display models and imports SwiftUI. The iOS target depends on both packages and owns lifecycle, navigation, persistence, permission presentation, and app-specific view models.

No third-party dependency or project-generation tool is introduced.

## WattlineCore Architecture

### Transport Boundary

`DeviceTransport` is the only interface consumed by app state. It exposes asynchronous connection operations, discovery results, commands, telemetry reads, and a single `AsyncStream<DeviceEvent>` for connection, scan, telemetry, and transaction-state events.

Implementations:

- `BLETransport`: a CoreBluetooth-backed transport. A per-device actor serializes command-characteristic operations as write-with-response followed by a read of `0x4302`. Only one command transaction can be active, and pending depth is emitted for UI spinners.
- `DemoTransport`: deterministic LP2_V5 simulation seeded for screenshots and tests. It emits the normal handshake and approximately one-hertz telemetry, models discharge/charge behavior, supports the P0 port and power-limit commands, and reproduces the Type-C `mode` reconciliation quirk.
- `ReplayTransport`: consumes canned events, replies, telemetry frames, write failures, and disconnects. Tests use it to exercise logic without CoreBluetooth or hardware.

Expected-disconnect operations are modeled as transport policies for RESTART, PK, and FM. A disconnect while one of these writes is pending completes the operation successfully. FM also disarms automatic reconnect; RESTART and PK select their later expected flows. Phase 1 exposes none of these commands in the UI.

### Codec and Models

Pure value types decode and encode:

- Standard command requests and replies, including echo and action-echo validation.
- FEATURES, DEVICE_ID, power-limit, port-control, bypass, and running-mode commands.
- BLE IEEE-11073 SFLOAT, including signed mantissa/exponent and NaN/positive-infinity/negative-infinity encodings.
- `ExtBatteryInfo`, `DcPortStatus`, and `TypeCPortStatus` from documented offsets.
- OTA INFO only to distinguish normal and OTA advertisements during the connection handshake; there is no OTA update engine.

Telemetry parsers require only the documented prefix needed for fields they expose and ignore trailing bytes. Optional later-firmware fields are decoded only when their offsets exist. DEVICE_ID reverses its six payload bytes before formatting the MAC address.

### Device Session

`DeviceSession` owns the handshake and the UI-facing `DeviceState`:

1. Connect and allow the firmware's two-second settle interval.
2. Discover `0x5301`, `0x180A`, and `0x1805` plus their characteristics.
3. Read OTA INFO to distinguish app mode from bootloader mode and obtain CID when present.
4. Read Device Information strings.
5. Query FEATURES.
6. Resolve capabilities and read/subscribe only to supported telemetry.
7. Write Current Time.
8. Query DEVICE_ID for persisted identity.
9. Read USB-C power-limit types 1–4 when supported.

The session exposes loading, live, stale, disconnected, and reconnecting states. Telemetry becomes stale after ten seconds without an update. Control mutations remain pending until authoritative telemetry or command readback confirms them. DC and Type-C control use three-second reconciliation windows; bypass policy uses ten seconds.

Automatic reconnect retrieves the saved CoreBluetooth peripheral identifier and issues a pending connect immediately. CoreBluetooth state restoration and `bluetooth-central` background mode support reconnect through suspension and relaunch. Scan matching uses advertisement `localName`, never `CBPeripheral.name`.

### Capability Resolution

`CapabilityResolver` applies exactly this precedence:

1. FEATURES when present.
2. CID model byte (`0x01` LP1, `0x02` LPP, `0x03` LP2).
3. Legacy model string (`BP4SL3V1`, `PK-LINK-POWER-1`, `BP4SL3V2`, `BP4SL3`).

An authoritative FEATURES bitmask can remove capabilities even when CID or model implies them. Unknown variants retain their raw identity and remain usable when FEATURES is available. Gates produce concrete presentation capabilities so unsupported controls are never constructed in the SwiftUI view tree.

## P0 Control Reconciliation

DC control sends `[0x01, 0x01, op]`, validates `01 81 00`, then waits for `DcPortStatus.enabled`. Timeout returns the switch to telemetry truth and emits a user-facing error.

USB-C output sends `[0x13, 0x01, 0x02, op]`, validates `13 81 00`, then confirms against `TypeCPortStatus.mode`: output is on for mode 2 or 3 and off for mode 0 or 1. The `enabled` byte is never used for this decision.

Power-limit GET maps types 1–4 and levels 0–5 to 30, 45, 60, 65, 100, and 140 watts. SET sends `[0x02, 0x01, type, level]`; clear sends `[0x02, 0x02, type]`. Both operations re-GET the type and display the returned value. Result `0xFF` is accepted only for runtime type 4 and renders an em dash; it is an error for types 1–3.

DC bypass protocol policy ignores result byte `0xFF` or `0xFD` only for opcode `0x14`, then waits for `DcPortStatus.bypassOn`. Running-mode policy requires and validates `e0 81 00`.

## WattlineUI Design

The UI package contains small, previewable components:

- `BatteryHero` with segmented-meter and instrument-gauge variants.
- `DCPortHero` for devices without battery capacity.
- `PortCard` with inline pending state and telemetry.
- `StatTile` with monospaced numerals.
- `LimitSlider` with exactly six detents.
- `DemoBadge` and the shared dark theme.

The theme uses system SF typography, `.monospacedDigit()` for numeric presentation, indigo accent, green charging semantics, orange discharging semantics, neutral idle styling, and dimmed stale data. This uses the system fonts available without bundling or downloading assets.

Components accept immutable display data and callbacks. They do not import CoreBluetooth, own transport state, or decide capability visibility.

## iOS Application Flow

First launch presents the three value propositions and Bluetooth priming copy before any central manager is created. “Connect a device” creates the BLE transport and advances to scanning. “Try Demo Mode” creates `DemoTransport` without requesting Bluetooth permission. Denied or restricted Bluetooth displays an explanation, an `UIApplication.openSettingsURLString` action, and Demo Mode entry.

Scanning filters for service `0x5301` and accepts fresh local names beginning with `Link-Power` or `PeakDo-OTA`. Rows show advertisement name, known cached identity or “New device,” known MAC when available, and four-step RSSI strength. Known devices sort first. OTA-mode devices are clearly labeled and do not enter the dashboard; because OTA is excluded, they show recovery guidance rather than an update flow.

After connection, the app uses a four-tab `TabView`: Home, Timers, Shortcuts, and Settings. Home contains the capability-gated dashboard and limits navigation. Other tabs are Phase 1 placeholders. In Demo Mode every tab and pushed screen carries a persistent DEMO badge, and Settings provides “Connect a real device.”

The dashboard conditionally constructs its hero, stat row, DC card, USB-C card, and limits navigation from resolved capabilities. Meter/gauge choice persists in `AppStorage`. Pull-to-refresh requests current supported telemetry. Pending controls render spinners, errors render transient toasts, and stale/disconnected states retain dimmed last-known values with reconnect context.

## Persistence

UserDefaults stores onboarding completion, battery-hero style, last device peripheral UUID, auto-reconnect preference, and cached identity fields. Codable last-known telemetry and timestamp support stale rendering. No value is written to iCloud or sent over a network.

## Test Strategy

`WattlineCore` follows strict red-green-refactor cycles. Initial tests use exact vectors from `API.md`, including:

- SFLOAT bytes `d0 e7` decode to 20.00 V and all three special encodings.
- FEATURES reply `fe 80 00 ff 7f 00 00` decodes to `0x00007FFF`.
- Live-format 11-byte DC and 13-byte Type-C telemetry decodes documented offsets and ignores trailers.
- DEVICE_ID payload `2b 72 eb 5a 04 dc` formats as `DC:04:5A:EB:72:2B`.
- Reply echo and action-echo mismatches fail.

Dedicated regression tests cover every §5.7 quirk:

1. Bypass accepts nonstandard result codes and reconciles only from telemetry.
2. Power-limit clear encodes opcode `0x02`, never `0x06`, and performs a GET.
3. RESTART, PK, and FM disconnects complete as success with correct reconnect policy.
4. Type-C output confirmation reads `mode`, not `enabled`.
5. Running-mode control waits for and validates its reply.
6. Discovery accepts or rejects using fresh advertisement local name even when cached peripheral name conflicts.
7. Runtime limit alone accepts unset result `0xFF`.
8. The macOS OTA bonding trap is represented as an OTA-mode classification/recovery-policy test; no macOS OTA UI or update workflow ships in Phase 1.

Capability tests exercise each bit in the §5.6 matrix, authoritative-bit removal, CID fallback, model-string fallback, and unknown variants. App/UI tests assert absence—not disabled state—for unsupported battery, USB-C, limits, and control elements.

Replay tests cover command serialization, timeouts, stale transitions, reconnect state, and authoritative mutation confirmation. Demo tests use a fixed seed and assert plausible telemetry plus working P0 controls.

## Verification

Each core stage runs `swift test` before the next begins. Final local acceptance requires:

- `swift test` succeeds in both packages.
- The iOS app builds for an available iOS simulator with `xcodebuild`.
- The app launches in the simulator without Bluetooth permission and reaches Demo Mode.
- Dashboard, both toggles, both battery visualizations, limits set/reset, placeholder tabs, persistent DEMO badges, and “Connect a real device” are exercised.
- A source and entitlement scan finds no URLSession, Network framework, web view, network permission, CDN URL, or third-party networking dependency.

The 48-hour LP2_V5 soak and reconnect ≤10 s p95 require physical hardware and are explicitly reported as unverified environmental exit criteria rather than inferred from simulator results.
