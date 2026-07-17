# Router Client Rename Design

## Goal

Ship the first gated topology-B router mutation: rename exactly one known
client, without changing access state, Wi-Fi configuration, radios, or any
other client configuration.

## Design

`PATCH /api/router/clients/{mac}` is an authenticated, 128 KiB JSON endpoint.
It accepts only `config_revision`, `confirmation`, and a non-empty
`given_name`. The path MAC is normalized to lowercase colon notation and is
matched against the latest router snapshot. Topology B and a reachable router
are mandatory.

The handler compares the supplied revision with the snapshot, then dials the
router and rereads `wifi_get_config` immediately before the mutation. It
compares the reread incarnation again because the targeted RPC is not known to
enforce it atomically. It finds the matching `ClientConfig`, clones it, changes
only `given_name`, and sends it with `WifiSetClientGivenName` (request field
3017). A missing config receives the minimal `{mac_address, given_name}`
configuration. This preserves the config's client ID, group ID, and weekly
block schedules.

The handler rereads clients and config after the RPC and returns `202` only if
the client name equals the requested value. Unsupported gRPC status codes map
to `422`; other upstream or readback-confirmation failures map to `502`.
Successful writes create one `router_control` audit event and one live event,
without including configuration passwords.

When topology B is present but no router poll snapshot exists, `GET /api/router`
returns a typed warming response with `reachable:false`; topology absence
remains `503`.

## Tests

Use the in-process Handle-protocol fake router. Cover successful read-merge and
readback-confirmation, schedule preservation, validation/status mappings,
normalized MAC lookup, and absence of passphrases from HTTP/audit output. No
test reaches a live router.
