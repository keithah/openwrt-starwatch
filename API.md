# Starwatch HTTP API

This document defines the token-authenticated API served by `starwatchd`. It
documents the released 0.1.0 surface, including diagnostics, battery, and
curated Starlink-router management.

Installation, package selection, and opkg feed instructions live in the
project README; this document is the wire contract after the daemon is running.

Starwatch is local-network-first. It does not use a Starlink account or cloud
API, and it does not claim account, billing, activation, plan, or global outage
state.

## Conventions

- The default origin is `http://<router>:9633`.
- Every `/api/*` route requires `Authorization: Bearer <token>`.
- `?token=<token>` is also accepted for browser and WebSocket bootstrap. Clients
  should avoid it elsewhere because URLs are commonly logged.
- JSON request bodies generally reject unknown fields and have a 128 KiB limit.
  `POST /api/control/{action}` is an exception: it accepts unknown fields and
  has a 64 KiB limit. Every PATCH handler must call
  `json.Decoder.DisallowUnknownFields` and enforce the 128 KiB limit.
- Date-time values are RFC 3339 strings unless a field is explicitly named `*_ns` or
  `*_seconds`.
- Rates use bits per second, durations use nanoseconds, power uses watts,
  temperatures use degrees Celsius, and radio rates use megabits per second.
- Missing data is omitted or represented by an availability object. A numeric
  zero is never used to mean unavailable.
- Existing errors are UTF-8 `text/plain`. The principal endpoint-specific
  codes are `400` invalid input, `401` authentication failure, `409` conflicting
  state, `502` upstream gRPC failure, and `503` unavailable component.
- Mutation success codes are endpoint-specific. Dish controls,
  speed-test start, and alert-test enqueue return `202`; config PUT, failover
  assist POST, and token regeneration return `200`. A `202` means the
  immediate operation was accepted or its upstream call returned without error.
  The router mutation endpoints are deliberately stronger: their documented
  `202` is returned only after the required configuration or live-client
  readback confirms the requested change.

## Authentication

```http
GET /api/status HTTP/1.1
Authorization: Bearer <token>
```

An empty configured token denies every API request. `POST
/api/config/regenerate-token` returns a replacement once and invalidates the old
token immediately.

## Released endpoints

### `GET /api/status`

Returns the current dish, topology, configuration readback, Starlink-router
summary, WAN summary, location (when opted in), and field availability.

Availability values have this shape:

```json
{
  "available": false,
  "reason": "needs local-access opt-in in the official Starlink app"
}
```

The response may contain:

```json
{
  "topology": "full",
  "dish_reachable": true,
  "dish": {
    "updated_at": "2026-07-16T21:00:00Z",
    "uptime_seconds": 12345,
    "latency_ms": 24.2,
    "drop_rate": 0.002,
    "downlink_throughput_bps": 8200000,
    "uplink_throughput_bps": 900000,
    "power_w": 46.8,
    "power_source": "history"
  },
  "device_info": {
    "id": "ut...",
    "hardware_version": "mini1_panda_prod1",
    "software_version": "...",
    "country_code": "US"
  },
  "config": {
    "snow_melt_mode": "AUTO",
    "power_save_mode": false,
    "power_save_start_minutes": 0,
    "power_save_duration_minutes": 0
  },
  "starlink_router": {
    "reachable": true,
    "hardware_version": "v4",
    "software_version": "...",
    "client_count": 2,
    "uptime_seconds": 5400
  },
  "field_availability": {
    "status": {"available": true},
    "location": {"available": false, "reason": "location polling disabled"}
  }
}
```

`power_source` is `status` only for a positive `upsu_stats.dish_power` reading.
It is `history` when the newest positive `get_history.power_in` sample is used.

### `GET /api/history?series=<name>&span=<span>`

Returns at most 1000 ordered points. Supported spans are `15m`, `3h`, `24h`,
`7d`, and `30d`. The selected tier is `ram`, `minute`, or `quarter`.

