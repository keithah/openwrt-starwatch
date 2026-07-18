# Starwatch — Product & Technical Specification

| | |
|---|---|
| **Product** | Starwatch — Starlink dish monitoring + management for OpenWrt routers, with WAN-link health and failover assistance |
| **Platforms** | OpenWrt 23.05+ (LuCI) and GL.iNet SDK4 firmware (native **Applications** panel entry). First target: GL-X3000 Spitz AX (`aarch64_cortex-a53`); arch is a build knob |
| **Status** | Released v0.1.0 — 2026-07-17 |
| **Components** | `starwatchd` (Go daemon) · `luci-app-starwatch` · `gl-app-starwatch` · opkg feed |
| **Sources** | Starlink local gRPC API (community-documented: sparky8512/starlink-grpc-tools, clarkzjw/starlink-grpc-golang protos) · Speedify OpenWrt integration (support.speedify.com articles 918/922/235/241/1066, sagar.se teardown) · starbar.app feature set · `peakdo/router` (wattline) packaging + GL-panel learnings, verified on a GL-X3000 |

> **Grounding rule used throughout:** every dish telemetry field, control, and behavior in this spec cites the local gRPC API surface documented and exercised by the starlink-grpc-tools community. UI structure decisions cite the Speedify dashboard model or Starbar's card inventory. Packaging decisions cite what was live-verified on-target in the wattline project. Where a decision is ours alone, the spec says **Assumption:** or **Decision:** explicitly.

---

## 1. Overview & goals

### 1.1 Product summary

Starwatch turns an OpenWrt router into a full-time Starlink monitor and control panel. A small Go daemon (`starwatchd`) polls the dish's **local gRPC API** (`192.168.100.1:9200`, plaintext, no account needed), keeps long-horizon history the dish itself cannot (the dish buffers only ~15 minutes), watches the Starlink WAN path with its own probes, raises alerts over webhook/ntfy, and serves a single polished web dashboard. That one dashboard is embedded into **LuCI** (menu entry) and into the **GL.iNet admin panel** (Applications entry) — the Speedify model: one SPA, hosted by the daemon, surfaced natively in whatever admin UI the platform has.

No Starlink account, no cloud API, no telemetry leaves the router. Everything works on a router sitting behind a dish in bypass mode — the normal OpenWrt + Starlink setup.

### 1.2 Goals

1. **Everything Starbar shows, on the router.** Latency, ping success, throughput, power draw, obstruction stats + sky map, alignment, hardware/firmware info, events/outages — all from the local gRPC API, all rendered honestly ("unavailable" beats a guess).
2. **Everything the local API can control, that Starbar can't.** Stow/unstow, reboot, snow-melt mode, sleep schedule, GPS toggle, clear obstruction map, firmware update, dish speed test — with destructive actions gated behind confirmation.
3. **History that outlives the dish's 15-minute buffer.** 30 days of graphs and a persistent outage log, stored flash-gently (RAM ring + downsampled sqlite flush).
4. **WAN-link truth.** Independent latency/loss probes out the Starlink interface so "dish healthy, path bad" and "dish outage" are distinguishable; merged outage timeline; optional mwan3 awareness and a one-click Starlink-primary/cellular-backup assist on GL.iNet.
5. **Speedify-grade looks.** Icon-rail dashboard with live scrolling graphs pushed over WebSocket at 1 Hz — not a LuCI form page.
6. **Alerting that wakes you up.** Outages, obstruction growth, thermal events, water detection, stuck motors → webhook + ntfy, with in-UI alert history.

### 1.3 Non-goals (initial release)

