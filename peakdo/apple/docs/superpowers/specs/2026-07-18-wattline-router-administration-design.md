# Wattline Router Discovery and Administration Design

**Date:** 2026-07-18  
**Status:** Product-approved design  
**Authority:** `~/src/openwrt-wattline/docs/api.md`, route descriptors, handlers, and tests  
**Platforms:** iOS 17+ and macOS 14+

## 1. Objective

Complete Wattline's optional router experience on iOS and macOS. Users can
discover and enroll with `wattlined`, inspect router history, and explicitly
unlock router administration with the existing bootstrap token. Administrators
can manage API clients, pairing, router configuration, TLS, Link-Power pairing,
advanced device settings, and automation rules.

Bluetooth remains the primary device transport. A PIN-enrolled router client is
an optional peer transport and retains telemetry-is-truth reconciliation. Router
administration is a separate HTTP control plane; it never creates another BLE
owner or changes dashboard state optimistically.

This work does not add OTA, firmware download/upload, device Timers, cloud
services, or deprecated compatibility routes. Timers remain removed by product
decision, and OTA remains deferred.

## 2. Architecture

### 2.1 Credential and role separation

`RouterTransport` continues using a managed **client** token for identity,
telemetry, SSE, history, ordinary controls, and router-to-device BLE pairing.
`RouterAdministrationClient` uses the separately entered **administrator**
bootstrap token only for short-lived privileged requests.

Both secrets use `RouterCredentialStore`, keyed by normalized endpoint and role.
The existing unsuffixed Keychain account remains the client account so current
installations migrate without losing credentials. Administrator accounts use a
distinct suffix. Tokens are never copied into `UserDefaults`, snapshots, logs,
errors, QR payloads, or view state beyond the lifetime of a secure entry field.

Entering an administrator token performs `GET /api/v1/settings`. A `200` proves
the role and saves the token. `401` rejects an invalid token; `403
admin_required` identifies a managed client token and is not treated as an
administrator credential. Wattline cannot promote a managed token and does not
attempt privilege escalation.

### 2.2 Package boundaries

- `WattlineNetwork` owns all HTTP/SSE, Network.framework, Security/Keychain,
  Bonjour, QR payload parsing, router DTOs, typed API clients, and pure mutation
  validation.
- `WattlineCore` remains free of networking, Security, SwiftUI, UIKit, AppKit,
  AVFoundation, Vision, and router-specific administration models.
- `WattlineUI` contains cross-platform SwiftUI presentation and composition for
  history and router administration without importing networking frameworks.
- Thin iOS/macOS app adapters own camera/image QR recognition, platform
  permissions, navigation, and one shared-source `RouterAdministrationModel`.

Each app process still owns exactly one active `DeviceTransport`. The
administration actor can issue HTTP requests but cannot construct a BLE
transport, `DeviceSession`, or `DeviceOperationBroker`.

### 2.3 Administration request actor

One `RouterAdministrationClient` actor serializes privileged mutations per
router. Read-only requests may share the actor but do not overlap a mutation
whose returned effective state must be reloaded. Every mutation follows:

1. send the exact canonical request;
2. validate the status and typed response;
3. re-fetch the authoritative resource when the endpoint response is not the
   complete effective state;
4. publish the accepted generation only;
5. leave prior state visible but stale on failure.

Attaching a different endpoint increments a generation. Completions from the
previous endpoint are discarded. Cancellation maps `URLError.cancelled` to
`CancellationError`, and continuations resume once.

## 3. Navigation and structural gating

Both platforms expose **Advanced → Router Administration** for a saved or
discovered router. The shared section order is:

1. Connection and History
2. Client Enrollment
3. API Clients
4. Router Configuration
5. Link-Power Pairing
6. Device Administration
7. Automation Rules

Client surfaces appear after client enrollment. Administrator sections appear
only after successful administrator-token verification. Device-administration
controls additionally require `settings.advanced == true` and the corresponding
identity feature/availability. Unsupported surfaces are absent from the view
tree, not disabled. The Advanced setting itself remains visible to an
administrator so the operator can enable it.

