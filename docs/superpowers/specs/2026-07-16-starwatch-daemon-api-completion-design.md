# Starwatch Daemon API Completion Design

## Goal

Complete the daemon API surface for the SPA by adding safe runtime configuration, optional location and Starlink-router telemetry, and conservative mwan3 visibility and failover assistance without expanding the Task 5 scope.

## Final wire formats

`GET /api/config` returns nested `main`, `history`, and `alerts` objects mirroring UCI ownership. The main object includes the §2.1 fields plus `location_enabled`; `token` is masked to its final four characters. `PUT /api/config` accepts the same nested shape as a partial update, but only probe hosts/interval, obstruction-map cadence, alert enables and thresholds, delivery URLs, and retention days are writable. Restart-managed keys are rejected with HTTP 400 and the phrase `restart-managed field`.

Field availability is finalized as an object keyed by field name whose values are:

```json
{"available": true}
```

or:

```json
{"available": false, "reason": "needs local-access opt-in in the official Starlink app"}
```

`/api/status` gains optional `location` and `starlink_router` objects. Location contains `latitude`, `longitude`, and `altitude`; the router object contains `reachable`, `hardware_version`, `software_version`, `client_count`, and `uptime_seconds`.

`/api/wan` gains an optional `mwan3` object with normalized interface states, tracking state, active policy, and last switch information. `/api/wan/failover-assist` returns `{available, reason, proposed}`, where `proposed` is an ordered array of `{package, section, option, value}` tuples. The exact same tuples shown by GET are submitted through UCI batch by POST.

## Component boundaries

### mwan3 manager

`internal/mwan` owns command execution, output parsing, GL coexistence detection, assist eligibility, proposal generation, and explicit application. Every command runs through an injected runner. Status prefers `ubus call mwan3 status` and falls back to `mwan3 interfaces`; absence or an unrecognized response produces no mwan3 snapshot and never fails the daemon.

Assist eligibility requires mwan3, no GL multi-WAN manager, no non-Starwatch mwan3 sections, and at least two discovered WAN interfaces. The detected Starlink interface is primary. If more than one backup exists, the lexically first non-Starlink interface is selected for deterministic output. Generated sections use only `starwatch_*` names. Application sends one UCI batch, runs `mwan3 restart`, then refreshes status. No other component writes routing configuration.

### Runtime settings manager

The config package retains a source-preserving UCI document representation. Known option values can be replaced while unknown lines, sections, and options remain intact; comments are retained when their surrounding lines remain unchanged. Writes use a temporary file plus rename.

A settings manager validates a complete candidate configuration before persistence. Persistence happens before runtime publication, so failed writes leave active settings unchanged. Runtime consumers receive safe updates through setters or atomically read the manager snapshot. Authentication reads the current token for every request, making token regeneration immediate. Every successful update and token regeneration appends a `config` event and publishes it on the live event bus.

Token regeneration uses `crypto/rand`, returns the new token in full once, persists it, and subsequently masks it in GET responses.

### Location telemetry

The dish client gets a typed `get_location` wrapper. The existing poller calls it every 60 seconds only when `location_enabled` is true. Success stores latitude, longitude, and altitude. PermissionDenied or Unavailable marks the location field unavailable with the fixed local-access opt-in reason. Disabling the option stops calls and removes location from the public snapshot.

### Starlink-router telemetry

A separate read-only router poller is active only while the dish topology is full. An injected gateway resolver produces `<gateway>:9000`, and an injected dialer creates a client using the same plaintext `Handle` protocol. At 60-second cadence it calls only `get_device_info`, `wifi_get_clients`, and `wifi_get_status`. It never constructs a `wifi_set_*` request. Failed discovery omits the router section; a previously discovered router reports `reachable:false` during later failures.

### Failover alert

`failover_event` is a warning rule enabled by default and configurable through UCI. The engine compares a canonical, sorted set of active/online mwan3 interfaces with the previous tick. It emits one firing notification and event when the set changes after the initial baseline. It has no active state and emits no clear notification.

## Error handling and safety

- Missing mwan3, ubus, GL objects, location permission, or Starlink-router gRPC are availability states, not daemon failures.
- Failover-assist POST returns HTTP 409 when the current eligibility result is unavailable.
- Unsafe daemon settings are rejected before any write.
- UCI application is explicit, injectable, and restricted to `starwatch_*` sections.
- Config mutation and token changes are serialized.
- Existing WebSocket framing is unchanged; new config, failover, and related events use the existing asynchronous event envelope.

## Testing

Tests use fake runners, fake filesystem/UCI fixtures, fake clocks, and in-process fake gRPC servers. Coverage includes mwan3 JSON/text parsing, all assist refusal reasons, exact UCI proposal/application, unknown UCI content preservation, partial config updates and forbidden fields, immediate token rotation, location gating and denial reasons, read-only router RPC coverage, and event-only failover alerts. No test invokes real network, UCI, ubus, or mwan3 commands.

The two implementation commits each pass race tests, vet, and a CGO-disabled Linux arm64 build.
