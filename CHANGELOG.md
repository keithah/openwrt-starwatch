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