- **No Starlink cloud/account API.** Billing, service plans, data quotas, remote (off-LAN) dishes, fleet management — out of scope permanently for this tool.
- **No channel bonding / VPN.** We borrow Speedify's *UX*, not its product. Starwatch never routes traffic.
- **No general automatic routing changes.** The one narrow exception is the self-healing, VPN-bypassing `192.168.100.1/32` dish-management host route. Starwatch may maintain only that exact route (and users may disable it with `manage_dish_route=0`); it never rewrites default/general routing or firewall config. The mwan3 assist remains an explicit user action.
- **No factory reset button.** The API offers it; we deliberately don't expose it.
- **No general rules engine.** Fixed alert catalog with thresholds (§7). Condition→action rules (wattline-style) are a future-release candidate (§14).
- **Curated Starlink-router Wi-Fi management only.** Topology B may expose ordinary Wi-Fi settings and client controls through guarded, audited, readback-confirmed writes. Factory, regulatory, mesh-trust, bypass/routing, firewall, DHCP, aviation, calibration, and debug surfaces remain excluded; see `API.md`.

### 1.4 Target users

| Persona | Situation | What Starwatch gives them |
|---|---|---|
| **GL-X3000 / dual-WAN nomad** | Starlink primary, cellular backup, RV/boat | Merged outage timeline, failover assist, obstruction map to aim the dish at a new campsite, power-draw card for battery budgeting |
| **Off-grid homestead** | Starlink + solar; router is always-on anyway | 30-day history, snow-melt control from the couch, ntfy alerts when the dish thermally throttles or an outage starts |
| **Homelab / remote worker** | Starlink as primary ISP, OpenWrt box, uptime matters | Persistent outage log with causes for ISP disputes, drop-rate alerts before a video call dies, speed tests on demand |
| **Tinkerer with scripts** | Wants dish data in Grafana/HA | Token-authed local REST + WS API (§9); everything the UI shows is fetchable as JSON |

### 1.5 Competitive framing

| | Official Starlink app | Starbar (macOS) | Starwatch |
|---|---|---|---|
| Runs on | Phone | Mac menu bar | The router itself — always on |
| History | Limited, cloud | Dish's ~15 min buffer | 30 days on-router (§8) |
| Controls | Full (incl. account) | None (read-only) | All local-API controls (§5) |
| Alerts | Push (limited) | None | Webhook/ntfy catalog (§7) |
| WAN path view | No | No | Independent probes + mwan3 (§6) |
| Needs account | Yes | No | No |
| Where it shows up | — | — | LuCI + GL.iNet Applications |

### 1.6 Product principles

