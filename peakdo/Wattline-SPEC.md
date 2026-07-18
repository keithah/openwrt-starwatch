# Wattline — Product & Technical Specification

| | |
|---|---|
| **Product** | Wattline — native, unofficial companion app for PeakDo Link-Power portable power stations (LP1, LP2, LP+) |
| **Platforms** | iOS 17+ · macOS 14+ (menu-bar app + Notification Center widget), single SwiftUI codebase |
| **Status** | Draft v1.0 — 2026-07-14 |
| **Sources** | `Wattline-design.html` (approved visual design, screen inventory §4) · `API.md` (reverse-engineered BLE protocol, live-verified 2026-07-14 against LP2_V5 / fw 1.4.9 / OTA 2.0.2) |

> **Grounding rule used throughout:** every telemetry number, command, and byte layout in this spec cites an `API.md` section. Every screen, state, and visual decision derives from the approved design. Where the design implies a decision but leaves detail open, the spec says **Assumption:** explicitly.

---

## 1. Overview & goals

### 1.1 Product summary

Wattline is a native iOS + macOS companion app for the PeakDo Link-Power family of portable DC power stations. It talks **directly to the device over Bluetooth LE (GATT)** — no cloud, no account, no analytics, no server. The only network call the app can ever make is a **read-only firmware-update check** against PeakDo's public CDN (`api.peakdo.ca/fw-api`, API.md §10), and only from the Firmware Update screen.

The official control surface today is a PWA (`pwa.peakdo.ca`) that iOS users must run inside the **Bluefy** Web-Bluetooth browser. Wattline replaces that with a real app: instant reconnect, lock-screen Live Activities, Home Screen widgets, a macOS menu-bar readout, and Siri/Shortcuts automation — all things a PWA in a wrapper browser structurally cannot do.

### 1.2 Goals

1. **Glanceable power state everywhere.** Battery %, charge/discharge state, and runtime visible on the lock screen (Live Activity), Home Screen (widgets), and macOS menu bar without opening the app.
2. **Full device control, native.** Everything the OEM PWA can do — port toggles, USB-C power limits, schedules, settings, OTA — with correct handling of the firmware quirks the PWA gets wrong (see §5.7).
3. **Private by construction.** Zero telemetry leaves the phone. This is a first-class product principle, stated in onboarding and in App Store copy, and enforced by architecture (§9).
4. **Automatable.** App Intents expose device control to Shortcuts, Siri, and (on macOS) the Shortcuts menu bar.
5. **Safe.** OTA updates that cannot brick the device through app error; destructive actions gated behind confirmation.

### 1.3 Non-goals

- **No cloud features**: no remote (out-of-BLE-range) control, no fleet management, no history sync between devices. Historical charting beyond the current session is out of scope for v1 (candidate for v1.x, stored locally only).
- **No support for non-Link-Power PeakDo products** (displays, cables). Only devices advertising the `0x5301` service with a `Link-Power` name prefix (API.md §1).
- **No firmware authoring/downgrade tools.** Wattline installs only firmware the CDN offers for the device's exact CID, after pack CRC validation (API.md §11). No downgrade UI in v1 (open question §11.1).
- **No Android / watchOS** in this spec's horizon (watchOS is a v1.x candidate, §12).
- **Not a replacement for the physical UI** — device power-on always requires the hardware button (shutdown is one-way over BLE, API.md §3.5).

### 1.4 Target users

| Persona | Situation | What Wattline gives them |
|---|---|---|
| **Off-grid / vanlife** | Link-Power feeding a 12 V fridge or router bank; battery anxiety is constant | Lock-screen Live Activity with % + runtime; low-battery notification; schedules to cut loads overnight |
| **Photographers / videographers** | Powering cameras, monitors, laptops via USB-C PD in the field | Fast reconnect on set, USB-C power-limit control (protect small sources / prioritize charge speed), menu-bar % while tethered to a MacBook |
| **Starlink users** | Link-Power as DC UPS for a Starlink dish | DC Bypass control, DC port scheduling, glanceable runtime-remaining during outages |
| **Tinkerers** | Bought a DC-only LP+ or a new hardware rev the PWA doesn't know | Capability-gated UI that adapts to the FEATURES bitmask instead of a hard-coded model list (API.md §3.4-FEATURES, §7) |

### 1.5 Competitive framing vs. the OEM PWA (via Bluefy)

| | OEM PWA in Bluefy | Wattline |
|---|---|---|
| Install | Open browser app → bookmark → grant Web-Bluetooth each session | App Store, native permission prompt once |
| Reconnect | Manual chooser dialog every session | Automatic: pending `connect()` on the stored peripheral identifier (§5.5) |
| Glanceability | None — must open Bluefy | Live Activity, widgets, menu bar |
| Automation | None | App Intents / Siri Shortcuts (§6.3) |
| Background | None (tab must be foreground) | `bluetooth-central` background mode on iOS; persistent agent on macOS |
| Correctness | Ships known bugs: power-limit *clear* silently no-ops (wrong opcode); ignores DC-bypass result codes and shows optimistic state (API.md §3.4) | Sends the correct clear frame `[0x02,0x02,type]`; reconciles bypass state from `DcPortStatus` telemetry (§5.7) |
| New hardware | Hard-coded variant table stops at LP2_V4; LP2_V5 exists in the wild (API.md §7) | Capability detection from CID *and* FEATURES bitmask; unknown CIDs degrade gracefully (§5.6) |
| Privacy | Web app; browser can see everything | No network stack in the control path at all |

### 1.6 Product principles

1. **Local-first, local-only.** If a feature requires a server, it doesn't ship (firmware check CDN excepted, and it is user-initiated, §9).
2. **Never show a control the device doesn't have.** All controls gate on the FEATURES bitmask, falling back to CID inference (§5.6).
3. **Telemetry is truth.** After any write, the UI reconciles against the device's own notified state, never against optimistic local state alone (the PWA's bypass bug is the cautionary tale, §5.7).
4. **Instrument-grade presentation.** Dark UI, SF Pro for UI text, IBM Plex Mono for all numerals, indigo brand accent. **Green = charging, orange = discharging** — consistently, on every surface: dashboard, widgets, Live Activity, menu bar, macOS popover.
5. **Safety over convenience** for anything that can strand the user (OTA, shutdown, restart).

---

## 2. Feature list & priorities

Priorities: **P0** = MVP, app is pointless without it · **P1** = v1.0 App Store release · **P2** = v1.x.