```json
{
  "series": "power_w",
  "span": "24h",
  "tier": "minute",
  "points": [
    {"time": "2026-07-16T20:00:00Z", "value": 45.2, "min": 42.1, "max": 49.8}
  ]
}
```

Current series are `latency_ms`, `drop_rate`, `dish_down_bps`, `dish_up_bps`,
`power_w`, `obstruction_fraction`, `wan_probe_rtt_ms`, `wan_probe_loss`,
`router_down_bps`, and `router_up_bps`. Every point uses the `time` key shown
above.

### `GET /api/wan`

Returns the Starlink WAN interface, state, router-side rates, 30-second and
5-minute probe windows, and optional read-only mwan3 state.

### `GET /api/outages?span=<span>`

Returns at most 1000 merged dish, `dish_unreachable`, and path entries:

```json
[
  {
    "source": "dish",
    "cause": "OBSTRUCTED",
    "start": "2026-07-16T20:00:00Z",
    "duration": 11000000000,
    "ongoing": false
  }
]
```

### `GET /api/events?span=<span>`

Returns daemon lifecycle, alert, control, speed-test, and configuration audit
events. `detail` is a JSON string for forward-compatible event-specific fields.

### `GET /api/obstruction-map`

Returns the current obstruction grid as JSON. `Accept: image/png` returns a
rendered polar-friendly source image. The endpoint refreshes an absent or stale
map inline and returns `503` when the dish is unreachable.

### `GET /api/speedtest` and `POST /api/speedtest`

The GET state is `idle`, `running`, `done`, `unsupported`, or `error`. POST
starts one test; a concurrent POST returns `409`.

### `POST /api/control/{action}`

Current canonical actions are `reboot`, `stow`, `unstow`, `snow-melt`,
`sleep-schedule`, `gps`, `gps-enable`, `gps-disable`,
`clear-obstruction-map`, and `firmware-update`. The aliases `snow-melt-mode`,
`sleep`, and `software-update` are also accepted. `firmware-update-check` and
`firmware-update-apply` are deprecated aliases: both invoke the same
`software_update` RPC as `firmware-update`; “check” is not a safe no-op query.
Every action is audited. The generic `gps` action requires an explicit
`enabled` boolean.

### `GET|POST /api/wan/failover-assist`

GET returns availability, refusal reason, and the exact proposed UCI changes.
POST applies only explicitly named `starwatch_*` mwan3 sections and then rereads
status. It refuses GL.iNet-managed multi-WAN and non-pristine custom mwan3
configurations.

### `GET|PUT /api/config`

GET returns daemon settings with the token masked. PUT accepts partial updates
only for safe live-managed fields. Listen address, port, token, `dish_addr`,
`poll_status`, `wan_iface`, `ram_hours`, `db_path`, and `flush_secs` remain
restart-managed.

### `POST /api/config/regenerate-token`

Persists a cryptographically random token, activates it immediately, and
returns it once as `{"token":"..."}`.

### `POST /api/alerts/test`

Queues a test notification through configured webhook and ntfy delivery.

### `GET /api/ws`

Sends one-Hz frames containing `t`, `dish`, and `wan`, plus asynchronous
`event` messages. Slow clients are disconnected when their bounded queue fills.

## Diagnostics and battery (0.1.0)

### Additions to `GET /api/status`

Dish status gains satellite/GPS context when exposed by the local API:

```json
{
  "dish": {
    "gps": {
      "valid": true,
      "satellites": 14,
      "inhibited": false,
      "no_satellites_after_ttff": false,
      "pnt_filter_state": "FILTER_CONVERGED"
    },
    "seconds_to_first_nonempty_slot": 0.8,
    "disablement_code": "OKAY"
  }
}
```

