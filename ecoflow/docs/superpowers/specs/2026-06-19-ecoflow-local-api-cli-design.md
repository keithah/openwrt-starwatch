# EcoFlow Local API and CLI Design

Date: 2026-06-19

## Goal

Build a local-only Node/TypeScript CLI and HTTP API for an EcoFlow River 3 Plus at `192.168.8.112`.

The first version must monitor device status, expose input/output and charging/discharging statistics, control output groups where the local protocol supports it, and attempt whole-device shutdown only when it can be represented honestly. The implementation should also serve as a clear reference for a future Swift port, so the API contract and protocol notes are first-class deliverables.

## Non-Goals

- EcoFlow cloud login, cloud MQTT, or cloud REST support in the first version.
- Home Assistant integration in the first version.
- A web dashboard in the first version.
- Pretending unsupported local controls succeeded.

## Recommended Approach

Use a probe-first local adapter with a stable normalized API.

The River 3 Plus local protocol surface may vary by firmware, and whole-device shutdown may not be locally exposed. The implementation will discover and document what the device actually exposes, map known fields into stable API responses, and preserve raw diagnostic data for unknown fields or commands.

## Architecture

### `ecoflow-local`

TypeScript library containing the local transport and River 3 Plus protocol adapter.

Responsibilities:

- Connect to the configured device IP.
- Probe likely local protocol ports and transports.
- Decode known telemetry fields into typed domain models.
- Encode known output control commands.
- Preserve raw diagnostic frames/messages for fields not yet mapped.
- Return explicit capability and command status results.

This layer should avoid HTTP framework types, CLI formatting, and process globals where practical. It should be portable enough that a Swift implementation can mirror its types and control flow.

### `ecoflowd`

Local HTTP service exposing the normalized API.

Responsibilities:

- Load configuration, including device IP.
- Poll or subscribe to device state.
- Cache recent status for fast reads.
- Expose versioned JSON endpoints under `/v1`.
- Serialize errors using stable error codes.
- Keep diagnostics available for protocol mapping.

### `ecoflow`

CLI using the same library/client contract.

Responsibilities:

- Provide script-friendly commands.
- Print JSON by default.
- Offer concise human-readable output via an explicit flag later if useful.
- Exit non-zero on rejected, unsupported, unknown, or failed control commands.

## HTTP API Contract

All endpoints return JSON. Control endpoints must not infer success from a sent packet alone; they must report command outcome explicitly.

### `GET /v1/device`

Returns static and slowly changing device identity and capability information.

Response shape:

```json
{
  "device": {
    "name": "EcoFlow River 3 Plus",
    "model": "river_3_plus",
    "ip": "192.168.8.112",
    "serialNumber": null,
    "firmwareVersion": null
  },
  "capabilities": {
    "outputs": {
      "ac": "unknown",
      "dc": "unknown",
      "usb": "unknown"
    },
    "shutdown": "unknown",
    "diagnostics": "supported"
  }
}
```

Capability values are:

- `supported`
- `unsupported`
- `unknown`

### `GET /v1/status`

Returns the current normalized status snapshot.

Response shape:

```json
{
  "battery": {
    "percent": 72,
    "state": "discharging"
  },
  "power": {
    "inputWatts": 0,
    "outputWatts": 34,
    "netWatts": -34
  },
  "outputs": {
    "ac": { "state": "on", "watts": 28 },
    "dc": { "state": "off", "watts": 0 },
    "usb": { "state": "unknown", "watts": null }
  },
  "updatedAt": "2026-06-19T09:00:00.000Z"
}
```

Battery state values are:

- `charging`
- `discharging`
- `idle`
- `full`
- `unknown`

Output state values are:

- `on`
- `off`
- `unknown`

### `GET /v1/stats`

Returns charging/discharging details and estimates when available or safely derivable.

Response shape:

```json
{
  "batteryPercent": 72,
  "inputWatts": 0,
  "outputWatts": 34,
  "netWatts": -34,
  "estimatedMinutesRemaining": null,
  "estimatedMinutesToFull": null,
  "isEstimateDerived": false,
  "updatedAt": "2026-06-19T09:00:00.000Z"
}
```

### `GET /v1/outputs`

Returns output group state.

Response shape:

```json
{
  "outputs": {
    "ac": { "state": "on", "watts": 28, "controllable": "unknown" },
    "dc": { "state": "off", "watts": 0, "controllable": "unknown" },
    "usb": { "state": "unknown", "watts": null, "controllable": "unknown" }
  },
  "updatedAt": "2026-06-19T09:00:00.000Z"
}
```

`controllable` uses the same `supported`, `unsupported`, or `unknown` values as device capabilities.

