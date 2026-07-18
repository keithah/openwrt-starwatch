# gRPC-only dashboard telemetry design

## Goal

Make the dashboard unambiguous about whether a Starlink terminal is connected.
Terminal telemetry must come only from the dish gRPC snapshot and history
series. Router interface counters and WAN probes must never substitute for dish
telemetry.

## Source boundary

The Telemetry card uses only these dish-derived history series:

- Throughput: `dish_down_bps`, `dish_up_bps`
- Latency: `latency_ms`
- Loss: `drop_rate`
- Power: `power_w`

The dashboard header uses only the matching live dish fields. It does not fall
back to `router_down_bps`, `router_up_bps`, `wan_probe_rtt_ms`, or any other WAN
source. The daemon may continue collecting and serving WAN information for its
API and failover functions; this change does not alter those backend contracts.

## Disconnected state

When `dish_reachable` is false, the dashboard must:

- show `STARLINK DISCONNECTED` as the primary link state;
- hide the live metric strip;
- show `WAITING FOR DISH` instead of a `LIVE` streaming badge;
- render one prominent disconnected-state panel in place of dashboard cards;
- render no telemetry, WAN health, outage, power, dish control, speed test,
  hardware, Starlink-router, or client-management card.

Settings and the historical Events audit view remain reachable because they are
not current WAN telemetry. Navigation remains available. The disconnected panel
must not describe the attached non-Starlink network or show its measurements.

## Recovery

The existing status/WebSocket flow remains authoritative. When a later snapshot
reports `dish_reachable:true`, the normal section cards and gRPC-only header
metrics return automatically. The app then loads and appends only the dish
series listed above. No page reload is required.

## Implementation boundaries

Put source selection and disconnected visibility decisions in pure dashboard
logic so the browser harness can test them directly. Components render those
decisions; CSS is not the authority for hiding data. Remove the current
WAN-only Telemetry-card message because the entire card will be absent.

No daemon polling, REST endpoint, history storage, route management, router
control, packaging, or feed behavior changes are part of this work.

## Tests

The browser logic harness must prove:

1. Every graph tab selects only the approved dish gRPC series.
2. WAN/router series are absent even when a dish is reachable.
3. A disconnected snapshot produces no dashboard cards and the explicit
   disconnected state.
4. The header exposes no router/WAN metric fallback while disconnected.
5. A reachable snapshot restores the normal cards and gRPC-only metrics.

The complete Go race suite, vet, Linux ARM64 build, and embedded browser harness
must pass before commit and deployment.