`pnt_filter_state` is the protobuf `AttitudeEstimationState`: `FILTER_RESET`,
`FILTER_UNCONVERGED`, `FILTER_CONVERGED`, `FILTER_FAULTED`, or `FILTER_INVALID`.
It describes the receiver's PNT/attitude filter, not a GPS-lock state. These
fields provide receiver context only; Starwatch does not claim to expose the
identity or orbital position of the currently serving Starlink satellite.

### `GET /api/diagnostics?span=<span>`

Returns derived summaries for the dashboard. Supported spans match history.
Calculations ignore unavailable/non-finite samples and return an availability
reason when no valid sample exists.

```json
{
  "span": "24h",
  "latency": {
    "approximate": true,
    "current_ms": 24.2,
    "mean_ms": 27.1,
    "p95_ms": 44.8,
    "max_ms": 102.4,
    "router_ms": 3.1,
    "distribution": [
      {"upper_bound_ms": 20, "count": 340},
      {"upper_bound_ms": 40, "count": 902},
      {"upper_bound_ms": null, "count": 4}
    ]
  },
  "ping": {
    "dish_success": 0.998,
    "router_success": 1.0,
    "wan_success_30s": 1.0,
    "wan_success_5m": 0.996,
    "seconds_since_router_success": 0
  },
  "outages": {
    "count": 3,
    "downtime_ns": 21000000000,
    "longest_ns": 11000000000
  },
  "power": {
    "current_w": 46.8,
    "mean_w": 45.2,
    "min_w": 41.7,
    "max_w": 51.3,
    "kwh_per_day": 1.0848,
    "source": "history",
    "snow_melt_mode": "AUTO",
    "sleep_enabled": false
  },
  "battery": {
    "configured": true,
    "capacity_wh": 1024,
    "state_of_charge_percent": 76,
    "reserve_percent": 10,
    "conversion_efficiency_percent": 90,
    "load_window": "15m",
    "load_w": 45.5,
    "full_charge_runtime_hours": 18.23,
    "remaining_runtime_hours": 13.37,
    "state_of_charge_updated_at": "2026-07-16T20:00:00Z",
    "state_of_charge_stale": false,
    "derived": true
  }
}
```

Ping success is `1 - drop_rate`, clamped to `[0,1]`. It is labeled by source;
Starwatch never presents dish, router, WAN, or DNS reachability as interchangeable.
No DNS success value is emitted unless a real DNS-specific signal is available.

Latency percentiles use raw RAM samples for spans within RAM retention and
persisted aggregate values for longer spans. A long-span percentile is therefore
an approximation and is labeled `approximate: true`.

Latency distribution buckets are inclusive at 20, 40, 60, 80, 100, 150, 200,
and 500 milliseconds. The final open bucket has `upper_bound_ms: null`.

Outage totals merge only intervals inside the requested span and do not double
count overlapping representations of the same outage.

## Battery configuration

`GET /api/config` returns:

```json
{
  "battery": {
    "enabled": true,
    "capacity_wh": 1024,
    "state_of_charge_percent": 76,
    "reserve_percent": 10,
    "conversion_efficiency_percent": 90,
    "state_of_charge_updated_at": "2026-07-16T20:00:00Z"
  }
}
```

`PUT /api/config` accepts the same partial `battery` object. Bounds are:

- `capacity_wh`: greater than 0 and at most 100000.
- `state_of_charge_percent`: 0 through 100.
- `reserve_percent`: 0 through 95 and lower than state of charge for a positive
  remaining-runtime estimate.
- `conversion_efficiency_percent`: 1 through 100.

The runtime calculation uses the rolling 15-minute mean positive terminal power:

```text
usable_wh = capacity_wh * max(0, state_of_charge - reserve) / 100
            * conversion_efficiency / 100
remaining_runtime_hours = usable_wh / load_w
```