1. **Local-only.** The daemon's only network peers: the dish, the LAN, and user-configured alert endpoints (webhook/ntfy). Nothing else, ever.
2. **Honest telemetry.** Field availability varies by dish model/firmware (confirmed by Starbar's docs and starlink-grpc-tools issues). Unavailable fields render as "—/unavailable", never as zero or an estimate.
3. **Read loudly, write carefully.** Polling is relentless; controls are explicit, confirmed, and logged (§5.3).
4. **Degrade gracefully.** No dish reachable → WAN-only mode. No mwan3 → hide failover card. Unknown dish model → show what parses, flag what doesn't (§11).

---

## 2. System architecture

```
                 ┌──────────────────────── OpenWrt router ────────────────────────┐
                 │                                                                │
 Starlink dish   │  ┌──────────────────────── starwatchd ─────────────────────┐   │
 192.168.100.1 ◄─┼──┤ dish client (gRPC poller + backfill)                    │   │
      :9200      │  │ WAN monitor (probes, counters, mwan3 reader)            │   │
                 │  │ history store (RAM rings → sqlite downsample flush)     │   │
                 │  │ alert engine (catalog §7 → webhook/ntfy)                │   │
                 │  │ HTTP server :9633 (REST + WS + SPA static)  [token auth]│   │
                 │  └─────────────────────────────────────────────────────────┘   │
                 │        ▲                        ▲                               │
                 │        │ iframe + token         │ iframe + token                │
                 │  ┌─────┴──────┐          ┌──────┴────────┐                      │
                 │  │ LuCI view  │          │ GL oui view   │                      │
                 │  │ (menu.d +  │          │ (menu.d +     │                      │
                 │  │  rpcd ACL) │          │  compiled js) │                      │
                 │  └────────────┘          └───────────────┘                      │
                 └────────────────────────────────────────────────────────────────┘
```

- **Language/runtime:** Go, plain cross-compile (`GOOS=linux GOARCH=arm64`), static binary, no cgo — sqlite via pure-Go `modernc.org/sqlite`. Same no-SDK pipeline as wattline (proven on GL-X3000).
- **Service:** procd init script, `respawn`, started at boot. UCI config in `/etc/config/starwatch`; a `uci-defaults` script generates a random API token on first install (wattline pattern, verified).
- **Dish protos:** vendored from `clarkzjw/starlink-grpc-golang` (current, full request oneof). Single `Handle` RPC with request oneof; plaintext gRPC; no auth for reads.
- **Process budget:** **Assumption:** < 25 MB RSS steady-state (rings are float32 and bounded, §8.1); one goroutine per poller cadence.

### 2.1 Configuration (`/etc/config/starwatch`)

```
config starwatch 'main'
    option listen        '0.0.0.0'      # SPA must be reachable from LAN
    option port          '9633'
    option token         '<generated>'  # uci-defaults fills if empty
    option dish_addr     '192.168.100.1:9200'
    option poll_status   '1'            # seconds
    option poll_map      '900'          # obstruction map refresh, seconds
    option wan_iface     ''             # autodetect (§6.1); override here
    option probe_hosts   '1.1.1.1 8.8.8.8'
    option probe_interval '2'

config history
    option ram_hours     '3'
    option minute_days   '7'
    option quarter_days  '30'
    option db_path       '/etc/starwatch/history.db'
    option flush_secs    '300'

config alerts
    option webhook_url   ''
    option ntfy_url      ''             # e.g. https://ntfy.sh/mytopic
    # per-alert thresholds/enables, see §7
```

**Decision:** history DB lives under `/etc/starwatch/` so it survives sysupgrade with "keep settings" — but see flash-wear budget §8.3 and open question §13.3.

---

## 3. Deployment topologies

| | Topology | Dish reachability | Behavior |
|---|---|---|---|
| **A (primary)** | Dish in **bypass mode** → OpenWrt WAN gets CGNAT/public IP | Needs a host route: `192.168.100.1/32` out the WAN interface | Full functionality. Package `postinst` offers the route via a UCI static-route entry if missing (well-known community requirement; documented in starlink-grpc-tools setup guidance) |
| **B** | OpenWrt **behind the Starlink router** (double NAT) | The host route must use the Starlink WAN gateway: `192.168.100.1/32 via <wan-gateway>`; an interface-only route can select the wrong uplink on multi-WAN routers | Full dish telemetry; additionally the Starlink router's own gRPC on port 9000 is polled for clients, ping health, configuration, radios, diagnostics, and interfaces. Curated writes follow the guarded `API.md` contract: client blocking is schedule-based, transmit power uses real `TX_POWER_LEVEL_*` enums, and whole-network writes remain gated on credential readback. The package derives the `wan` gateway and emits it in the UCI route; link-scope is reserved for bypass/direct-DHCP setups with no gateway |
| **C** | No dish reachable (probe fails) | — | **WAN-only mode:** dashboard shows WAN health cards + outage log from probes; dish cards show a setup hint. Daemon retries discovery every 60 s |

Detection is automatic at startup and on failure: try `get_device_info` at `dish_addr`; classify topology; expose it in `/api/status` and the UI header.

---

## 4. Dish telemetry — feature ↔ gRPC mapping

All calls are request-oneof members of `SpaceX.API.Device.Device/Handle`.

### 4.1 Reads (polled)

| UI element | gRPC request | Fields used | Cadence |
|---|---|---|---|
| Status header, latency, ping success, throughput, instant power, outage flag | `get_status` | `pop_ping_latency_ms`, `pop_ping_drop_rate`, `downlink_throughput_bps`, `uplink_throughput_bps`, `outage`, `alerts` — instant power prefers a positive `upsu_stats.dish_power`; when absent or zero, falls back to the newest nonzero `get_history.power_in` sample (refreshed at 60 s cadence) and reports `power_source: history` | 1 s |
| Obstruction card (numbers) | `get_status` | `obstruction_stats` (fraction obstructed, valid-s, time obstructed) | 1 s (same call) |
| Alignment card | `get_status` | `boresight_azimuth_deg`, `boresight_elevation_deg`, `alignment_stats`, `tilt_angle` | 1 s (same call) |
| Hardware card | `get_device_info` | id, `hardware_version`, `software_version`, country code, + `mobility_class`, `class_of_service` from status | 60 s |
| History backfill on daemon start | `get_history` | per-second rings: latency, drop rate, up/down bps, `power_in[]`, `outages[]` (cause + duration), `event_log` | startup + hourly reconciliation |
| Obstruction sky map | `dish_get_obstruction_map` | `num_rows` × `num_cols` SNR grid, `min_elevation_deg`, `map_reference_frame` | 15 min + on-demand |
| Temperatures / radio | `get_radio_stats`, `get_diagnostics` | temps, bands (availability varies by model — render honestly) | 60 s |
| Outage log seed | `get_history.outages[]` | cause enum, start, duration | startup + hourly |
| GPS position (opt-in) | `get_location` | lat/lon/alt — **only works if the user enabled "allow access on local network" in the official app**; UI explains this when the call is unauthorized | 60 s when enabled |
| Config readback | `dish_get_config` | snow-melt mode, sleep schedule, level mode, location mode, swupdate prefs | 60 s + after every write |

### 4.2 Availability honesty

Some requests return errors or `not authorized` on some hardware/firmware (documented across starlink-grpc-tools; `signed_request` calls are SpaceX-reserved). Every card in the SPA has an "unavailable" render state; the daemon marks a field unavailable after 3 consecutive failed/absent reads and clears the mark on first success.

---

## 5. Dish controls

### 5.1 Control inventory

| Control | gRPC request | Confirmation | Notes |
|---|---|---|---|
| Reboot dish | `reboot` | **Typed confirm** ("dish will be offline 2–5 min") | |
| Stow / Unstow | `dish_stow` / `dish_stow{unstow:true}` | Confirm | Hidden for models without motors (e.g. Mini/HP flat) once detected via hardware version |
| Snow-melt mode | `dish_set_config{snow_melt_mode}` | None (safe) | AUTO / ALWAYS_ON / ALWAYS_OFF; paired `apply_*` bool set |
| Sleep schedule | `dish_set_config{power_save_*}` | None | start/duration in minutes past midnight **UTC** — UI converts to router-local time and says so |
| GPS enable/disable | `dish_inhibit_gps` | Confirm | |
| Clear obstruction map | `dish_clear_obstruction_map` | Confirm ("map rebuilds over ~12 h") | |
| Firmware update | `software_update` | Confirm (reboot implied) | The released `firmware-update-check` and `firmware-update-apply` aliases call this same mutating RPC; "check" is not a read-only check |
| Dish speed test | `start_speedtest` → poll `get_speedtest_status` | None | Availability varies by firmware; button shows "unsupported on this dish" when the RPC errors (§13.2) |

### 5.2 Explicitly not exposed

`dish_factory_reset` / `factory_reset` / `reset_button` (destructive, recoverable only physically), `dish_set_config.location_request_mode` writes (privacy setting belongs to the official app), all `signed_request`/`sensitive_request` calls (SpaceX-reserved, would fail anyway).

### 5.3 Audit log

Every control action is appended to the events table (§8.2) with its time, action, parameters, and result — visible in the Events card and `/api/events`.

---

## 6. WAN link management

### 6.1 Interface discovery

Find the WAN interface carrying the dish: an explicit UCI `wan_iface` override always wins; otherwise autodetect — the interface holding the route to `dish_addr`, else the mwan3/netifd interface named `wan`. Discovery re-runs periodically (60 s) so interface renames are picked up without a restart. Cellular/backup interfaces are discovered from mwan3 config when present.

### 6.2 Path probes

- ICMP (fallback UDP) probes to `probe_hosts` **bound to the Starlink WAN interface** every `probe_interval` (default 2 s), tracking RTT + loss over 30 s / 5 min windows.
- If mwan3 exists, its tracking status is read (`mwan3 interfaces` / ubus) and shown alongside — but Starwatch's own probes are the primary signal, because they run per-interface even without mwan3.
- Byte counters from `/sys/class/net/<dev>/statistics` at 1 Hz → per-WAN throughput series (this is *router-side* throughput; the dish reports its own — both are graphed, labeled distinctly).

### 6.3 Outage timeline (merged)

One timeline merging three sources, each entry tagged with its source and cause:

1. **Dish-reported outages** (`get_history.outages[]` — cause enum, e.g. obstruction / no downlink / no schedule).
2. **Dish unreachable** (gRPC failures — usually dish power loss or cabling).
3. **Path outages** (probes failing while the dish claims connectivity — upstream/CGNAT problems the dish can't see).

This three-way distinction is the tool's sharpest diagnostic and is rendered as one bar-chart timeline (§10.4).

### 6.4 mwan3 failover assist (GL.iNet & generic)

- **Read-only always:** if mwan3 is installed, show interface states, active policy, last failover events.
- **One-click assist (explicit action):** "Set up Starlink-primary / cellular-backup" writes a minimal, named mwan3 config (members, policy, default rule) after showing the exact UCI diff and getting confirmation. Never runs automatically; never touches existing custom mwan3 config (button disabled with explanation if non-Starwatch mwan3 config exists).
- **Decision:** GL.iNet's own multi-WAN UI coexists — the assist is skipped (hidden, with a note) when GL's `mwan` feature is managing failover, to avoid two writers.

---

## 7. Alerts

### 7.1 Catalog

Fixed set, each individually enable/disable-able with thresholds in UCI + Settings UI. All alerts have hysteresis/dedup: an alert fires once on entry, once on clear (`*_resolved`), never repeats while active.

| Alert | Trigger (default) | Clears when | Severity |
|---|---|---|---|
| `outage_started` | Any merged-timeline outage ≥ 30 s | Connectivity restored (also sends duration) | critical |
| `dish_unreachable` | gRPC down ≥ 60 s | First successful poll | critical |
| `path_degraded` | Probe loss > 20 % or RTT > 300 ms over 5 min | Below threshold 5 min | warning |
| `obstruction_high` | fraction obstructed > 2 % (24 h avg) | Below threshold | warning |
| `thermal_throttle` | `alerts.thermal_throttle` true | Flag clears | warning |
| `thermal_shutdown` | `alerts.thermal_shutdown` true | Flag clears | critical |
| `motors_stuck` | `alerts.motors_stuck` true | Flag clears | warning |
| `water_detected` | `alerts.dish_water_detected` true | Flag clears | warning |
| `mast_not_vertical` | `alerts.mast_not_near_vertical` true | Flag clears | info |
| `slow_ethernet` | `alerts.slow_ethernet_speeds` true | Flag clears | info |
| `firmware_pending` | software update state indicates pending install | Update applied | info |
| `failover_event` | mwan3 switched active interface | — (event, no clear) | warning |

**Decision:** the remaining `get_status.alerts` booleans (~20 total) that aren't cataloged above are surfaced in the UI's Alerts card as raw flags but don't push notifications in the initial release.

### 7.2 Delivery

- **Webhook:** POST JSON `{"alert": "outage_started", "severity": "critical", "state": "firing|resolved", "at": <unix>, "detail": {...}, "device": "<dish id>"}` with 3 retries, exponential backoff.
- **ntfy:** POST to configured URL with `Title`/`Priority`/`Tags` headers mapped from severity.
- Every fire/clear also lands in the events table → Alerts card history.

---

## 8. History & storage

### 8.1 RAM tier

Float32 ring buffers at 1 s resolution for `ram_hours` (default 3 h) covering: down/up bps (dish + router-side), latency, drop rate, power W, obstruction fraction, per-WAN probe RTT/loss. ≈ 11 k samples × ~12 series × 4 B ≈ **< 1 MB**. Live graphs and the WS feed read from here.

### 8.2 sqlite tier (`modernc.org/sqlite`, pure Go)

| Table | Row | Retention |
|---|---|---|
| `minute` | per-minute min/avg/max of each series | 7 days |
| `quarter` | per-15-min aggregates | 30 days |
| `outages` | merged-timeline entries (source, cause, start, duration) | 10 000 rows |
| `events` | alerts fired/cleared, control actions (§5.3), daemon lifecycle | 10 000 rows |
| `speedtests` | time-keyed results | 500 rows |

Backfill from `get_history` on startup fills gaps ≤ 15 min, so daemon restarts don't hole the graphs.

### 8.3 Flash-wear budget

Single transaction flush every `flush_secs` (default 300 s): ~5 minute-rows × ~12 series plus any events ≈ **a few KB per flush, ~1–2 MB/day** worst case before sqlite page reuse. Journal mode `MEMORY` with full-file fsync at flush (power-loss tolerance = lose ≤ 5 min of aggregates; RAM tier + dish backfill re-covers on restart). Acceptable on eMMC/NOR at this volume.

---

## 9. HTTP API

Bearer token (`Authorization: Bearer <token>` or `?token=` for the iframe bootstrap). Listens on `listen:port` (default `0.0.0.0:9633`). CORS disabled; the SPA is same-origin.

| Endpoint | Method | Returns |
|---|---|---|
| `/api/status` | GET | Full current snapshot: dish status, config readback, WAN states, topology, field-availability map |
| `/api/history?series=...&span=3h|7d|30d` | GET | Series data from the right tier, downsampled to ≤ 1000 points |
| `/api/obstruction-map` | GET | JSON grid + rendered PNG variant (`Accept: image/png`) |
| `/api/outages?span=` | GET | Merged outage timeline |
| `/api/events?span=` | GET | Alerts + control audit log |
| `/api/control/<action>` | POST | §5 controls; JSON body for parameters; 202 + follow-up event |
| `/api/speedtest` | POST/GET | Trigger / poll dish speed test |
| `/api/wan` | GET | Interfaces, probe stats, mwan3 state |
| `/api/wan/failover-assist` | GET/POST | GET: proposed UCI diff; POST: apply (§6.4) |
| `/api/config` | GET/PUT | Daemon settings (writes go through UCI + reload) |
| `/api/ws` | WS | 1 Hz status frames `{t, dish:{...}, wan:{...}}` + async `{event:...}` messages |

### 9.1 0.1.0 delivered phases

The expanded contracts in `API.md` shipped in risk order, with each phase
covered by an in-process fake gRPC server:

1. Diagnostics plus status GPS/PNT and disablement fields.
2. Battery configuration and derived runtime.
3. The read-only `/api/router` model.
4. Client rename through the targeted `WifiSetClientGivenName` RPC carrying
   `ClientConfig`.
5. Client block/unblock through a Starwatch-owned `WeeklyBlockSchedule` on the
   same targeted RPC.
6. Wi-Fi network and radio writes. Each network edit is rejected when any
   sibling PSK credential is redacted, so `ApplyNetworks` cannot erase an
   unseen password. Scalar writes use exactly one apply flag; channel writes
   remain withheld when firmware does not advertise a non-DFS allowed set.
7. Dashboard navigation and personalization: an icon rail groups the existing
   cards into seven sections, while Overview visibility and density stay local
   to each browser.

---

## 10. UI — one SPA, embedded twice

### 10.1 Tech & delivery

- Self-contained bundle (Preact + htm + **uPlot** for charts, all vendored — **zero external/CDN requests**; the router may be offline). Built at dev time, shipped as static files in the `starwatchd` package (`/usr/share/starwatch/www`), served by the daemon.
- Live data over `/api/ws`; graphs scroll at 1 Hz like Speedify's.
- Dark theme default matching admin-panel surroundings; light theme via `prefers-color-scheme`. Fully responsive: single column ≤ 720 px (Speedify's responsive behavior).

### 10.2 Embedding

- **LuCI** (`luci-app-starwatch`): `menu.d` entry ("Services → Starwatch" + top-level "Starwatch" tab), `rpcd` ACL exposing one call — `starwatch.token` (shell rpcd script reading UCI) — and a JS view that fetches the token and renders a full-height iframe of `http://<router>:9633/?token=…`. LuCI session = Starwatch access; token never typed by the user.
- **GL.iNet** (`gl-app-starwatch`): `oui` `menu.d` JSON entry under **Applications** + compiled view bundle (`gl-sdk4-ui-starwatch.common.js`) that reads the token via an `oui-httpd` RPC and iframes the same URL — the exact mechanism verified for wattline's GL panel app.
- Direct browser access (`http://router:9633`) shows a token prompt — for users who bookmark it.

### 10.3 Layout

The dashboard uses seven hash-routed sections behind an expandable icon rail.
Overview card visibility and compact density are browser-local preferences;
cards still auto-hide when their data source is absent.

**Status header** — dish state dot + word (Online / Obstructed / Outage / Searching / Unreachable / WAN-only), uptime, current down/up rate, latency, topology badge. This is the "big Speedify toggle" position, minus the toggle (nothing to toggle — monitoring is always on).

### 10.4 Card inventory

| Card | Contents | Source |
|---|---|---|
| **Live graphs** | Tabbed like Speedify (Throughput / Latency / Loss / Power), uPlot scrolling, span picker 15 m · 3 h · 24 h · 7 d · 30 d; dish-side vs router-side throughput as separate labeled series | §4.1, §8 |
| **Obstruction** | Fraction obstructed, time obstructed, sky-map render (SNR grid as polar plot), "clear map" action | `obstruction_stats`, `dish_get_obstruction_map` |
| **Outage timeline** | Merged three-source timeline bars with cause tooltips + table of recent outages with durations | §6.3 |
| **Alignment** | Compass-style azimuth/elevation/tilt readout | boresight fields |
| **Power** | Instant/min/mean/max W + 24 h area chart + kWh/day derived; optional user-configured battery capacity/SOC/reserve/efficiency yields the clearly labeled runtime estimates and SOC-staleness behavior defined in `API.md` | `power_in` + local battery settings |
| **WAN health** | Per-WAN cards (Starlink, cellular, …): probe RTT/loss sparkline, state, byte counters; mwan3 status + failover-assist button when applicable | §6 |
| **Controls** | Snow melt (3-state), sleep schedule editor (local-time UI, UTC stored), GPS toggle, stow/unstow, reboot, firmware update — confirmation-gated per §5.1 | §5 |
| **Speed test** | Run button, latest + history table | §5.1, `speedtests` |
| **Alerts** | Active raw dish flags + Starwatch alert history; link to settings | §7 |
| **Hardware** | Model (friendly name mapped from `hardware_version`), firmware, dish id, country, mobility class, temperatures when available | §4.1 |
| **Starlink router** (topology B only) | Clients with full MAC/IP/signal/SNR/rates, ping health, radios, temperatures, Ethernet/bridge/interfaces, plus the guarded `API.md` write surface: targeted client rename, schedule-based block/unblock, real transmit-power enums, and credential-readback-gated network edits | router gRPC :9000 |
| **Settings** | Token display/regenerate, dish address, probe hosts, alert thresholds + webhook/ntfy config with "send test", history retention | §2.1 |

---

## 11. Failure modes & edge cases

| Situation | Behavior |
|---|---|
| Dish unreachable at startup | Topology C: WAN-only mode, retry every 60 s, setup hint card (check bypass mode / host route) |
| Dish rebooting (user-initiated) | Expected-outage window: `dish_unreachable` alert suppressed for 5 min after our own reboot command |
| Unknown/new dish model | Parse what's present; unavailable-field machinery (§4.2) handles the rest; hardware card shows raw `hardware_version` string |
| Router clock wrong at boot (common: no RTC) | History writes deferred until time is sane (year ≥ 2025 or NTP synced); dish `get_history` backfill re-anchors sample times |
| sqlite corruption | Detect on open → move aside, recreate, event logged; RAM tier unaffected |
| Token leaked / regenerate | Settings action regenerates UCI token; LuCI/GL embeds pick it up on next load |
| opkg same-version reinstall no-op | Documented: bump VERSION or `--force-reinstall` (wattline-verified) |
| GL firmware upgrade wipes packages | Documented recovery: re-install from feed; `/etc/starwatch/` (config + history) survives with "keep settings" |

---

## 12. Packaging, install, service

All wattline-verified mechanics carry over unchanged:

- **`.ipk` format:** outer **gzipped tar** (never `ar` — opkg segfaults), members **ustar** (`--format ustar`; BSD tar pax headers rejected). Built by `package/Makefile`, no OpenWrt SDK.
- **Packages:**
  - `starwatchd_<v>_aarch64_cortex-a53.ipk` — daemon, procd init, UCI defaults + token generator, SPA assets, postinst enables + **restarts** service (upgrade picks up new binary).
  - `luci-app-starwatch_<v>_all.ipk` — menu.d + rpcd ACL + iframe view.
  - `gl-app-starwatch_<v>_all.ipk` — oui menu.d + compiled view bundle.
- **Feed:** `make -C package VERSION=x.y.z feed` → `package/out/{*.ipk, Packages, Packages.gz}`; host anywhere HTTP; router adds one `customfeeds.conf` line; upgrades via `opkg upgrade` / GL Plug-ins page. Version must be bumped in lockstep (Makefile injects it into control, filename, index — wattline-verified on GL-X3000).
- **Dev install:** pipe over ssh (`cat > /tmp/… `) since dropbear lacks scp — documented one-liner.
- **Dependencies:** none beyond OpenWrt base (static Go binary; no bluez-equivalent this time). mwan3 optional.

---

## 13. Open questions

1. **§10.2 iframe vs. served-through-LuCI:** iframing `:9633` fails if the browser can't reach that port (strict firewall zones, remote access via VPN with port restrictions). Fallback option: uhttpd reverse-proxy stanza. Ship iframe-first, revisit if reports come in.
2. **§5.1 dish speed test reliability:** `start_speedtest`/`get_speedtest_status` availability varies by firmware; if too flaky in practice, add a daemon-run HTTP throughput test (against user-configured endpoint) as a future fallback.
3. **§2.1 history DB location:** `/etc/starwatch/` survives sysupgrade but sits on the config partition; if 30-day DBs prove larger than expected on small-flash devices, move default to `/overlay` data dir with a settings toggle.

## 14. Future candidates

Card reordering with persisted layout · rules engine (condition→action,
wattline-style) · Prometheus `/metrics` exporter + MQTT publish (Home
Assistant) · obstruction-map time-lapse · multi-dish support · daemon-run speed
test fallback · CSV/JSON export buttons · public REST docs page.

---

*End of spec.*