### `POST /v1/outputs/ac`

Request:

```json
{ "state": "on" }
```

`state` may be `on` or `off`.

Response:

```json
{
  "target": "ac",
  "requestedState": "on",
  "result": "applied",
  "observedState": "on",
  "message": null
}
```

### `POST /v1/outputs/dc`

Same shape as AC, with `target` set to `dc`.

### `POST /v1/outputs/usb`

Same shape as AC, with `target` set to `usb`.

If the River 3 Plus does not expose USB as a separately controllable local output group, return `unsupported`.

### `POST /v1/power/shutdown`

Attempts whole-device shutdown only if a local command is discovered and verified.

Request:

```json
{}
```

Response:

```json
{
  "target": "device",
  "requestedState": "shutdown",
  "result": "unsupported",
  "observedState": "unknown",
  "message": "Whole-device shutdown is not exposed by the verified local protocol."
}
```

### `GET /v1/diagnostics`

Returns recent probe and raw protocol observations for development and Swift porting.

Response shape:

```json
{
  "deviceIp": "192.168.8.112",
  "observations": [
    {
      "timestamp": "2026-06-19T09:00:00.000Z",
      "transport": "unknown",
      "direction": "inbound",
      "raw": "base64-or-hex",
      "decoded": null,
      "notes": "Unmapped telemetry frame"
    }
  ]
}
```

Diagnostics may redact secrets if cloud support is added later.

## Command Result Semantics

Control results are:

- `applied`: command was sent and observed state matches the request.
- `rejected`: device returned an explicit rejection or error.
- `unsupported`: this implementation knows the local protocol does not support the request.
- `unknown`: command was sent or attempted, but outcome could not be verified.
- `failed`: transport or implementation failure prevented the command attempt.

Integrations must treat only `applied` as success.

## CLI Contract

The CLI should be usable both directly and from scripts.

Commands:

```text
ecoflow status --host 192.168.8.112
ecoflow stats --host 192.168.8.112
ecoflow outputs --host 192.168.8.112
ecoflow output ac on --host 192.168.8.112
ecoflow output ac off --host 192.168.8.112
ecoflow output dc on --host 192.168.8.112
ecoflow output dc off --host 192.168.8.112
ecoflow output usb on --host 192.168.8.112
ecoflow output usb off --host 192.168.8.112
ecoflow shutdown --host 192.168.8.112
ecoflow diagnostics --host 192.168.8.112
ecoflow serve --host 192.168.8.112 --listen 127.0.0.1:8787
```

Defaults:

- `--host` defaults to `ECOFLOW_HOST`, then `192.168.8.112`.
- Output is JSON by default.
- Control commands exit `0` only when the result is `applied`.

## Protocol Documentation Deliverable

Maintain `docs/protocol-river-3-plus.md` during implementation.

It must include:

- Device model and firmware when available.
- Local ports and transports tested.
- Message/frame examples with timestamps.
- Known telemetry field mappings.
- Known control command mappings.
- Unsupported or unverified controls.
- Notes relevant to a Swift port, including byte ordering, framing, checksums, retries, timeouts, and command verification strategy.

## Configuration

Initial configuration can be CLI flags and environment variables.

Environment variables:

- `ECOFLOW_HOST`
- `ECOFLOW_HTTP_LISTEN`
- `ECOFLOW_POLL_INTERVAL_MS`

Cloud credential variables are intentionally out of scope for this design.

## Error Model

HTTP errors use a stable JSON shape:

```json
{
  "error": {
    "code": "device_unreachable",
    "message": "Could not reach EcoFlow device at 192.168.8.112.",
    "details": {}
  }
}
```

Initial error codes:

- `device_unreachable`
- `protocol_timeout`
- `protocol_decode_failed`
- `invalid_request`
- `unsupported_operation`
- `command_rejected`
- `command_unverified`
- `internal_error`

## Testing Strategy

- Unit tests for normalized model types, command result semantics, and API serialization.
- Unit tests for known protocol decode/encode fixtures as they are discovered.
- CLI tests that assert JSON output and exit codes.
- HTTP API tests using a fake `ecoflow-local` adapter.
- Optional live tests gated by `ECOFLOW_LIVE_TESTS=1` and `ECOFLOW_HOST`.

Live tests must never run by default because they can change real device power state.

## Open Implementation Risks

- The River 3 Plus may not expose all desired controls locally.
- Whole-device shutdown may be unavailable locally.
- Some telemetry fields may require reverse mapping from raw local messages.
- LAN probing from sandboxed environments may require explicit network approval.

The API design handles these risks by distinguishing `unknown`, `unsupported`, and `applied`, and by keeping diagnostics available for future protocol work.