Full-charge runtime uses `100 - reserve`. Power-derived estimates are hidden
when power telemetry is stale, the clock is insane, or there is no positive
power sample. `remaining_runtime_hours` is additionally omitted and its
availability reason reports stale SOC when `state_of_charge_updated_at` is more
than 24 hours old; `state_of_charge_stale` is then `true`. A stale SOC does not
hide `full_charge_runtime_hours`, which does not depend on the entered SOC.
These estimates describe the configured battery powering the Starlink terminal
only—not the GL router, other loads, battery voltage behavior, temperature,
aging, or charge input. Starwatch's runtime estimate is an added derived feature;
StarBar reports power but explicitly does not estimate battery runtime.

UCI persistence uses a dedicated `config battery` section. Unknown UCI content
continues to be preserved.

## Starlink-router telemetry and guarded writes (0.1.0)

### `GET /api/router`

Returns `503` when topology B is absent or the Starlink router is unreachable.
The payload is a typed, local JSON model; protobuf messages are never embedded.

```json
{
  "reachable": true,
  "updated_at": "2026-07-16T21:00:00Z",
  "config_revision": "incarnation:42",
  "device": {
    "id": "Router-...",
    "hardware_version": "v4",
    "software_version": "...",
    "uptime_seconds": 5400,
    "wan_ipv4": "192.168.1.1",
    "no_wan_link": false
  },
  "ping": {
    "latency_mean_ms": 3.1,
    "latency_stddev_ms": 0.8,
    "latency_mean_ms_5m": 3.4,
    "latency_mean_ms_1h": 4.0,
    "drop_rate": 0,
    "drop_rate_5m": 0,
    "drop_rate_1h": 0.001,
    "seconds_since_last_success": 0,
    "derived": true
  },
  "networks": [
    {
      "domain": "lan",
      "ipv4": "192.168.1.1/24",
      "ipv6": [],
      "clients_ethernet": 1,
      "clients_2ghz": 0,
      "clients_5ghz": 1,
      "basic_service_sets": [
        {
          "ssid": "Starlink",
          "bssid": "00:11:22:33:44:55",
          "band": "RF_5GHZ",
          "interface": "wlan0",
          "security": "WPA2_WPA3",
          "credential_set": true,
          "hidden": false,
          "disabled": false
        }
      ]
    }
  ],
  "clients": [
    {
      "mac": "aa:bb:cc:dd:ee:ff",
      "name": "laptop",
      "given_name": "Work Mac",
      "ipv4": "192.168.1.20",
      "ipv6": [],
      "active": true,
      "blocked": false,
      "interface": "CLIENT_5GHZ",
      "interface_name": "wlan0",
      "signal_dbm": -52,
      "snr_db": 39,
      "mode": "11ax",
      "channel_width_mhz": 80,
      "associated_seconds": 1200,
      "rx": {"rate_mbps": 866, "throughput_mbps_15s": 12.4, "bytes": 1234},
      "tx": {"rate_mbps": 720, "throughput_mbps_15s": 2.1, "bytes": 5678},
      "ping": {"latency_ms_5m": 4.2, "drop_rate_5m": 0}
    }
  ],
  "radios": [
    {
      "band": "RF_5GHZ",
      "channel": 149,
      "channel_width_mhz": 80,
      "disabled": false,
      "tx_power_level": "TX_POWER_LEVEL_100",
      "rx_bytes": 1234,
      "tx_bytes": 5678,
      "temperature_c": 51.2,
      "thermal_throttled": false
    }
  ],
  "interfaces": [],
  "availability": {
    "radio_stats": {"available": true},
    "diagnostics": {"available": true},
    "wifi_config": {"available": true}
  }
}
```

Full client MAC addresses are intentionally returned to authenticated local
administrators. The UI does not transmit them elsewhere.

`domain` is the network identifier. A BSS reports `bssid`, `ssid`, and `band`;
`bssid` may be an empty string in config-only readback and is never synthesized,
so it is not a write key. Wi-Fi mutations select a BSS by its `{ssid, band}`
pair.
Router ping fields are derived from router status and history. A ping success is
a finite sample with `drop_rate < 1`; the one-hour fields are omitted and their
availability is false when the router history buffer does not cover one hour.

