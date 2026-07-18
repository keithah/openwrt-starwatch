# Changelog

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