| # | Feature | Priority | Design ref | API ref |
|---|---|---|---|---|
| F1 | Onboarding + BLE permission priming + Demo Mode entry | P0 | Screen 1 | — |
| F2 | Scan, pair, auto-reconnect | P0 | Screen 2 | §1, §8, §12 |
| F3 | Dashboard: battery hero + live telemetry | P0 | Screen 3 | §4.1–4.3 |
| F4 | DC port toggle | P0 | Screen 3 | §3.4 DC_CONTROL |
| F5 | USB-C output toggle | P0 | Screen 3 | §3.4 TYPEC_CONTROL |
| F6 | USB-C power limits (global/input/output + runtime readout) | P0 | Screen 4 | §3.4 TYPEC_POWER_LIMIT |
| F7 | Capability gating (FEATURES / CID) | P0 | all | §3.4 FEATURES, §7 |
| F8 | Demo Mode simulation | P0 | Screens 1–4 | §10 (this doc) |
| F9 | System & device settings (info, clock sync, DC bypass, restart, shutdown) | P1 | Screen 6 | §3.4, §3.5, §5 |
| F10 | Schedules (up to 6 on-device timers) | P1 | Screen 5 | §3.4 SCHEDULED_ON_OFF |
| F11 | Live Activities (charging + discharging) | P1 | Screen 9 | §4.1 |
| F12 | Home Screen widgets (small + medium) | P1 | Screen 9 | §4.1 |
| F13 | macOS menu-bar app + popover | P1 | Screen 10 | §4.1–4.3 |
| F14 | macOS Notification Center widget | P1 | Screen 10 | §4.1 |
| F15 | App Intents / Siri Shortcuts gallery | P1 | Screen 8 | §3.4 |
| F16 | Low-battery notification + automation hook | P1 | Screen 8 | §4.1 |
| F17 | Firmware update (OTA) | P2 | Screen 7 | §9, §10, §11 |
| F18 | Expert tier: BLE PIN, factory mode | P2 | Screen 6 | §3.4 BLE_PIN, RUNNING_MODE |
| F19 | Multiple saved devices, device switcher | P2 | Screen 2 | §12 |

### Acceptance criteria (per feature)

**F1 — Onboarding**
- First launch shows value props (glanceable, private, automatable) before any permission prompt; Bluetooth permission is requested only after the user taps the primed CTA (never on cold launch).
- "Try Demo Mode" is available on the same screen and requires no permission.
- Denying Bluetooth lands on an explainer with a deep link to Settings, plus the Demo Mode entry — never a dead end.

**F2 — Scan & pair**
- Scanning filters on service `0x5301` + name prefixes `Link-Power` / `PeakDo-OTA` (API.md §1); matching uses the **advertisement's fresh `local_name`**, never `CBPeripheral.name` (stale-cache trap, API.md §12).
- Each row shows model, identity line, and signal strength (RSSI bars). A previously connected device row shows its stored MAC (from `DEVICE_ID`, §5.3); a never-connected device shows "New device" (OS hides MAC pre-connect — Assumption, §11.2).
- After one successful connection, relaunching the app within range reconnects with **no user interaction** in ≤ 10 s (pending-connect on stored identifier).
- A device found in OTA mode (`PeakDo-OTA`) is labeled "In firmware-update mode" and routes to the OTA recovery flow (§8.1), not the dashboard.

**F3 — Dashboard**
- Battery %, capacity Wh, runtime, and voltage update live from `ExtBatteryInfo` notifications with no user action; a value older than 10 s renders in the dimmed "stale" style.
- Hero meter color: green when `status == 1`, orange when `status == -1`, neutral when `0` (API.md §4, signed `int8`).
- Segmented meter is default; instrument-gauge alternative is a persisted per-app preference.
- On an LP+ (no `FF_BATTERY_CAPACITY`), the battery hero is replaced by the DC-port hero; no battery or USB-C UI is present (§5.6).

**F4 — DC port toggle**
- Toggling writes `[0x01, 0x01, op]`, expects reply `01 81 00`, then confirms against the next `DcPortStatus.enabled` notification (arrives ≤ ~1 s live-verified); the switch shows a spinner until confirmed and reverts with an error toast on timeout (3 s).

**F5 — USB-C output toggle**
- Toggling writes `[0x13, 0x01, 0x02, op]`. Confirmation reads **`TypeCPortStatus.mode`** (3→1 off, 1→3 on) — **not** the `enabled` byte, which stays 1 throughout (live-verified quirk, API.md §3.4).