Router status, clients, ping metrics, diagnostics, configuration, and radio
statistics are polled every 60 seconds. Each subfield follows the existing
three-consecutive-failures availability rule.

## Curated Starlink-router writes (0.1.0)

All router mutations:

1. Require topology B and a reachable Starlink router.
2. Require the latest `config_revision` from `GET /api/router`. Immediately
   before every write, Starwatch rereads router configuration and compares its
   `incarnation` with the supplied revision; a mismatch returns `409` without
   writing. Because the displayed revision can be up to 60 seconds old and no
   atomic compare-and-swap is known, this is a best-effort concurrency guard:
   the targeted RPC is not known to enforce `incarnation` server-side.
3. A mutation that uses `wifi_set_config` sets only the exact paired `apply_*`
   flag for the requested setting. Scalar writes contain only their requested
   value. Aggregate flags such as
   `ApplyNetworks`, `ApplyClientNames`, and `ApplyClientConfigs` replace whole
   collections and therefore risk destroying omitted state. Network writes may
   use `ApplyNetworks` only under the credential-readback gate below; client
   writes use the targeted RPC and never resend either client collection. No
   unrelated apply flag is set.
4. Reread configuration and compare every requested field before returning
   `202`. A mismatch is an upstream failure and must not be reported as
   accepted.
5. Append a `router_control` audit event containing action, non-secret
   parameters, result/error, and affected network/client identifiers.
6. Publish the audit event over `/api/ws`.
7. Never log, persist, echo, or publish a Wi-Fi passphrase. Full client MAC
   addresses are non-secret identifiers and do persist in `router_control`
   audit events and sqlite when they identify the affected client.

Every PATCH body rejects unknown fields and is limited to 128 KiB. In
addition to the released error codes, these endpoints use `422` for a known but
unsupported or unsafe-on-this-router value.

### `PATCH /api/router/wifi`

Accepts one or more safe partial updates:

```json
{
  "config_revision": "incarnation:42",
  "confirmation": "APPLY WIFI CHANGES",
  "network": {
    "ssid": "Starlink Cabin",
    "band": "RF_5GHZ",
    "new_ssid": "Starlink Studio",
    "security": "WPA2_WPA3",
    "passphrase": "write-only replacement",
    "hidden": false,
    "disabled": false
  },
  "radio": {
    "band": "RF_5GHZ",
    "enabled": true,
    "channel": 149,
    "channel_width_mhz": 80,
    "tx_power_level": "TX_POWER_LEVEL_100"
  },
  "band_steering_enabled": true,
  "outdoor_mode": false,
  "dns": {
    "servers": ["1.1.1.1", "8.8.8.8"],
    "secure": false
  }
}
```

Every top-level member is optional except `config_revision` and `confirmation`.
At least one mutation must be present. A `network` edit selects exactly one BSS
with its current non-empty `{ssid, band}` pair; `new_ssid` is the optional
rename value. The API never accepts a fictional network ID or runtime `bssid`
as a selector. Allowed security modes map directly to the BSS `Auth` oneof:
`OPEN` → `AuthOpen`, `WPA2` → `AuthWpa2`, `WPA3` → `AuthWpa3`, and `WPA2_WPA3`
→ `AuthWpa2Wpa3`. A PSK is the selected auth arm's `Password`; an open network
requires the stronger confirmation `CREATE OPEN NETWORK`. A supplied passphrase
is accepted only for PSK security and must satisfy upstream length constraints.

**BLOCKING precondition for network writes:** the only protobuf write is
`ApplyNetworks`, which replaces the entire networks collection; there is no
per-network or per-BSS apply flag. Network mutation must not ship until
on-device testing on every supported firmware family proves `wifi_get_config`
returns every live BSS credential needed to reconstruct the collection. If any
credential is redacted or omitted, Starwatch withholds network writes rather
than relying on omission to preserve it. Passphrases remain write-only at the
HTTP boundary even when upstream readback provides them internally.

