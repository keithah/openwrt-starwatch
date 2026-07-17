# Wattline Optional LAN/VPN Transport — Design

## Scope

Add an optional router-backed source for the Wattline iOS and macOS apps. Bluetooth remains the primary transport; Demo remains available everywhere. The first version uses explicit user selection of a discovered or manually entered router and does not perform automatic failover.

The compatibility target is the shipped `wattlined` HTTP API in `keithah/openwrt-wattline`: bearer-authenticated `/api/v1/status`, `/api/v1/telemetry`, `/api/v1/events` (SSE), device actions, USB-C limits, bypass threshold, schedules, and pairing routes. The repository's `docs/API.md` remains the BLE protocol reference and is not treated as a REST contract.

## Package boundary

`WattlineNetwork` is a new SPM package that depends on `WattlineCore` only. URLSession, SSE parsing, NWBrowser, Network.framework, TLS policy, and router discovery live exclusively in this package. WattlineCore remains platform/model/codec/transport-only and imports no networking or UI frameworks. WattlineUI remains unchanged except for transport labels and structurally gated connection surfaces in the app layer.

`RouterTransport` conforms to `DeviceTransport`. It owns one serialized request path and one SSE subscription per selected router. The app's existing owner model remains intact: AppModel/MacAppModel owns the transport instance; the transport never creates another BLE session.

## Connection and telemetry

1. `connect` performs an authenticated `GET /api/v1/status`.
2. The status identity (`model`, `hw_rev`, `firmware`, `mac`, `cid`, `features`) becomes `DeviceIdentitySnapshot`; capability resolution uses the existing FEATURES→CID→model resolver, supplemented by an endpoint capability map returned by the router adapter.
3. The transport opens authenticated `GET /api/v1/events` and parses SSE `data:` frames as router snapshots. The initial frame is accepted as telemetry.
4. `connected`, battery, DC, and Type-C events are emitted from each accepted snapshot. `connected=false`, HTTP failure, malformed frames, or stream termination produce reconnecting/disconnected state and stale telemetry; reconnect uses bounded backoff and generation tokens so old streams cannot publish into a new connection.
5. Every mutation waits for authoritative SSE telemetry before the existing `MutationReconciler` reports success. No optimistic state is emitted. Bypass, Type-C mode, power-limit re-GET, and disconnect-as-success semantics remain those of WattlineCore.

The router JSON models are decoded into adapter-only DTOs and mapped to existing Core models. Missing port objects remain absent rather than fabricated with zero values. Wall-clock timestamps come from `updated_at` and the adapter's injected Date fallback when absent.

## Commands and capability gating

Common commands map to the daemon routes:

- DC and device actions → `POST /api/v1/device/action` with an allow-listed action string.
- USB-C limit get/set/clear → `GET`/`POST /api/v1/device/usbc-limit`.
- Bypass threshold → `GET`/`POST /api/v1/device/bypass-threshold`.
- Timer CRUD → `/api/v1/device/schedules`.

Clock sync, raw BLE-only settings, and any endpoint absent from the router capability map are unsupported. Their views and commands are absent from the view tree, not disabled. A router error or unsupported response is mapped to the existing command failure type. Restart/shutdown are treated as disconnect-as-success only when the router reports the action accepted and the SSE stream closes or status becomes disconnected.

## Discovery, remote hosts, and identity

`RouterDiscovery` wraps `NWBrowser` for `_wattline._tcp`. TXT `id` (MAC) and optional certificate fingerprint are retained. Discovery is injected in tests. Manual host entries support LAN, Tailscale, and other VPN DNS/IP endpoints; saved entries include scheme, host, port, display name, device ID (when known), and security choice.

Bluetooth and router records deduplicate by normalized MAC, then CID. They represent one physical device with a preferred transport (Bluetooth by default). Automatic failover is explicitly deferred.

## Pairing and security

Router bearer tokens are obtained through the router's asynchronous PIN pairing endpoints and stored through an injected Keychain credential store; plaintext persistence is prohibited. QR pairing is a follow-up until the router exposes a documented QR payload. HTTP is allowed for LAN/Tailscale/VPN hosts; HTTPS is supported with certificate-fingerprint pinning from discovery or pairing metadata. Plain-HTTP WAN access requires an explicit insecure-WAN opt-in and a persistent warning. No cloud relay or analytics is added.

The network package redacts tokens from errors/logs and validates host schemes, ports, and certificate fingerprints before connecting. SSE and command requests share the same bearer token and timeout policy.

## Test strategy

All network tests use an in-process fake HTTP+SSE server or injected protocol seams; no router, LAN, or external network is required. Tests cover handshake and identity mapping, initial/event telemetry, command-to-route mapping, telemetry reconciliation (including bypass/Type-C/limits/disconnect), SSE reconnect/stale generation quarantine, token success/failure, discovery TXT parsing, host validation, Keychain error paths, identity deduplication, and endpoint capability gating. Existing WattlineCore and WattlineUI tests remain unchanged and green. A source audit asserts that networking imports occur only in WattlineNetwork/app wiring and that WattlineCore remains free of URLSession/Network imports.

## Out of scope

Automatic transport failover, router firmware changes, router-repo edits, QR pairing, cloud services, OTA, timers beyond the existing Core surface, and any new app surfaces unrelated to choosing a transport are deferred.
