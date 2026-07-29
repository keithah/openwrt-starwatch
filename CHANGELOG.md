# Changelog

## Unreleased

## 0.1.6 — 2026-07-27

- Fixes the API listener being unreachable over IPv4 on routers whose kernel
  advertises dual-stack support (`net.ipv6.bindv6only=0`) but doesn't
  actually deliver IPv4-mapped connections to it. `listen '0.0.0.0'` now
  binds an explicit IPv4 socket instead of relying on Go's wildcard
  auto-detection to pick a working dual-stack socket.

## 0.1.5 — 2026-07-27

- Fixes feed migration failing installation on routers whose BusyBox build
  omits the `stat` applet (observed on GL-X3000), by falling back to parsing
  `ls -ln` to preserve config and key file ownership/permissions.

## 0.1.4 — 2026-07-24

- Makes package installation safe on GL firmware by avoiding network reloads
  and destructive procd restarts while opkg is configuring packages.
- Defers service startup to boot when ubus is unhealthy instead of damaging
  the router control plane.

## 0.1.3 — 2026-07-24

- Fixes fresh installs failing to generate the initial API token under the
  post-install script's `set -e` mode.

## 0.1.2 — 2026-07-20

- Reduces dashboard render churn by caching derived history data and avoiding
  unnecessary sky-map, outage, and event redraw work.
- Avoids redundant 15-minute battery power queries and repeated chronological
  history sorting.
- Adds short-lived browser caching for embedded static dashboard assets.

- Sanitizes non-finite dish telemetry before REST or WebSocket encoding, so a
  degraded link cannot truncate status JSON or force one-second reconnects.
- Uses crash-safe SQLite WAL/FULL mode with a busy timeout, bounds pre-NTP
  pending data, follows configured history retention, and fsyncs UCI file and
  directory updates before reporting success.
- Persists alert/failover runtime state, resolves active rules when disabled,
  isolates webhook and ntfy workers, redacts endpoint secrets, and stops
  retrying terminal HTTP 4xx responses.
- Restricts query-string API tokens to the WebSocket endpoint, moves LuCI token
  retrieval to write ACL scope, and adds an idle timeout without imposing a
  WebSocket-breaking write timeout.
- Retains last-good MWAN state on ubus failures, serializes `mwan3 reload`,
  resolves hostname probes before ICMP, and bounds dish speed-test status RPCs.
- Makes UCI apostrophe escaping round-trip safe, rejects line-breaking delivery
  URLs and non-persistable rule edits, and invokes live config callbacks outside
  the manager lock.
- Hardens the SPA for empty API responses, WebSocket authorization failures,
  partial settings, blank numeric inputs, stable list identity, and null chart
  gaps; buffers obstruction PNGs before committing response headers.

## 0.1.1 — 2026-07-18

- Makes dashboard telemetry strictly dish-gRPC sourced, with no router-counter
  or WAN-probe fallback. When the terminal is unreachable, the dashboard shows
  an explicit Starlink-disconnected state and hides every current-data card.

## 0.1.0 — 2026-07-17

- Adds diagnostic summaries, GPS/PNT and disablement status fields, and
  configured battery runtime estimates.
- Adds the topology-B Starlink-router read model, client rename and
  schedule-based block/unblock controls.
- Adds guarded Wi-Fi and radio configuration: scalar writes are narrowly
  applied, while network edits refuse to proceed if the router does not return
  every sibling PSK credential needed to preserve it.
- Adds a topology-B Wi-Fi editor, client-management card, self-healing
  VPN-proof dish host-route handling, and an icon-rail dashboard with local
  Overview visibility and density preferences.
- Adds a one-line, architecture-checked installer that selects the GL.iNet or
  LuCI integration without overwriting other custom feeds or local settings.
- Publishes the three 0.1.0 packages and signed opkg index through GitHub Pages
  after race tests, vet, the ARM64 build, and package checks pass. The installer
  pins the dedicated feed key without disabling OpenWrt signature checks.
- Adds desktop and mobile dashboard screenshots and aligns the public API,
  product specification, package metadata, and release notes on version 0.1.0.
