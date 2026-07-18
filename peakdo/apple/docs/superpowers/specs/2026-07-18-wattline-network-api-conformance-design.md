# Wattline Network API Conformance Design

**Date:** 2026-07-18  
**Status:** Approved direction; written-spec review pending  
**Scope:** App-used `wattlined` HTTP API only

## 1. Purpose and authority

Bring `WattlineNetwork` into exact agreement with the current `wattlined` HTTP v1 implementation in `~/src/openwrt-wattline`. The router repository remains read-only. Its `docs/api.md`, `internal/api/routeDescriptors`, handlers, and tests are the wire authority; the older Wattline network design remains historical context.

This pass covers discovery, API-client enrollment, identity, cached telemetry, SSE, ordinary device controls, USB-C limits, clock access, restart, and shutdown. It deliberately excludes OTA, device timers, automation rules, router settings, token administration, router-to-device BLE pairing, and expert operations. Those receive separate designs later.

## 2. Chosen approach

Wattline will use the canonical v1 routes rather than deprecated compatibility aliases. It will not probe aliases or silently fall back. Replies remain forward-compatible by ignoring additive JSON fields.

Rejected approaches:

- Keeping the compatibility routes would preserve known technical debt and prevent the client from using the canonical error and identity contracts.
- Runtime route probing would add traffic and make permission, capability, and version failures ambiguous.

## 3. Package boundary

All HTTP, SSE, Bonjour, TLS, and Keychain integration remains in `WattlineNetwork`. `WattlineCore` and `WattlineUI` remain free of `URLSession`, `Network`, and `Security` imports.

`RouterTransport` remains a `DeviceTransport` peer of BLE, Demo, and Replay transports. It continues to serialize commands and publish only accepted-generation events. The app remains the single transport owner per process.

## 4. Canonical connection and telemetry flow

1. Resolve a Keychain-backed bearer credential for the selected endpoint.
2. Call `GET /api/v1/device` and decode the complete identity contract: stable device ID, model, hardware revision, application firmware, OTA firmware, CID, raw features, mode, characteristic availability, connection state, and optional MagicDNS name.
3. Emit `handshakeCompleted`, preserving application-versus-OTA mode and the identity values returned by the router.
4. Open authenticated `GET /api/v1/events` and decode unnamed `data:` frames using the complete `/telemetry` snapshot schema. Additive `identity` and `commands` fields are ignored until a consumer needs them.
5. Emit battery, DC, and Type-C events only for fields present in the snapshot. Never synthesize absent ports or zero telemetry.
6. Treat `connected:false`, stream termination, or a transport failure as reconnecting/stale. Treat `401` as terminal credential failure. Preserve generation quarantine and the last accepted telemetry timestamp floor.
7. `GET /api/v1/telemetry` remains the explicit refresh route and follows the same mapping and generation gates as SSE.

The initial device response is cached state and may report disconnected. The transport may complete identity setup, publish reconnecting, and continue trying the SSE stream without inventing live telemetry.

## 5. Canonical command routes

The command mapper uses only these routes:

| Operation | Request | Confirmation |
|---|---|---|
| DC output | `POST /api/v1/device/dc` with `{"on":BOOL}` | Matching `dc.enabled` telemetry |
| USB-C output | `POST /api/v1/device/usbc/output` with `{"on":BOOL}` | Matching `typec.mode` telemetry; never `enabled` |
| DC bypass | `POST /api/v1/device/dc/bypass` with `{"on":BOOL}` | Matching `dc.bypass` telemetry within 10 seconds |
| Read USB-C limit | `GET /api/v1/device/usbc/limit/{type}` | Device-observed response converted to the Core command reply |
| Set USB-C limit | `PUT /api/v1/device/usbc/limit/{type}` with `{"watts":N}` | Canonical response is already the router's serialized SET-then-GET observation |
| Clear USB-C limit | `DELETE /api/v1/device/usbc/limit/{type}` with no body | Canonical response is already the router's serialized DELETE-then-GET observation |
| Read clock | `GET /api/v1/device/clock` | For an explicitly configured administrator connection, return the decoded device time or `nil` when `available:false` |
| Sync clock | `POST /api/v1/device/clock/sync` with no body | For an explicitly configured administrator connection, use the successful observed router response; no optimistic clock state |
| Restart | `POST /api/v1/device/restart` with no body | Preserve disconnect-as-success and reconnect |
| Shutdown | `POST /api/v1/device/shutdown` with `{"confirm":true}` | Preserve disconnect-as-success and disarm reconnect |

Compatibility routes `/device/action`, `/device/usbc-limit`, `/device/bypass-threshold`, and `/device/schedules` are removed from the app-used mapper. Bypass-threshold administration and schedules are outside this pass and must not appear as supported router surfaces.