Destructive actions—token revocation, TLS rotation, unpairing, running-mode
changes, BLE PIN changes, shutdown rules, listener removal, and insecure WAN
HTTP—require a purpose-specific confirmation. Monospaced numerals and the shared
charging/discharging/idle colors remain consistent with existing Wattline UI.

## 4. Discovery and client enrollment

### 4.1 Bonjour and deduplication

`RouterConnectionModel` owns an injected `RouterDiscovery` lifecycle. It starts
`NWBrowser` for `_wattline._tcp` while the scan surface is active and stops it on
exit. Results must pass the existing exact v1 TXT validation (`api`, `id`,
`auth`, `tls`, `cid`, `features`) and include a resolved authority.

The scan screen presents Bluetooth and router observations together. MAC is the
primary deduplication key and CID is the fallback only when MAC comparison is
unavailable. A physical device seen through both sources is one row with BT
preferred and a Router badge/action. Saved LAN, VPN, and WAN endpoints correlate
to the same device ID rather than creating duplicate devices.

iOS adds `NSLocalNetworkUsageDescription` and `_wattline._tcp` to
`NSBonjourServices`. macOS adds only the sandbox/network declarations required
by the existing app target.

### 4.2 Pairing inputs

Wattline accepts the documented `wattline://pair` v1 payload through:

- iOS camera barcode capture;
- opening the registered URL scheme on either platform;
- paste on either platform;
- QR image import on either platform using a platform adapter.

The cross-platform parser remains `RouterPairingPayload`. iOS camera access is
requested only after the user taps Scan QR and has a camera usage description.
macOS does not request camera access; it supports URL paste and image import.

A discovered router without a QR can enroll by asking for its six-digit current
pairing PIN and a client label. Enrollment calls public `POST /api/v1/pair`
without Authorization, correlates device ID and TLS pin, saves the client token
to Keychain, persists only host metadata, and then connects. PIN and QR payload
descriptions remain redacted. Manual entry of an existing bearer token remains
an explicitly labeled recovery path.

## 5. History

`GET /api/v1/history` is client-role and returns the router's bounded,
approximately one-minute samples. Wattline decodes `at`, `level`, signed
`status`, `dc_w`, and `typec_w` exactly. It does not fabricate missing samples or
persist a second history database.

The shared presentation provides battery level and aggregate/individual port
power over time, an empty state, and an honest fetch timestamp. History is loaded
lazily and refreshed explicitly or when the endpoint changes. It remains useful
while the Link-Power is disconnected because the route serves cached data.

## 6. Client enrollment administration

### 6.1 Pairing mode and QR sharing

The administrator client implements:

- `GET /api/v1/pairing-mode`
- `POST /api/v1/pairing-mode` with zero-byte body
- `DELETE /api/v1/pairing-mode` with zero-byte body
- `GET /api/v1/pairing-mode/qr.png` with no query

The PIN and QR PNG exist only in memory while the pairing view is visible. The
view shows expiry and clears secret material on dismissal, close, expiration,
endpoint replacement, or backgrounding. QR retrieval is enabled only while the
authoritative status is open. Sharing uses the system share sheet/save panel and
never writes the PIN into app persistence.

### 6.2 Managed tokens

`GET /api/v1/tokens` decodes metadata only: ID, label, creation time, optional
last-seen time, and bootstrap flag. No model contains a returned token secret.
`DELETE /api/v1/tokens/{id}` requires confirmation, percent-encodes the path
component, rejects empty/bootstrap IDs locally, and re-lists after success.

Revoking the managed token used by this Wattline endpoint warns that SSE will
close immediately. After confirmed revocation, Wattline deletes the matching
client Keychain credential and returns that endpoint to enrollment. Revoking a
different client does not disturb the active transport.

## 7. Router configuration and TLS

### 7.1 Typed merge settings

`GET /api/v1/settings` decodes the complete settings response. A typed
`RouterSettingsPatch` encodes only changed writable members for `PUT
/api/v1/settings`, preserving omitted fields and nested members. It cannot encode
unknown fields or read-only `tls.sha256`. Empty mDNS interface arrays remain
distinct from omission.