**F6 — USB-C power limits**
- Sliders detent at exactly 30/45/60/65/100/140 W = levels 0–5; Global/Input/Output map to types 1/2/3; Runtime (type 4) is read-only (API.md §3.4).
- Setting writes `[0x02, 0x01, type, level]`; the app re-`GET`s the type after the ack and renders what the device reports.
- "Reset to default" sends `[0x02, 0x02, type]` (the *correct* clear frame — never the PWA's buggy `0x06` opcode) and the UI then shows the device's reported post-reset value (65 W observed on LP2; the app displays whatever `GET` returns, not a hard-coded 65).
- Runtime tile shows "—" when `GET` type 4 returns `RESULT 0xFF` (no PD sink attached).
- Values survive device restart (on-device persistence — live-verified) and the UI re-reads them on every reconnect.

**F7 — Capability gating**
- With FEATURES = `0x00007FFF`, all controls appear. With `FF_USB_PORT` cleared, no USB-C card, no limits screen, no USB-C intents. With `FF_BATTERY_CAPACITY` cleared, no battery hero/widgets/Live Activity. Automated tests cover each bit's UI effect (§5.6 matrix).
- If the FEATURES query fails, gating falls back to CID model nibble (LP1/LP2 → battery + USB-C; LPP → DC-only), matching PWA handshake behavior (API.md §8).

**F8 — Demo Mode** — see §10 for the full simulation contract; acceptance: every P0/P1 screen is fully navigable in Demo Mode with plausible data and functioning (simulated) controls, and every demo surface carries a persistent "DEMO" badge.

**F9 — Settings**
- Shows model, hardware rev/variant, app firmware, OTA bootloader version straight from Device Information strings (API.md §2.2).
- Clock sync writes the 10-byte Current Time value (API.md §5) automatically on every connect and manually via "Sync now"; UI shows device-time-vs-phone-time drift when known.
- Restart: confirmation sheet → write `[0x11, 0x01]` → **treat the write-error/disconnect as success** (API.md §3.4) → show "Restarting…" and auto-reconnect (device re-advertises in ~15 s).
- Shut down: destructive confirmation explicitly stating "You must press the button on the device to turn it back on" → write `"FM"` to `0x4310` → disconnect-as-success → return to scan screen (API.md §3.5).
- DC Bypass toggle follows the reconciliation rule in §5.7 (never trusts the result byte).

**F10 — Schedules**
- Timer list loads via list-IDs then per-ID get (API.md §3.4 SCHEDULED_ON_OFF); UI caps at **6 timers** (design constraint; protocol max unknown — Assumption §11.2).
- Create/edit composes the 9-byte `TIMER_SETTINGS` struct exactly (one-shot y/m/d; daily; weekly bitmask Mon=bit1…Sun=bit7; monthly bitmask day1=bit1…day31=bit31; action on/off).
- Enable/disable rewrites the timer with `status` 1 / −1; statuses −2/−3 render as "Disabled (invalid)" / "Expired".
- Add uses `id 0xFF` and adopts the device-assigned id from the reply (byte 3).
- After any mutation the app re-lists and re-gets to render device truth.

**F11–F14, F15–F16** — see §6 and §7 for full criteria.

**F17 — OTA** — see §8; headline criterion: *no code path can send `END` (`0x83`) after programming unless `WHOLE_VERIFY` (or full per-chunk `VERIFY`) succeeded*, and a cancelled/failed session always leaves the device in the (recoverable) bootloader or exits it cleanly via bare `[0x83]`.

**F18 — Expert tier**
- Hidden behind a disclosure in Settings with an "I understand" interstitial.
- BLE PIN: two matching entries of 0–999999, sent as u32 LE `[0x04, 0x01, pin32]`; UI states plainly that the PIN **cannot be read back or deleted** over BLE (`GET`/`DEL` → `0xFC`, live-verified) and Wattline does not store it.
- Factory mode: writes `[0xE0, 0x01, mode]` and **does** read the reply (`e0 81 00` — the device replies, contra the PWA's fire-and-forget; API.md §3.4).

---

## 3. Information architecture & navigation

```
Cold start ──► Onboarding (first run only) ──► Scan & Pair ──► Dashboard
                     │                             │
                     └──► Demo Mode ───────────────┴──► (same UI, simulated transport)

iOS tab bar (design: Home / Timers / Shortcuts / Settings)
├── Home (Dashboard)
│    ├── Battery hero (meter ⇄ gauge preference)
│    ├── DC Port card ──► (toggle inline)
│    └── Type-C Port card ──► USB-C Power Limits screen
├── Timers ──► Timer editor (sheet): type, time, repeat, action
├── Shortcuts (App Intents gallery) ──► Shortcuts app deep links
└── Settings
     ├── Device info (model / variant / firmware)
     ├── Clock sync
     ├── DC Port + DC Bypass toggles
     ├── Firmware Update ──► OTA flow (full-screen modal, uncancellable past ERASE)
     ├── Restart · Shut Down (confirmation sheets)
     └── Expert ▸ (BLE PIN, Factory mode)

Disconnected overlay (any tab) ──► reconnecting state ──► Scan & Pair (on give-up)

macOS
├── Menu-bar item (% + bolt) ──► Popover (hero + quick toggles + runtime)
│                                   └── "Open Wattline" ──► main window (same tab content as iOS, sidebar layout)
└── Notification Center widget (small/medium, same WidgetKit widgets as iOS)
```

Navigation rules:
- Tabs persist per-device state; switching tabs never drops the BLE connection.
- The OTA modal blocks all navigation while a session is active (§8).
- Deep links: `wattline://device/<id>` (widgets/Live Activity tap-through), `wattline://limits`, `wattline://timers`.

---

## 4. Screen-by-screen specification

Common state machine for every connected screen: `loading → live → stale (no notification >10 s) → disconnected (link drop) → reconnecting`. Demo Mode replays the same states from the simulated transport. Numbers set in IBM Plex Mono; green/orange semantics per §1.6.

### 4.1 Onboarding + BLE permission (Screen 1)

- **Purpose:** communicate value + privacy posture; prime the single Bluetooth permission; offer Demo Mode.
- **Content:** 3 value-prop panes (Glanceable · Private — "your power data never leaves this device" · Automatable), then a priming pane explaining *why* Bluetooth is needed before triggering the system prompt.
- **States:** first-run · permission-denied (explainer + Settings deep link + Demo entry) · returning user (skipped entirely).
- **Interactions:** "Connect a device" → permission → Scan; "Try Demo Mode" → Dashboard on demo transport.
- **Data:** none from device.

### 4.2 Scan & pair (Screen 2)

- **Purpose:** find devices, connect, establish auto-reconnect trust.
- **Data per row:** advertised name (`Link-Power-N`), model/variant if previously seen (from stored Device Information, API.md §2.2), MAC if previously seen (from stored `DEVICE_ID` reply — 6 bytes reversed = `DC:04:5A:EB:72:2B` format, API.md §3.4), RSSI as 4-step signal bars.
- **States:** scanning (radar animation) · empty ("Bring your Link-Power within range — make sure it's switched on", plus Demo entry) · found list · connecting (row spinner) · pairing (system dialog may appear — see PIN note §8.4) · failed (retry + help) · OTA-mode device (amber row → recovery flow §8.1).
- **Interactions:** tap row = connect; pull-to-refresh restarts scan; known devices sort first; a known device that appears auto-connects if "Auto-reconnect" is enabled for it (default on).
- **Behavior:** on connect, run the full handshake (§5.2). Store peripheral identifier, DIS strings, MAC, CID, FEATURES for next launch.

### 4.3 Dashboard (Screen 3)

- **Purpose:** the glanceable home — battery state and both ports, live.
- **Layout:** battery hero (segmented meter default; instrument gauge via preference) → stat row (capacity / runtime / voltage) → DC Port card → Type-C Port card → tab bar.

Data mapping (every number to its telemetry field):

| UI element | Source | Field (API.md §4) |
|---|---|---|
| Battery % (hero) | `ExtBatteryInfo` 0x4303 notify | `level` u8 @7 |
| Charging/discharging color + arrow | 〃 | `status` **int8** @1 (1=charging→green, −1=discharging→orange, 0=idle→neutral) |
| "Fully charged" badge | 〃 | `full` u8 @2 |
| Capacity "412 / 512 Wh" | 〃 | `capacity` SFLOAT @5 / `maxCapacity` SFLOAT @3 |
| Runtime "3 h 12 m" | 〃 | `remain` u16 @14 (minutes) |
| Battery voltage | 〃 | `voltage` SFLOAT @8 |
| Battery power W (hero sub-line) | 〃 | `power` SFLOAT @12 |
| DC card on/off | `DcPortStatus` 0x4304 notify | `enabled` u8 @0 |
| DC V / A / W | 〃 | SFLOATs @2 / @4 / @6 |
| DC bypass pill | 〃 | `bypassOn` u8 @8 (len ≥ 9) |
| Type-C V / A / W | `TypeCPortStatus` 0x4305 notify | SFLOATs @2 / @4 / @6 |
| Type-C temperature | 〃 | `temperature` SFLOAT @8 |
| Type-C mode chip ("In · Out") | 〃 | `mode` u8 @11 (0 dis/1 in/2 out/3 all) |
| Type-C "DC input" indicator | 〃 | `isDCInput` u8 @12 |

All SFLOATs decode per API.md §6 (12-bit mantissa, 4-bit exponent, both sign-extended; NaN `0x07FF` renders as "—").

- **States:** loading (skeleton cards during handshake) · live · stale · disconnected (cards dim, hero shows last-known % with timestamp, "Reconnecting…" banner) · demo (DEMO badge) · reduced (LP+: DC-only layout, §5.6).
- **Interactions:** DC toggle (F4) · Type-C toggle (F5) · Type-C card tap → Limits screen · hero long-press → meter/gauge style switch · pull-to-refresh forces a read of all three characteristics.
- **Parse rule:** frames are length-variable across firmware (11-byte `DcPortStatus`, 13-byte `TypeCPortStatus` on fw 1.4.9); parse by documented offsets, ignore trailing undocumented bytes (@9–10 of 0x4304), never reject a frame for being longer than expected (API.md §4.2–4.3).

### 4.4 USB-C power limits (Screen 4)

- **Purpose:** control PD negotiation ceilings; protect small sources or force fast charge.
- **Content:** three detented sliders — Global (type 1), Input (type 2), Output (type 3) — stops 30/45/60/65/100/140 W (levels 0–5); a read-only **Runtime** readout (type 4) showing the currently negotiated live limit; a persistent safety note ("Limits are stored on the device and survive restarts. Setting a low input limit slows charging; a low output limit may cause connected laptops to charge slowly or not at all."); per-slider "Reset to default".
- **States:** loading (GET ×4 on entry) · live · runtime-unset (type 4 `RESULT 0xFF` → "— no device negotiating") · write-pending (slider haptic + spinner) · error (revert slider, toast) · unsupported (screen unreachable: gated on `FF_USB_POWER_LIMIT`).
- **Source of truth:** after every SET/DEL the app re-GETs that type and renders the reply. Rationale: DEL does not create an "unset" state — it resets to the device default (65 W observed), and `0xFF` "unset" only ever occurs for runtime type 4 (both live-verified, API.md §3.4).
- **Never** send the PWA's broken clear frame (`0x06` opcode) — documented silent no-op (API.md §3.4).

### 4.5 Schedules / Timers (Screen 5)

- **Purpose:** on-device DC-port scheduling that works with the phone away.
- **Content:** list of up to 6 timers; each row: enable toggle, time (Plex Mono), repeat descriptor ("Daily", "Mon Wed Fri", "1st + 15th", "Once · Aug 3"), action chip (Turn On / Turn Off). Editor sheet: action, type (one-shot/daily/weekly/monthly), time, repeat pickers matching the struct semantics exactly (API.md §3.4 TIMER_SETTINGS).
- **States:** loading · empty ("No schedules — the device runs these itself, even with your phone away") · list · editing · saving · error · full (6/6 → add disabled with explainer) · clock-skew warning (if device clock drift > 2 min, banner offering "Sync clock" — timers fire on the *device's* clock, API.md §5).
- **Gating:** `FF_DC_OUT_SCHEDULER`.
- **Wire details:** all CRUD via sub-opcodes (list `[0x06,0x00,0x00]`, get `[0x06,0x00,0x01,id]`, add/edit `[0x06,0x01,0x02,id,…struct]`, delete `[0x06,0x01,0x04,id]`). Get replies carry a 5-byte trailer and list replies a trailing byte — parse the documented prefix, ignore trailers (live-verified, API.md §3.4).

### 4.6 System & device settings (Screen 6)

- **Purpose:** identity, maintenance, power actions, expert access.
- **Sections & sources:**

| Item | Source / command |
|---|---|
| Model (`BP4SL3V2`) | DIS `0x2A24` |
| Hardware / variant (`V5#0305` → "LP2 V5") | DIS `0x2A27`, parsed `variant#CID[#rREV]` (API.md §7) |
| Firmware (app) | DIS `0x2A28` |
| OTA bootloader | DIS `0x2A26` |
| MAC address | `DEVICE_ID [0x10,0x00]` reply, bytes reversed |
| Clock sync (auto + manual) | Current Time `0x2A2B` 10-byte write (API.md §5) |
| DC Port toggle | `DC_CONTROL` (same as dashboard) |
| DC Bypass toggle | `DC_BYPASS_CONTROL` + telemetry reconciliation (§5.7) |
| Firmware Update row ("1.4.9 → 1.5.0 available" badge) | CDN check, only on screen entry (§8.2, §9) |
| Restart | `[0x11,0x01]`, disconnect = success |
| Shut Down | `"FM"` → `0x4310`, disconnect = success |
| Expert ▸ BLE PIN, Factory mode | `BLE_PIN` / `RUNNING_MODE_CONTROL` (F18) |

- **States:** live · disconnected (info rows show cached values dimmed; action rows disabled) · demo (actions simulate).
- Restart/Shut Down/Expert rows hide or disable per FEATURES (`FF_SHUTDOWN`, `FF_FACTORY_MODE`).

### 4.7 Firmware update — OTA (Screen 7)

- **Purpose:** guided, brick-safe OTA with unambiguous progress.
- **Content:** current vs. available version + changelog (from CDN `log` field, API.md §10.1); progress ring (Plex Mono %); staged step list mirroring the real protocol: **Enter update mode → Prepare (erase / MTU) → Program → Verify → Finish**; persistent warning banner: "Keep the device on and stay nearby. Don't close Wattline. Interrupting an update can leave the device unusable until recovered."
- **States:** up-to-date · update-available · downloading pack · validating pack (CRC16 header, CRC32 firmware, CRC32 pack, CL-section CID match — all four must pass, API.md §11) · awaiting-confirmation (shows battery gate, §8.3) · macOS pre-flight (bond dance, §8.5) · entering OTA (device reboots to `PeakDo-OTA`) · erasing · programming (ring = bytes written / total) · verifying · finishing · success (reconnected, new version confirmed via DIS re-read) · failed-recoverable (retry from erase; device still in bootloader) · cancelled-before-erase (bare `[0x83]` exit, device returns to app mode — live-verified recovery path, API.md §9.7).
- **Interactions:** Cancel allowed only before ERASE; after ERASE the modal is uncancellable and the screen stays awake (`isIdleTimerDisabled`).
- Full protocol sequence in §8.

### 4.8 Siri Shortcuts & App Intents gallery (Screen 8)

- **Purpose:** discoverability for automation; one-tap add to Shortcuts.
- **Content:** cards for **Toggle DC Port**, **Get Battery Level**, **Set USB-C Limit** (parameter: type + wattage from the 6 levels), and a **Low Battery automation** recipe. Each card: phrase example ("Hey Siri, what's my power station at?"), Add to Siri button.
- **States:** normal · no-device-yet (cards visible but disabled with "Connect a device first") · demo (intents run against the simulated device, clearly badged).
- Technical behavior in §6.3.

### 4.9 iOS system surfaces (Screen 9)

**Live Activity** (charging + discharging variants): lock-screen banner + Dynamic Island. Shows %, meter, state arrow, runtime ("3 h 12 m to empty" / "1 h 04 m to full" — the same `remain` field, labeled by `status`), port wattage summary. Green tint charging / orange discharging. Compact island: % + bolt; minimal: ring segment.

**Widgets:** small (battery ring, %, state color, staleness timestamp) and medium (ring + runtime + DC/USB-C wattage rows). Both deep-link into the dashboard. Staleness is a first-class element: "as of 14:32" whenever data isn't live (§6.2 refresh model).

**App icon:** indigo, segmented-meter glyph (per design).

### 4.10 macOS surfaces (Screen 10)

- **Menu-bar item:** monochrome template glyph: battery % text (Plex Mono) + bolt overlay when charging. Colorless in the bar (macOS convention); color lives in the popover.
- **Popover:** battery hero (compact), runtime, DC toggle, USB-C toggle, per-port wattages, "Open Wattline" + "Firmware update available" row when applicable. Mirrors dashboard state machine including stale/disconnected.
- **Notification Center widget:** the same WidgetKit small/medium widgets as iOS.
- Behavior details in §7.

---

## 5. BLE integration spec

### 5.1 Stack & transport abstraction

- CoreBluetooth on both platforms. All protocol logic lives in a platform-agnostic `WattlineCore` package behind a `DeviceTransport` protocol with three implementations: `BLETransport` (CoreBluetooth), `DemoTransport` (§10), `ReplayTransport` (tests, replays captured frames).
- Command channel `0x4302` is strictly **write-with-response, then read** (API.md §3). Serialize commands through a single async queue per device — one in-flight transaction at a time; queue depth surfaced to UI as the pending state.
- 16-bit UUIDs used directly (`CBUUID(string: "5301")` etc.).

### 5.2 Connection handshake (mirrors PWA, API.md §8)

1. `connect()` → on `didConnect`, wait ~2 s (firmware needs settle time — PWA does the same).
2. Discover services `0x5301`, `0x180A`, `0x1805`; discover characteristics.
3. Write `[0x84]` (OTA INFO) to `0x4301`, read reply → `mode` byte: 1 = app mode → continue; 2 = bootloader → route to OTA recovery (§8.1). Parse CID from offset 13 when present (15-byte app-mode reply live-verified).
4. Read DIS strings (model, hardware rev, software rev, firmware rev).
5. Query FEATURES `[0xFE, 0x00]` → u32 LE bitmask at byte 3; cache per device.
6. Read-then-subscribe telemetry per capability: `DcPortStatus` always (if `FF_DC_OUT_PORT`); `ExtBatteryInfo` + `TypeCPortStatus` only when the respective FEATURES bits (or LP1/LP2 CID fallback) allow.
7. Write Current Time (§4.6) — automatic clock sync on every connect.
8. Load timers (list + per-id gets) lazily on first Timers-tab visit (not in handshake critical path — differs from PWA; Assumption §11.2).
9. **No CDN call in the handshake.** Firmware check happens only on the Settings/OTA screen (privacy, §9).

Target: dashboard live ≤ 5 s from `didConnect` (2 s of that is the mandated settle wait).

### 5.3 Identity & storage

Per device, persisted locally (UserDefaults/SwiftData in the app group container): peripheral `identifier` (UUID), advertised name, model/variant/firmware strings, CID, FEATURES, MAC (via `DEVICE_ID [0x10,0x00]` — 6 bytes, reversed byte order; the only way to show a MAC on Apple platforms), last-seen timestamp, last telemetry snapshot (for widgets/stale UI).

### 5.4 Frame codec

- Requests `[CMD, ACTION, …payload]`; replies `[CMD_echo, ACTION|0x80, RESULT, …]` (API.md §3.1). Codec validates the echo byte and action-echo; a mismatched echo fails the transaction.
- Result-code table honored: `0x00` ok · `0xFF` unset (limits type 4) · `0xFD` unavailable · `0xFC` action-unsupported — plus the DC-bypass exemption (§5.7).
- SFLOAT (IEEE-11073 16-bit) decode/encode exactly per API.md §6 incl. NaN/±Inf specials; unit-tested against the live-captured vectors (`d0 e7` = 20.00 V, etc.).
- All multi-byte integers little-endian.
- Length-tolerant parsing for telemetry (§4.3 parse rule).

### 5.5 Reconnect strategy

- On disconnect: immediately issue `connect()` again on the stored peripheral — CoreBluetooth pending connects never time out, so the device reconnects the moment it's back in range/on.
- iOS: `bluetooth-central` background mode + CoreBluetooth **state restoration** (`CBCentralManagerOptionRestoreIdentifierKey`) so reconnects survive app suspension/relaunch.
- Expected-disconnect suppression: RESTART, `"PK"`, `"FM"` all *succeed by disconnecting* (API.md §3.4/§3.5) — the transport marks these transactions "disconnect-expected" so the UI shows the intentional flow (Restarting… / Entering update mode… / Powered off) instead of the error banner. After RESTART, auto-reconnect resumes (~15 s re-advertise). After `"FM"`, auto-reconnect is disarmed until the user acts (device needs its physical button).
- Backoff: none needed (pending connect is passive); scanning restarts only on the Scan screen.

### 5.6 Capability gating model

Resolution order: **FEATURES bitmask** (authoritative) → **CID** (fallback: model byte `CID >> 8`: 0x01 LP1, 0x02 LPP, 0x03 LP2) → **model-number string** (legacy mapping, API.md §7). Unknown CID (e.g., a future LP2_V6) is *not* an error — FEATURES still gates correctly; the UI shows the raw variant string. (Precedent: LP2_V5 itself is absent from the PWA's table — API.md §7.)

| FEATURES bit | Gates |
|---|---|
| 4 `FF_BATTERY_CAPACITY` | Battery hero, stat row, widgets, Live Activity, Get Battery Level intent, low-battery notification |
| 5/6 `FF_DC_OUT_PORT` / `FF_DC_OUT_CONTROL` | DC card / DC toggle (+ Toggle DC intent) |
| 7 `FF_DC_OUT_SCHEDULER` | Timers tab |
| 8 `FF_USB_PORT` | Type-C card |
| 9 `FF_USB_POWER_LIMIT` | Limits screen + Set USB-C Limit intent |
| 10 `FF_USB_OUTPUT_CONTROL` | Type-C toggle |
| 11/12 `FF_DC_BYPASS` / `FF_DC_BYPASS_CONTROL` | Bypass pill / bypass toggle |
| 13/14 `FF_USB_DC_INPUT(_POWER)` | "DC input" indicator / its wattage |
| 1 `FF_FACTORY_MODE` | Expert ▸ Factory mode |
| 3 `FF_SHUTDOWN` | Shut Down row |

Hidden means **absent**, not disabled — per principle 2.

### 5.7 Documented firmware quirks Wattline must handle

1. **DC-bypass non-standard result codes** — `[0x14,0x01,op]` returns `0xFF`/`0xFD` even when the toggle works, and bypass-on can engage seconds later, asynchronously. Wattline ignores the result byte for this one command, shows a "pending" toggle, and reconciles from `DcPortStatus.bypassOn` (byte 8) with a 10 s reconciliation window before declaring failure. (API.md §3.4.)
2. **PWA power-limit clear bug** — the OEM clear path sends opcode `0x06` and silently no-ops. Wattline sends `[0x02, 0x02, type]` and treats DEL as reset-to-default (65 W observed), re-reading after (API.md §3.4).
3. **Disconnect-as-success** — RESTART / `"PK"` / `"FM"` writes "fail" with a disconnect; that *is* the ack (§5.5).
4. **`TYPEC_CONTROL` reflects in `mode`, not `enabled`** (§4.3/F5).
5. **`RUNNING_MODE_CONTROL` does reply** — read it; don't fire-and-forget (API.md §3.4).
6. **Stale peripheral name cache** — match on advertisement `local_name` only (API.md §12).
7. **`0xFF` "unset" only for runtime limit type** — types 1–3 always return a level (API.md §3.4).
8. **macOS bonding trap on OTA re-entry** — §8.5.

---

## 6. Widgets, Live Activities, App Intents

### 6.1 Refresh model (notification-driven, never polled)

The app process (iOS app or macOS agent) is the only BLE owner. Every telemetry notification updates an in-memory `DeviceState`; a snapshot (%, status, runtime, port wattages, timestamp) is written to the **app-group container** and fanned out:

- **Live Activity:** `Activity.update(…)` locally from the app on each material change (≥1 % level change, status flip, port toggle) — no push token, no server (there is no server). Works while backgrounded because BLE notifications wake the app via `bluetooth-central`.
- **Widgets:** `WidgetCenter.reloadTimelines` on material change, throttled to respect the reload budget (≤ ~1 reload/15 min steady-state; immediate on status flips). Widget timelines render the app-group snapshot + "as of" staleness stamp; widgets never touch BLE.
- **macOS:** the menu-bar agent is always running, so the popover and menu-bar title update on every notification; NC widget via the same snapshot + reload path.

Nothing polls the device: telemetry arrives as GATT notifications on `0x4303/0x4304/0x4305` (API.md §4). The single deliberate read cycle is the on-connect read-before-subscribe.

### 6.2 Live Activity lifecycle

- Auto-start when `status` becomes 1 (charging) or −1 (discharging) while enabled in app settings (per-state toggles: "During charging" / "During discharging"); auto-end 5 min after `status` returns to 0 or on disconnect >15 min (shows "last seen" until then).
- Content: level, meter, runtime with direction-aware label, aggregate output W (`DcPortStatus.power + TypeCPortStatus.power`), green/orange tint. 8-hour ActivityKit lifetime handled by re-requesting on significant updates.

### 6.3 App Intents

| Intent | Parameters | Behavior | Failure modes |
|---|---|---|---|
| **Toggle DC Port** | device (default: last), on/off/toggle | Connect if needed (§6.3.1) → `DC_CONTROL` → confirm via telemetry → result dialog | Not in range; unsupported (no `FF_DC_OUT_CONTROL`) |
| **Get Battery Level** | device | Returns `%`, status word, runtime as an `IntentResult` (usable in Shortcuts logic) | Not in range → returns last snapshot with `isStale=true` + age |
| **Set USB-C Limit** | device, type (Global/Input/Output), wattage (30/45/60/65/100/140) | SET + re-GET; speaks the confirmed value | Unsupported; write rejected |
| **Sync Clock** *(P2)* | device | Current Time write | — |

**6.3.1 Connection window:** intents run in-process (`ForegroundContinuableIntent` when the app must open). If already connected, execution is sub-second. If not, the intent attempts a 10 s connect window; on timeout it fails with a clear message (or returns stale data, for Get Battery Level). Documented in the gallery cards.

**6.3.2 Low-battery automation:** iOS offers no third-party event triggers for Shortcuts automations. Wattline therefore ships it as: (a) a **local notification** at a user-set threshold (default 20 %), driven by `ExtBatteryInfo` notifications in the background — with a Notification action "Turn off DC Port"; and (b) a gallery recipe: time-based Shortcuts automation → Get Battery Level → If < threshold → act. The gallery card explains both honestly. (Assumption §11.2.)

---

## 7. macOS

### 7.1 App shape

`MenuBarExtra` (SwiftUI) app; user-choosable **Dock + menu bar** or **menu-bar only** (`LSUIElement` toggle "Show in Dock"). Launch-at-login via `SMAppService`. The menu-bar process owns the BLE connection continuously — macOS apps aren't suspended, so the popover is always warm and reconnects are instant.

### 7.2 Menu-bar item & popover

- Title: `⚡︎ 84%` — bolt glyph only while charging; template rendering (monochrome) per macOS convention; % in Plex Mono. Optional "percentage only when charging/discharging" density setting.
- Popover = shared SwiftUI views (§7.3): compact hero, runtime, DC + USB-C toggles (same commands + reconciliation as iOS), stale/disconnected states, firmware-available row, "Open Wattline".
- Clicking a toggle never blocks the popover; pending state renders inline.

### 7.3 Shared-codebase strategy

| Package | Contents | Reused on |
|---|---|---|
| `WattlineCore` | Transport protocol, BLE engine, frame codec, SFLOAT, models, capability gate, OTA engine, demo simulator | everything incl. widgets/intents (read-side) |
| `WattlineUI` | BatteryHero (meter+gauge), PortCard, StatTile, TimerRow/editor, LimitSlider, OTAProgress, theme (colors/typography) | iOS app, macOS window **and popover**, widget views where WidgetKit allows |
| App targets | iOS app (tabs), macOS app (sidebar window + MenuBarExtra), WidgetKit extension (both OSes), Intents included in-app | — |

The macOS main window reuses the iOS tab content in a `NavigationSplitView`. The popover embeds `BatteryHero(compact:)` + `PortCard(compact:)` — same views, size-class-varianted, not forks.

### 7.4 macOS particulars

- CoreBluetooth on macOS needs no Info.plist permission prompt for LE, but **the OTA bond trap is macOS-specific and must be handled in-flow** (§8.5).
- NC widget shares the WidgetKit targets; snapshot via app group as on iOS.

---

## 8. Firmware update (OTA) — protocol flow, safety, edge cases

### 8.1 Entry points

- Settings → Firmware Update (normal path).
- Scan screen finds a `PeakDo-OTA` device (someone's earlier update died) → **Recovery**: offer "Resume update" (if we hold a validated pack for its CID) or "Exit update mode" (bare `[0x83]` — cleanly reboots to app mode, live-verified; API.md §9.7).

### 8.2 Update check & download (the app's only network I/O)

`GET /channel/1/cid/{cid}/fw/latest?ver={a.b.c}` — CID **decimal**, version suffix stripped (API.md §10.1). Empty `data` → "Up to date". Else show version + changelog. On user confirmation only: `GET /fw/{fid}/bin` → `.fwp` pack → validate **all four** integrity gates: header CRC16-CCITT-FALSE, firmware CRC32, whole-pack CRC32, and CL-section contains this device's CID (API.md §11). Any failure discards the pack. Type-2 (`ota`) packs update the bootloader itself — out of scope v1, surfaced as "Contact PeakDo" (Assumption §11.2).

### 8.3 Pre-flight gates (brick prevention, part 1)

- Battery ≥ 20 % **or** charging (Assumption — design shows a warning, threshold ours; §11.2).
- Pack validated (§8.2) and staged on disk (survives app relaunch → resume).
- Screen-awake engaged; iOS warns "Keep Wattline open"; user confirms the brick warning.
- **macOS only:** bond pre-flight (§8.5).

### 8.4 Protocol sequence (API.md §9)

1. Write `"PK"` (`[0x50,0x4B]`) to `0x4301` → disconnect-as-success → device re-advertises as `PeakDo-OTA` (match on adv `local_name`).
2. Connect to bootloader (minimal GATT: only `0x4301` + DIS). `INFO [0x84]` → mode 2 + `otaStartAddress`, `blockSize`, `appStartAddress`, CID (20-byte reply live-verified).
3. `FEATURES [0x90]` → bits: DETECT_MTU / WHOLE_VERIFY / LARGE_CHUNK (`0x7` on bootloader 2.0.2).
4. If DETECT_MTU: binary-search frame size via `0x89` probes; else default 240-byte chunks.
5. `ERASE 0x81` — `blocks = ceil(fwSize/blockSize)` from `otaStartAddress`. **Point of no return**: cancel disabled from here.
6. `PROGRAM` — `0xA0` large-chunk if supported else `0x80`; write-without-response fast mode; 4-byte-aligned, `0xFF`-padded tails; ring = bytes/total.
7. Verify — `WHOLE_VERIFY 0x85` (size + CRC32 + version triplet) if supported, else per-chunk `VERIFY 0x82` over every chunk. **Failure → retry from step 5 (up to 2×); never proceed.**
8. `END 0x83` (bare form when WHOLE_VERIFY supported) → device reboots to app mode → reconnect → re-read DIS Software Revision and assert it equals the pack version → Success.

### 8.5 macOS CoreBluetooth bonding trap (brick-*adjacent*, live-hit)

App firmware demands encryption → macOS silently bonds; the bootloader has **no bond storage** → every bootloader connect fails with `CBError 14 "Peer removed pairing information"`. `blueutil --unpair` and editing the paired.db **do not work**; the only fix that sticks is System Settings → Bluetooth → **Forget the device while it is in bootloader mode** (API.md §12).

Wattline's flow: after step 1 (device now in bootloader), if the connect fails with CBError 14, show a blocking instruction card — "Open System Settings → Bluetooth → Forget 'Link-Power-…' → Return here" — with a Retry button; on success continue automatically. The card warns that reconnecting in app mode re-arms the trap (expected; it recurs on every future OTA). iOS: same detection logic kept, but the trap has only been reproduced on macOS; if pairing errors occur, an equivalent "Forget this Device" card shows (Assumption §11.2).

### 8.6 Failure matrix

| Failure | Device state | Wattline behavior |
|---|---|---|
| Disconnect mid-PROGRAM | Bootloader (app image partially erased — device won't boot to app until completed) | Auto-rescan for `PeakDo-OTA`, auto-resume from ERASE with the staged pack; persistent notification "Update interrupted — resume" |
| Verify fails twice | Bootloader, image invalid | Keep device in bootloader, message "Do not exit update mode"; offer retry; never send END |
| User force-quits app mid-flight | Bootloader | On next launch, staged-pack + `PeakDo-OTA` detection → resume flow (§8.1) |
| Cancel before ERASE | Bootloader, app image intact | Bare `[0x83]` exit → reboots to app (live-verified) |
| CDN unreachable | n/a | "Couldn't check for updates" — no retry loop, no background retry |
| Battery below gate | App mode | Block with "Charge above 20 % or plug in to update" |

Other cross-cutting edge cases (outside OTA):

- **Low battery:** threshold notification (§6.3.2); Live Activity turns urgent-styled ≤ 10 %.
- **Out of range / powered off:** stale UI (10 s) → disconnected overlay; pending connect keeps trying silently; widgets/menu bar show "as of" stamps. Distinguishing off vs. out-of-range is impossible over BLE — copy says "out of range or powered off."
- **Multiple devices:** v1 = one active connection; all previously connected devices persist in Scan with per-device auto-reconnect toggles; active-device picker in the dashboard nav bar when >1 known (F19 expands to concurrent connections in v1.x).
- **PIN-protected devices:** firmware requests encryption on connect; the OS presents the pairing dialog and the user enters the device PIN there — Wattline never captures the PIN itself (§9). Pairing failure (`insufficientEncryption`/`CBATTError` on first read) → "This device has a PIN" explainer + retry.

---

## 9. Privacy & security

- **No cloud control path.** `WattlineCore` and `WattlineUI` have no networking dependency. Optional router access is isolated in `WattlineNetwork` and talks only to a wattlined instance explicitly selected by the user; Bluetooth remains primary and Demo Mode remains fully offline. The OTA client remains isolated to the future Firmware Update module and targets `api.peakdo.ca/fw-api` exclusively as described in API.md §10.
- **Optional LAN/VPN transport:** Wattline may connect directly to wattlined over a local LAN or a user-provided Tailscale/WireGuard/other VPN address. This is peer-to-peer control of the user's own router, uses the same telemetry-is-truth model as BLE, and never relays device data through a Wattline cloud service. LAN discovery may use `_wattline._tcp`; remote/VPN addresses are entered manually because mDNS is not assumed to cross VPN boundaries.
- **Router authentication and transport security:** each router uses a per-client bearer token obtained from wattlined pairing. Tokens are stored in Keychain and never in app preferences, app-group snapshots, logs, or host metadata. HTTPS connections require certificate-fingerprint pinning for both HTTP commands and SSE telemetry. Plain HTTP is allowed for LAN/VPN use; plain-HTTP WAN hosts require a separate explicit insecure-WAN opt-in with an interception warning.
- No accounts, no analytics/crash SDKs (Apple's opt-in crash reporting only), no ads, no third-party dependencies in the network path. App Privacy label: **Data Not Collected**.
- All persisted data (device identities, MACs, telemetry snapshots) stays in the local app-group container; never in iCloud (Assumption §11.2 — no sync in v1).
- **BLE PIN handling:** the OS pairing dialog handles PIN entry — Wattline never sees it. The Expert PIN-*setting* flow transmits the new PIN over an encrypted (bonded) GATT link as the protocol requires, does not persist it anywhere, and clearly warns it's set-only and unrecoverable via BLE (`GET/DEL → 0xFC`, API.md §3.4). Losing the PIN is a physical-reset problem, and the UI says so.
- Local Network permission is requested only when the user configures the optional router transport; location permission is not requested. Router discovery is dormant until its UI is enabled, and manual LAN/VPN hosts remain available without cloud discovery.
- Firmware packs are integrity-checked (4 CRC/CID gates, §8.2) before a single byte is written to the device.

---

## 10. Demo Mode

Purpose: full product tour with zero hardware and zero permissions (App Review benefits too).

Requirements:

1. `DemoTransport` implements the identical `DeviceTransport` interface — the UI cannot tell it apart (same handshake stages, same notification cadence ~1 Hz).
2. Simulated device: "Link-Power 2 (Demo)", LP2_V5, CID `0x0305`, FEATURES `0x7FFF`, fw "1.4.9".
3. Scripted telemetry: starts at 62 % discharging (−45 W: DC 19.6 V/1.2 A, USB-C 12 V/1.4 A), runtime derived from capacity/power; a "Plug in charger" demo control flips `status` to charging (+100 W) with green ramp; values carry realistic jitter (±2 %).
4. All controls function: port toggles update the corresponding simulated telemetry (respecting the mode-vs-enabled quirk!); limit changes clamp simulated negotiated wattage; timers CRUD against an in-memory table incl. status −3 expiry; restart simulates a 15 s disconnect/reconnect; OTA runs the full staged flow against a fake 350 KB image (including a resumable simulated interruption via a hidden gesture).
5. Deterministic seed for screenshots/UI tests.
6. Every surface shows a **DEMO** badge (dashboard corner, widget corner, menu-bar tooltip); widgets/intents work against the demo device only while Demo Mode is active.
7. Exit: "Connect a real device" always visible in Settings and Scan.

---

## 11. Open questions & assumptions

### 11.1 Open questions

1. **LP+ dashboard hero** — design's hero is battery-centric; LP+ has no battery telemetry. Proposed DC-hero (voltage/wattage focal) needs a design pass.
2. **Firmware downgrade / channel 0 (test)** — CDN supports both (API.md §10.1). Expose in Expert? Currently: no.
3. **OTA-type packs (`type: 2`, bootloader updates)** — supported flow or permanent "contact PeakDo"?
4. **Barrier-free mode (`0x03`) and DC-bypass threshold (`0x15`)** — protocol-verified but absent from the design. Expert-tier candidates for v1.x; excluded now per do-not-invent rule.
5. **Timer max** — is 6 a device limit or a design choice? Probe a 7th add on hardware; if accepted, keep UI at 6 anyway?
6. **`DcPortStatus` bytes 9–10 / timer reply trailers** — undocumented; continue ignoring, revisit with new firmware.
7. **Live Activity while phone is locked long-term** — iOS may suspend the BLE link on aggressive power saving; validate real-world update longevity, else add an honest staleness treatment in the Activity.
8. **watchOS** glance — demand exists (vanlife), out of scope pending v1 traction.

### 11.2 Explicit assumptions (design implies, detail open)

| # | Assumption |
|---|---|
| A1 | Scan rows show MAC only for previously connected devices (Apple hides MACs; `DEVICE_ID` needs a connection). New devices show name + RSSI only. |
| A2 | Timer cap of 6 is enforced client-side per the design. |
| A3 | OTA battery gate: ≥ 20 % or charging. Design shows the warning, not the number. |
| A4 | Timers load lazily on Timers tab, not during handshake (faster dashboard; PWA loads them in-handshake). |
| A5 | "Low-battery automation trigger" ships as local notification + Get-Battery-Level Shortcuts recipe, since iOS lacks third-party automation triggers (§6.3.2). |
| A6 | Firmware check runs only on Settings/OTA screen entry — stricter than the PWA's on-connect check, chosen for the privacy principle. |
| A7 | The iOS bonding-trap card mirrors macOS handling though the trap is only reproduced on macOS. |
| A8 | No iCloud sync of device list in v1. |
| A9 | Demo device is an LP2_V5 with all features — it exercises every UI path. |
| A10 | Power-limit "default" after DEL displays whatever the device reports (65 W observed on LP2_V5/1.4.9) rather than a hard-coded constant. |
| A11 | macOS 14+ floor (MenuBarExtra maturity + WidgetKit parity with the iOS 17 floor). |

---

## 12. Phased release plan

### Phase 1 — MVP (internal / TestFlight)

F1–F8: onboarding, scan/pair/auto-reconnect, dashboard with live telemetry, DC + USB-C toggles, USB-C limits, capability gating, Demo Mode. iOS only. Exit criteria: 48 h soak against LP2_V5 with zero stuck states; all quirk regressions (§5.7) covered by `ReplayTransport` tests; reconnect ≤ 10 s p95.

### Phase 2 — v1.0 (App Store)

F9–F16: settings (clock sync, bypass, restart, shutdown), timers, Live Activities, widgets, macOS menu-bar + NC widget, App Intents gallery, low-battery notification. Exit criteria: Live Activity survives a full discharge cycle with honest staleness; macOS popover toggles round-trip < 1.5 s; intents pass Shortcuts-app integration tests; privacy label "Data Not Collected" verified by network audit (zero connections with OTA screen unvisited).

### Phase 3 — v1.x

F17 OTA (after §8 failure matrix is fully rehearsed on sacrificial hardware, incl. the macOS bond dance and mid-PROGRAM pull-the-battery recovery), F18 Expert tier, F19 multi-device, plus backlog from §11.1 (LP+ hero, threshold/barrier-free expert controls, local history charts, watchOS spike).

---

*End of specification.*
