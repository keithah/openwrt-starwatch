# Starwatch Battery Phase 2 Design

## Scope

Implement the approved 0.1.0 battery configuration and derived terminal-runtime
contract. The feature is pure configuration and arithmetic: no gRPC writes,
router API/telemetry, Wi-Fi/client access, dish-control change, SPA change, or
packaging change.

## Configuration

`config.Config` gains a `BatteryConfig` value. The public GET view always emits
the battery object. PUT accepts a partial `BatteryUpdate` without a timestamp
field, so the existing unknown-field rejection rejects client timestamps.
Supplying state of charge stamps the update with the manager's server clock.

The disabled defaults are internally valid: 1000 Wh capacity, 100% state of
charge, 10% reserve, and 90% conversion efficiency. The timestamp is zero until
SOC is explicitly entered. Validation enforces the API bounds before writing.

Persistence uses an unnamed dedicated `config battery` section with options
`enabled`, `capacity_wh`, `state_of_charge_percent`, `reserve_percent`,
`conversion_efficiency_percent`, and `state_of_charge_updated_at`. Existing UCI
rewrite behavior preserves comments, unknown options, and unknown sections.
Battery changes use the existing `config` audit event path and live apply path.

## Diagnostics

The HTTP handler independently queries positive terminal power for the rolling
15-minute load window and passes those points plus a typed battery input to the
pure `internal/diagnostics` summarizer. The requested-span power summary remains
unchanged.

An enabled battery reports configured inputs, `load_window: "15m"`, staleness,
and `derived: true`. Positive finite samples are weighted by aggregate sample
counts. A sample is stale when its newest timestamp is before the 15-minute
window. Current time before 2025, a future sample, or an invalid timestamp is an
insane-clock path.

Runtime uses Wh divided by W to produce hours. Full-charge usable energy uses
`100 - reserve`; remaining usable energy uses `max(0, SOC - reserve)`. Both
apply conversion efficiency. Missing values have field-specific availability
objects rather than numeric zeros.

Disabled batteries report `configured: false` and `derived: true` without load
or runtime estimates. Invalid/stale power or an insane clock hides both runtime
values. SOC age is stale only when strictly greater than 24 hours; stale SOC or
SOC at/below reserve hides only remaining runtime, while full-charge runtime
remains present.

The model is explicitly for the configured battery powering the Starlink
terminal only. It does not model router/other loads, voltage, inverter behavior,
temperature, aging, or charging.

## Verification

Tests cover config GET/PUT DTOs, every bound, server SOC stamping, lossless UCI
round trips and audit events, exact formulas, Wh/W dimensional behavior,
disabled and invalid-load paths, insane clocks, stale power, reserve/SOC, and
the exact 24-hour SOC boundary. Final verification is the race suite, vet, and
CGO-disabled linux/arm64 build before one feature commit and push.