The editor covers HTTP/HTTPS enabled state, addresses and ports, TLS certificate
and key paths, token-store path, pairing TTL and always-on policy, Advanced,
mDNS enabled/interfaces, WAN access, and the six-digit BLE PIN. Sensitive or
high-risk values use explicit confirmations. A save renders only the complete
effective settings returned by the router; it never merges optimistically.

If `restart_required` is true, Wattline reports that `wattlined`/the router must
restart before listener, firewall, mDNS, or certificate changes take effect. It
does not pretend that restarting the Link-Power restarts the daemon.

Listener edits must leave at least one valid post-restart route. If the current
endpoint will disappear, Wattline requires the user to select and validate a
replacement candidate before saving. The current connection remains active
until the daemon actually restarts.

### 7.2 TLS rotation and pin handoff

`POST /api/v1/tls/rotate` is sent over the currently authenticated, pinned
administrator channel with `{"confirm":true}`. Wattline validates the returned
64-hex `sha256` and `restart_required:true`.

Rotation does not overwrite the active pin immediately because the running
listener continues serving the old certificate until restart. Host metadata
stores a staged next pin separately. After service restart, Wattline creates a
new session that accepts only the staged pin, verifies the correlated device ID,
and atomically promotes staged→active on successful `/device`. The old pin is
then rejected. Before restart the old pin remains the sole accepted pin. A
client that missed the authenticated handoff must re-enroll or confirm the new
pin out of band; there is no TOFU replacement or HTTP downgrade.

## 8. Router-to-Link-Power BLE pairing

The client-role pairing service implements the canonical status, scan, pair, and
unpair routes. Scan and pair are asynchronous:

- start only when status is not already scanning/pairing;
- poll `GET /api/v1/pairing/status` with an injected bounded clock;
- display stage, target, devices, RSSI, paired state, and asynchronous error;
- stop polling on terminal state, cancellation, endpoint replacement, or a
  bounded timeout;
- re-fetch status after unpair.

Pairing accepts a selected normalized MAC and an optional six-digit BLE PIN. An
empty PIN deliberately retains the configured router PIN. The PIN is never
logged or persisted by the app. Only one pairing operation is in flight per
router, and `operation_in_progress` is rendered as current activity rather than
starting a second operation.

## 9. Advanced device administration

When administrator authentication, `settings.advanced`, application/OTA mode,
and hardware capability all allow it, Wattline exposes:

- bypass threshold: GET and PUT volts, with the PUT response treated as the
  observed SET-then-GET value;
- clock read and manual sync using the existing administrator transport profile;
- running mode: PUT-only documented unsigned enum with confirmation;
- barrier-free mode: GET and PUT, displaying only the observed GET result;
- USB firmware: read-only raw/major/minor/patch;
- BLE PIN: exact six-digit string PUT with confirmation and no optimistic echo.

These calls live in the administration client rather than widening
`DeviceCommand` with router-only operations. `403 advanced_disabled` causes a
settings affordance to enable Advanced; it does not leave a dead control in the
view. Capability failures remove only the affected surface after the next
authoritative identity/settings refresh.

## 10. Automation rules

Wattline implements canonical `GET`, `POST`, `PUT`, and `DELETE /api/v1/rules`
without using deprecated `/device/action`.

Typed rules cover the documented conditions (`input_power`, `battery_level`,
`port_power`, `schedule`), operators, ports, five-field cron string, hold,
hysteresis, repeat interval, actions, and shutdown confirmation. Go duration
nanoseconds convert to checked user-facing durations without overflow. Webhook
actions are allowed only after an explicit warning that the router—not the
Wattline app—will make the outbound request.

Rules with unknown additive condition/action fields remain visible as read-only
JSON summaries and cannot be rewritten by Wattline. This prevents a
forward-compatible decode from silently deleting data the app does not
understand. Every mutation re-lists rules. Ordinary manual actions reuse the
canonical granular endpoints already implemented; Wattline does not call the
deprecated action route, including for manual webhooks.