The API exposes only:

- SSID, PSK security, write-only passphrase, hidden state, and enable state.
- 2.4 GHz, 5 GHz, and 5 GHz-high enablement.
- Band steering.
- Channels only when the candidate appears in the router-advertised supported
  non-DFS set; if no such set is available, manual channel writes are withheld.
- Channel widths mapped for the selected band: integer `20` → that band's
  `HT_BANDWIDTH_20_MHZ`, `40` → `HT_BANDWIDTH_20_OR_40_MHZ`, `80` → the
  selected 5 GHz band's `VHT_BANDWIDTH_80_MHZ`, and `160` →
  `VHT_BANDWIDTH_160_MHZ`. The 2.4 GHz band accepts only the HT widths. A width
  not supported by that band/router returns `422` without writing; `80+80` is
  not exposed by this integer contract.
- Per-band `tx_power_level` accepts only the real enum names
  `TX_POWER_LEVEL_100`, `_80`, `_50`, `_25`, `_12`, and `_6`, mapped through
  `ApplyTxPowerLevel_2Ghz`, `_5Ghz`, or `_5GhzHigh`.
- Outdoor mode through `ApplyOutdoorMode`, confirmation-gated and only when the
  router reports support. Starwatch relies on firmware regional enforcement;
  DFS enablement remains excluded below.
- Static DNS servers and secure-DNS toggle.

If a model/firmware does not expose a setting, Starwatch returns `422` and leaves
configuration untouched.

### `PATCH /api/router/clients/{mac}`

```json
{
  "config_revision": "incarnation:42",
  "confirmation": "RENAME CLIENT",
  "given_name": "Work Mac"
}
```

Each request makes exactly one client mutation: rename or block state. The path
MAC is normalized to lowercase colon notation and must match a client from the
latest router snapshot. Wi-Fi/radio fields remain rejected with `422` until
Phase 6.

Rename requires the exact `RENAME CLIENT` confirmation and a non-empty
`given_name`. Blocking requires `blocked:true` with exact `BLOCK CLIENT`;
unblocking requires `blocked:false` with exact `UNBLOCK CLIENT`:

```json
{
  "config_revision": "incarnation:42",
  "confirmation": "BLOCK CLIENT",
  "blocked": true
}
```

Rename uses the targeted `WifiSetClientGivenName` request (request oneof field
3017) carrying the current `ClientConfig` form. Before writing, Starwatch
rereads the addressed client and preserves `mac_address`, `client_id`, `group_id`,
and `weekly_block_schedules`. It does not use the deprecated `ClientName`
payload, `ApplyClientNames`, or the atomic `ApplyClientConfigs` collection. A
firmware that does not implement the targeted naming RPC returns `422` rather
than silently using a deprecated or collection-replacement path.

For blocking, Starwatch uses that same targeted RPC with a read-merged
`ClientConfig`, never `ApplyClientConfigs`. It adds exactly one owned weekly
schedule tagged `group_id:"starwatch-block"`, with its sole block range encoded
as `start_minutes:0`, `end_minutes:10080` (minutes of week; the protobuf has no
day field). Unblock removes only that tag and preserves user schedules. If the
live client is blocked while a non-Starwatch schedule exists, Starwatch returns
`409` rather than claiming it removed a user-managed block.

Starwatch rereads both configuration and clients after the RPC and returns `202`
only when config and live `WifiClient.Blocked`/name state confirm the requested
mutation. A failed confirmation returns `502`.
The incarnation comparison immediately before the write minimizes, but cannot
eliminate, the TOCTOU window because the target RPC is not known to perform an
atomic server-side incarnation check. Successful readback-confirmed mutations
append and publish a secret-free `router_control` audit event containing action,
normalized MAC, result, and client ID (plus `given_name` for rename).