The router correctly restricts clock routes to administrator credentials with advanced operations enabled. A token issued by public PIN enrollment has the client role, so a normal paired connection structurally omits manual router clock controls. Clock access is available only for an explicitly configured administrator connection; Wattline does not attempt privilege escalation or silently substitute a client token.

The server already reconciles granular boolean commands before returning, but Wattline still waits for accepted SSE telemetry before changing its local port state. A write acknowledgement or response echo never drives dashboard state.

## 6. Discovery and endpoint validation

Bonjour browses `_wattline._tcp` and accepts only v1 records whose TXT contract is internally valid:

- `api=1`
- normalized `id` MAC
- `auth=pin`
- optional `model`
- four-lowercase-hex `cid` when present
- eight-lowercase-hex `features` when present
- `tls=none` for HTTP or a 64-hex DER SHA-256 pin for HTTPS

The discovered service's resolved host and advertised port form the endpoint. The obsolete `fingerprint` TXT key is not accepted. Records are deduplicated by normalized device ID.

Manual addresses without a port use the daemon defaults: HTTP 8377 and HTTPS 8378. Explicit ports are preserved. Plain HTTP on WAN still requires explicit opt-in; HTTPS pin mismatch remains a hard failure with no downgrade. LAN HTTP and encrypted VPN HTTP remain allowed.

## 7. API-client enrollment and QR

Enrollment uses public `POST /api/v1/pair` with no Authorization header and request `{"pin":"NNNNNN","label":"…"}`. The client decodes the one-time token, token metadata, device ID, enabled base URLs, TLS fingerprint, and MagicDNS name.

Before storing the secret, Wattline validates:

- the response device ID matches the selected discovery or QR identity;
- the chosen base URL uses an allowed scheme and port;
- a supplied/discovered HTTPS pin matches `tls_sha256`;
- the response contains a token only on a successful 201 reply.

Only then is the token written to Keychain. Failure leaves no plaintext token or partially saved host. The public pairing request never receives a bootstrap or existing managed bearer token.

The QR parser accepts only the documented `wattline://pair` v1 payload and its exact meanings for `id`, `host`, `http`, `https`, `pin`, and `tls`. It rejects unknown versions, malformed MACs, invalid ports, malformed pins or fingerprints, and a TLS pin without HTTPS. URI query values use normal percent decoding; secrets are redacted from descriptions and errors.

Manual entry of an already-issued bearer token remains an advanced recovery path and stores the token directly in Keychain after host validation.

## 8. Errors and authentication

Canonical error bodies are decoded as `error.code`, `error.message`, and additive `error.details`. Wattline exposes stable typed cases for:

- unauthorized or revoked credential;
- invalid or expired pairing PIN;
- admin required;
- advanced disabled;
- capability unsupported;
- operation in progress;
- device disconnected;
- BLE operation failure;
- telemetry-confirmation timeout;
- invalid request, not found, and internal error.

Unknown codes retain the HTTP status and a redacted message. Error decoding never includes bearer tokens, pairing PINs, or QR payloads in logs/descriptions. `URLError.cancelled` continues to map to `CancellationError`.

Capability errors do not optimistically remove a surface mid-command. The canonical identity feature/availability data and the selected transport profile determine structural gating; unsupported surfaces are absent from the view tree.

## 9. Tests and verification

Every production behavior starts with a failing, non-vacuous test using exact router-derived JSON and an in-process fake HTTP/SSE server:

- canonical device identity and application/OTA mode mapping;
- complete telemetry, missing-port behavior, signed status, timestamps, SSE reconnect, and stale-generation quarantine;
- exact command method/path/body for all in-scope operations;
- telemetry confirmation for DC, Type-C, and bypass;
- authoritative limit response conversion and runtime read-only behavior;
- clock available/unavailable and sync;
- restart/shutdown disconnect semantics;
- canonical error-envelope mapping and token/PIN redaction;
- mDNS `tls` parsing, invalid-record rejection, host/port resolution, and identity deduplication;
- default ports 8377/8378 and explicit-port preservation;
- PIN enrollment, response correlation, atomic Keychain persistence, and QR parsing.

Verification runs WattlineNetwork, WattlineCore, WattlineUI, and affected app-target tests, plus source audits proving networking and Security imports remain confined to `WattlineNetwork`. Real-router checks remain external: Bonjour visibility, PIN/QR enrollment, certificate pinning, token revocation closing SSE, VPN reachability, and physical telemetry/control latency.

## 10. Deferred work

Separate future milestones will cover OTA; device timers; rules; router settings; token listing/revocation; pairing-mode administration; router-to-Link-Power BLE pairing; TLS rotation; and expert operations such as running mode, barrier-free mode, USB firmware, BLE PIN, and bypass threshold.
