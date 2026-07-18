# Starwatch Diagnostics Phase 1 Design

## Scope

Implement the read-only 0.1.0 diagnostic expansion: corrected dish GPS/PNT,
slot, and disablement status fields plus `GET /api/diagnostics`. The work adds no
gRPC writes, battery model, `/api/router`, new router RPC, SPA change, Wi-Fi or
client access, control change, or packaging change.

The corrected GPS JSON key is `pnt_filter_state`. It contains the exact
`AttitudeEstimationState.String()` value. `disablement_code` likewise contains
the exact `UtDisablementCode.String()` value.

## Architecture

The dish poller copies protobuf values into typed local JSON models. GPS is a
separately tracked optional field under the existing three-consecutive-failure
availability rule. A missing `GpsStats` increments only GPS availability and
never emits a zero-valued GPS object. Slot time and disablement code are scalar
members of every successful status response and follow status availability.

`internal/diagnostics` is a pure derivation package. It consumes narrow local
inputs: history points/tier, a dish snapshot, a WAN snapshot, and outage
entries. The API handler parses the existing supported span vocabulary, queries
the dependencies, and delegates calculations to the package.

The existing topology-B router poll retains ping latency/drop-rate values from
its already-issued `WifiGetStatus` request and records the last time a router
ping succeeded. No additional router request is added.

## Statistics and Availability

Raw RAM latency uses all valid samples and nearest-rank P95. Persisted aggregate
statistics retain their sample count internally so means are weighted.
Long-span P95 and histogram counts approximate each aggregate by its average,
weighted by its sample count, and set `approximate: true`.

Distribution buckets are inclusive at `20`, `40`, `60`, `80`, `100`, `150`,
`200`, and `500` milliseconds, followed by an open bucket represented by
`upper_bound_ms: null`.

NaN, infinity, and unavailable values are ignored. Power additionally requires
positive values. A sub-object with no usable data is encoded as
`{"available":false,"reason":"..."}` instead of fabricated numeric zeros.
Missing topology-B router latency is omitted and accompanied by
`router_ms_availability`.

Dish, router, and WAN ping fields retain distinct names. Success is
`clamp(1-drop_rate, 0, 1)`. No DNS result is produced.

Outages are clipped to the requested window, sorted, and unioned. Overlapping
representations contribute one merged interval to count, downtime, and longest
duration.

## HTTP and Validation

`GET /api/diagnostics` uses the existing bearer/query-token middleware. Its
supported spans are exactly `15m`, `3h`, `24h`, `7d`, and `30d`; the same
allowlist is applied to history requests so unknown spans return 400. History's
unknown series behavior remains 400.

## Verification

Tests cover exact status enum names and absent GPS, raw percentile boundaries,
aggregate approximation, ping clamping, outage unioning, power summaries,
empty availability, histogram edges, auth, and span validation. Final evidence
is `go test -race ./...`, `go vet ./...`, and a CGO-disabled linux/arm64 build.