## Explicitly excluded router writes

Starwatch will not expose these even though related protobuf fields or RPCs
exist:

- Factory reset, setup-complete state, calibration, self-test/factory-test, and
  debug commands.
- Country code, regulatory pinning, aviation, overflight, or custom radio power
  tables.
- Bypass, AP, repeater, umbilical VLAN, unbridged Ethernet, WAN traffic control,
  firewall, DHCP, static routes, or HTTP-server configuration.
- Mesh trust, mesh topology/onboarding, dynamic keys, client keys, RADIUS, or
  enterprise/onboarding authentication.
- `DisableSetWifiConfigFromController` (`1090`), which can lock out the
  controller write path.
- Sandbox controls (`SandboxEnabled`, `SandboxId`,
  `SandboxDomainAllowList`, and `ApplyDisableSandboxFailOpen` `1116`).
- DFS enablement (`ApplyDfsEnabled` `1058`), arbitrary DFS channels, and custom
  regulatory behavior. Manual channels are limited to the router-advertised
  non-DFS set described above.
- Arbitrary protobuf passthrough.

These exclusions prevent Starwatch from stranding the upstream router, altering
regulatory state, or becoming a general Starlink-router administration clone.
The official Starlink application remains the recovery and advanced-management
authority.

## Dashboard additions (0.1.0)

The SPA includes:

- Ping-success values and source-labeled dish/router/WAN checks.
- Latency current/mean/P95/max, distribution, and router-vs-dish context. The
  percentile/distribution analysis exceeds StarBar's latency and ping-success
  display and is labeled approximate where aggregate tiers are used.
- Outage count, total downtime, longest outage, timeline, and recent table.
- Power current/min/mean/max, 24-hour chart, kWh/day, snow-melt/sleep state,
  source badge, and the optional derived battery-runtime panel.
- Satellite/GPS receiver context without claiming satellite identity.
- Topology-B cards in the Controls section with full client MAC/IP/name,
  band/interface, signal, SNR,
  link/throughput rates, traffic counters, lease/activity state, and ping health.
- A Radios & Interfaces view with bands, channels, widths, temperatures,
  traffic, Ethernet, bridge, WAN, and partial-telemetry reasons.
- A guarded Wi-Fi editor and client rename/schedule-based block controls using
  the mutation contracts and network-write gate above.
- Seven hash-routed dashboard sections behind an expandable icon rail. Overview
  card visibility and compact density are browser-local preferences; they do
  not alter daemon configuration or telemetry collection.

The page remains fully offline, uses relative daemon URLs only, and hides cards
whose entire data source is absent. Individual missing fields render `—` with an
availability reason rather than a fabricated zero.

## Verification requirements for 0.1.0

- Fake gRPC coverage for every new read and write request type.
- Tests asserting exact `apply_*` flags and absence of unrelated apply flags.
- Tests proving passphrases never appear in responses, events, logs, or sqlite.
- On-device credential-readback verification for each supported firmware family
  before enabling any `ApplyNetworks` write; redaction keeps the feature off.
- Stale-revision, unsupported-field, confirmation, validation, readback-mismatch,
  and upstream-error tests.
- Battery formula, stale-SOC, zero-load, invalid-clock, bounds, and UCI
  round-trip tests.
- Statistical tests for percentile boundaries, approximate long-tier behavior,
  ping-success clamping, and overlapping outage totals.
- UI pure-logic harness coverage for runtime estimates, summary assembly,
  availability decisions, MAC/client rendering, and safe write payloads.
- `go test -race ./...`, `go vet ./...`, static Linux ARM64 build, package build,
  and read-only live verification on topology B.
- No live Wi-Fi mutation during automated or deployment verification. A chosen
  on-device Wi-Fi change requires separate explicit approval and a recovery plan.
