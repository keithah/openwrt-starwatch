# Changelog

## Unreleased

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
