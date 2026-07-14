# Wattline Router — Design Spec

| | |
|---|---|
| **Product** | `wattline-router` — OpenWrt daemon + LuCI app that monitors and automates a PeakDo LinkPower power bank over BLE from a GL.iNet router |
| **Target** | GL.iNet Spitz AX (GL-X3000): MediaTek MT7981 (aarch64), GL firmware 4.x on OpenWrt 21.02, kernel 5.4, 512 MB RAM, 8 GB eMMC, USB 2.0 port |
| **Status** | Draft v1.0 — 2026-07-14, design approved in brainstorming session |
| **Sources** | `API.md` (BLE protocol, fully live-verified 2026-07-14 incl. bootloader) · `LinkPower-2_quick_start_v2.1.pdf` (OEM manual) · Wattline-SPEC.md (Apple app sibling; §5.7 quirks list shared) |

## 1. Goal & scope

Run unattended on the router, hold a BLE connection to the LinkPower 2, and execute user-defined automation rules — the headline example: **"after 10 minutes of no input power, shut the power bank down (and tell me)."** Managed as .ipk packages installable from the GL.iNet panel's Plug-ins tab, configured through a LuCI page, and fully driveable through an HTTP JSON API so future clients (native GL-panel tab, phone app) need no daemon changes.

**Hardware prerequisite:** the retail X3000 has no Bluetooth radio. A USB BLE dongle (CSR8510 or Realtek RTL8761B — both supported by OpenWrt 21.02 `kmod-bluetooth` + firmware packages) occupies the USB 2.0 port.

**v1 non-goals:** native GL-panel tab (later goal — study how Speedify integrates under VPN); MQTT publish action; OTA firmware updates from the router; multiple simultaneous power banks (config schema is per-MAC so this can be added without migration); historical data persisted across reboots.

## 2. Architecture

Single Go daemon (`wattlined`), statically cross-compiled for `aarch64_cortex-a53`. Every UI is a client of its API.

```
BLE transport ─► Device session ─► State store ─► Rule engine ─► Actions
(tinygo/bluetooth  (handshake, notify  (snapshot +      (conditions,     (BLE commands,
 over BlueZ D-Bus)  subs, reconnect)    24h ring buffer)  hold, hysteresis) webhooks)

HTTP JSON API :8377 (REST + SSE, bearer token) ◄─ luci-app-wattline / future GL tab / apps
UCI config /etc/config/wattline               ◄─ SSH / LuCI generic editor
procd init (respawn, SIGHUP reload)
```

Dependencies (via opkg): `bluez-daemon`, `dbus`, `kmod-bluetooth`, dongle firmware package.

### 2.1 BLE layer

- Library: `tinygo-org/bluetooth` (BlueZ D-Bus backend on Linux; CoreBluetooth backend on macOS — the same binary runs on the dev Mac against real hardware).
- Implements the API.md §8 handshake: connect → 2 s settle → OTA INFO mode check (bootloader mode → hold off, log, never touch) → DIS strings → FEATURES bitmask → read-then-subscribe 0x4303/0x4304/0x4305 → Current Time sync.
- Command channel 0x4302: strict write-with-response-then-read, one transaction in flight, echo-byte validation.
- All verified quirks honored: match advertisement `local_name` only; disconnect-as-success for RESTART/`FM`; DC-bypass result codes ignored in favor of telemetry reconciliation (manual explains why: firmware auto-engages bypass <3% and at 100%); power-limit clear uses `[0x02,0x02,type]`, never the PWA's broken `0x06` frame; `TYPEC_CONTROL` confirmed via `mode` field, not `enabled`.
- Pairing: registers a BlueZ agent supplying a configured PIN (UCI `option pin`, default **020555** — the OEM fixed PIN; the device can also run random-PIN mode, shown on its LCD). On `AuthenticationFailed` after a device-side bond wipe, the daemon removes the stale BlueZ bond via D-Bus and re-pairs automatically.
- Reconnect: BlueZ autoconnect plus periodic scan fallback; reconnect stays armed after `restart`; after a `shutdown` action the daemon idles on scan until the device re-advertises (powered on by button **or by external PD power being plugged in** — per the manual, PD input auto-activates a shut-down unit).

### 2.2 State store

Latest full telemetry snapshot (battery level/status/Wh/V/A/W/remain, DC enabled/V/A/W/bypass, USB-C V/A/W/temp/mode/isDCInput) plus a 24 h in-RAM ring buffer at 1-minute resolution for `/history` charts. Lost on daemon restart — acceptable for v1.

### 2.3 Rule engine

Rule = **condition + hold + actions + re-arm policy**, evaluated on every telemetry tick (~1 Hz).

Conditions:

| Type | Params | Signal |
|---|---|---|
| `input_power` | `present` / `absent` | battery `status==1` OR `TypeC.isDCInput==1` |
| `battery_level` | `below`/`above` + percent | `ExtBatteryInfo.level` |
| `schedule` | cron expression | router clock (richer + centrally managed vs the device's 6 on-board timers) |
| `port_power` | port + `above`/`below` watts | port telemetry `power` |

Semantics:

- **Hold** (`10m`): condition continuously true for the whole window; any false tick resets. **Blind means not-firing** — during disconnect no rule progresses toward firing.
- **Re-arm:** default `edge` (fire once, re-arm when the condition goes false); optional `repeat_every`.
- **Hysteresis** on level rules: `below 15` re-arms above `15 + margin` (default 5).
- **Startup:** hold timers start at zero on connect — predictable over clever.

Actions (list, executed in order): `dc_on|dc_off|usbc_on|usbc_off|bypass_on|bypass_off|shutdown|restart|webhook:<url>`. `shutdown` requires `option confirm_shutdown '1'` on the rule; LuCI shows the recovery explanation (button or PD-plug-in wakes it). Webhook = HTTP POST, JSON body `{rule, device, telemetry, fired_at}` — covers ntfy/Home Assistant.

Reference rule (UCI):

```
config rule 'no_input_shutdown'
    option enabled '1'
    option condition 'input_power'
    option state 'absent'
    option hold '10m'
    list action 'webhook:https://ntfy.sh/keith-power?msg=input+lost'
    list action 'shutdown'
    option confirm_shutdown '1'
```

### 2.4 HTTP API

Default `0.0.0.0:8377`; bearer token generated at first boot into UCI; `option lan_api '0'` restricts to localhost.

```
GET  /api/v1/status         daemon + BLE state, device identity (model, fw, MAC, CID, FEATURES)
GET  /api/v1/telemetry      latest snapshot
GET  /api/v1/events         SSE: telemetry ticks, rule transitions, connect/disconnect
GET  /api/v1/rules          rules incl. runtime state (armed / holding / fired)
POST /api/v1/rules          create · PUT/DELETE /api/v1/rules/{name}  (persist to UCI + live-apply)
POST /api/v1/device/action  {"action":"dc_off"} — same vocabulary as rule actions
GET  /api/v1/history        ring buffer for charts
```

### 2.5 LuCI app

`luci-app-wattline`, modern JS LuCI. Views: **Status** (live tiles via SSE, manual action buttons), **Rules** (form builder mirroring UCI schema; hold-time picker; shutdown confirm affordance; note about the device's built-in 10–15 % USB-C reserve cutoff so users don't fight firmware behavior), **Settings** (device MAC + scan-and-pick, PIN, API port/token/LAN exposure). Thin client over the daemon API — GL-panel tab and phone apps reuse the same surface later.

## 3. Packaging & deployment

| Package | Contents | Arch |
|---|---|---|
| `wattlined` | static binary, procd init, UCI defaults, uci-defaults token script | `aarch64_cortex-a53` |
| `luci-app-wattline` | LuCI JS views, menu + ACL JSON | `all` |
| `wattline-bt` | meta-package: Depends on `bluez-daemon dbus kmod-bluetooth` + dongle firmware | `all` |

Built by a repo `Makefile`: `GOOS=linux GOARCH=arm64` cross-compile + tar-based ipk assembly (no OpenWrt SDK needed for a static binary). Optional: generate a package-feed directory servable over HTTP so the GL panel can install/upgrade from a custom repo URL.

procd: start after dbus/bluetoothd, respawn, SIGHUP = re-read UCI without dropping the BLE session; syslog logging (`logread -e wattline`).

## 4. Error handling

- **Dongle absent/unplugged:** daemon degrades to "no adapter" state visible in `/status` + LuCI banner; retries adapter discovery every 30 s.
- **Device out of range / powered off:** reconnect loop (autoconnect + scan); rules blind → no progress; snapshot marked stale with timestamp everywhere it's shown.
- **Bond loss (device-side wipe):** auto remove BlueZ bond + re-pair with configured PIN.
- **Bootloader-mode device found:** never touched; logged + surfaced ("device is in firmware-update mode").
- **Command failure:** per-command retry ×2 then rule marked `failed` in runtime state + webhook actions still attempted; telemetry reconciliation windows per quirk list.
- **Config errors:** invalid rule sections logged and skipped, never fatal; API rejects invalid rules with 400 + reason.

## 5. Testing

1. **Unit (host):** frame codec + SFLOAT against live-captured vectors from the 2026-07-14 verification; rule engine with fake clock (hold, hysteresis, blind, re-arm, startup semantics).
2. **Integration (Mac):** same binary via CoreBluetooth backend against the real LinkPower 2 — handshake, telemetry, actions, rule firing.
3. **Router soak (Spitz AX + dongle):** 24 h connection stability; dongle unplug/replug; device restart/shutdown/PD-wake cycles; reboot persistence; headline rule end-to-end.

## 6. Open questions

1. Current fixed PIN on Keith's unit: BLE_PIN was set to 000000 during protocol verification; manual documents fixed default 020555. Verify which the device now uses when pairing from BlueZ (UCI default stays 020555; setting is user-visible).
2. GL-panel native integration mechanism (Speedify precedent) — research task for v1.x.
3. Whether `input_power` should distinguish DC-input charging from USB-C PD input (manual: PD wake-from-shutdown only works via USB-C). v1 treats any charging as "input present"; revisit if a rule needs the distinction.