The reserved `no_input_shutdown` preset receives a dedicated Power-loss
shutdown editor. For a compatible preset it changes only `enabled`, `hold`, and
`confirm_shutdown` while preserving every other documented field and action. An
incompatible preset is read-only until the user confirms Reset preset, which
replaces it with the canonical absent-input/shutdown rule.

## 11. Error handling and lifecycle

All clients use the canonical error envelope and existing token redaction.
Presentation distinguishes invalid client credential, invalid administrator
credential, admin required, Advanced disabled, unsupported hardware, operation
busy, disconnected device, BLE failure, timeout, not found, invalid input, and
internal persistence failure.

An administrator 401 invalidates only the admin session; it does not disconnect
the client telemetry transport. A client 401 ends SSE and returns the endpoint
to enrollment. A 403 never triggers token replacement. Mutation failures keep
the last authoritative state marked stale and offer retry. Secrets are absent
from `CustomStringConvertible`, diagnostics, analytics, notifications, and
crash breadcrumbs.

## 12. Milestones

1. **Discovery and enrollment UI:** browser lifecycle, unified/deduplicated scan,
   URL/deep-link/paste/image QR flows, PIN enrollment, client credential storage.
2. **Administration foundation:** role-scoped credentials and verification,
   history, pairing-mode/QR sharing, token listing/revocation.
3. **Router configuration:** settings patch/readback, safe endpoint migration,
   TLS staged-pin rotation and promotion.
4. **Device administration:** router BLE pairing, bypass threshold, clock,
   running mode, barrier-free, USB firmware, and BLE PIN.
5. **Automation and completion:** rules, power-loss preset, shared iOS/macOS
   navigation, accessibility, Demo fixtures, and full verification.

Each milestone is TDD and stops for review with a separate commit per task.

## 13. Test strategy and exit criteria

Every production behavior begins with a non-vacuous failing test. Exact fixtures
come from the router documentation and handlers. Tests use injected HTTP,
discovery, Keychain, clocks, QR recognition, share, and lifecycle adapters; no
real router or external network is required.

Required coverage includes:

- Bonjour lifecycle, strict TXT parsing, deduplication, and saved-host merging;
- all pairing inputs, secret redaction, public no-auth request, identity/pin
  correlation, Keychain rollback, and cancellation;
- role-separated credential accounts and administrator verification;
- exact history, pairing-mode, token, settings, TLS, BLE-pairing, advanced, and
  rule request/response contracts;
- settings merge omission versus empty values;
- staged TLS pin behavior before/after restart and atomic promotion;
- async BLE-pair polling, busy/timeout/cancel/error behavior;
- structural absence for client-only, Advanced-off, unsupported, and unknown
  rule surfaces;
- stale-generation quarantine on endpoint replacement;
- iOS and macOS composition/navigation tests and Demo fixtures;
- Core/UI forbidden-import and Network-only networking/Security audits;
- clean simulator install and launch, including the preserved
  `RouterTransport` initializer ABI regression.

Milestone verification runs all WattlineCore, WattlineUI, WattlineNetwork, iOS,
macOS, and widget suites affected by that milestone. Real-router checks remain
external: LAN permission and Bonjour visibility, camera/image QR recognition,
PIN enrollment/rate limiting, VPN/WAN reachability, certificate rotation across
a daemon restart, listener migration, token-revoked SSE termination, physical
BlueZ pairing, advanced BLE commands, rules firing, and hardware latency.

## 14. Explicit exclusions

- OTA information/enter/exit and all firmware transfer work.
- Device Timers and timer UI.
- Deprecated compatibility endpoints, including `/device/action`,
  `/device/usbc-limit`, `/device/bypass-threshold`, and `/device/schedules`.
- Cloud relay, analytics, CDN, or app-originated webhook delivery.
- Automatic Bluetooth↔router failover; transport selection remains explicit.
- Editing the router repository or Wattline's read-only product/BLE contracts.
