# Starwatch Task 3 Implementation Plan

**Goal:** Address the six Task 2 review findings, then add the merged outage timeline, alert engine, event APIs, and authenticated WebSocket feed in a separate commit.

**Architecture:** Keep dish, WAN, history, outage, alert, event, and HTTP concerns separated behind small interfaces. SQLite remains optional: outage/event writers and readers degrade to RAM-only behavior. A bounded in-process event bus fans alert/outage transitions to WebSocket clients and disconnects subscribers that cannot keep up.

**Tech stack:** Go 1.22, modernc.org/sqlite, github.com/coder/websocket, stdlib HTTP/gRPC test fakes.

## Part A — reviewed Task 2 fixes

1. Add focused failing tests for retention option mapping, RAM fallback/logging, flush-worker shutdown, power-source freshness, periodic WAN rediscovery, and override precedence.
2. Extract SQLite option construction so `minute_days` and `quarter_days` are converted to durations and directly testable.
3. Give `TieredReader` an injectable error logger, log a persistent-query failure once, and fall back to RAM for both errors and empty persistent results.
4. Track the history flush worker with a done channel and join it before the final flush and database close.
5. Add `power_source` to dish status. Refresh only the newest history power sample at metadata cadence when status power is unavailable; retain hourly full reconciliation.
6. Add a periodic WAN discovery worker and make explicit interface override the first discovery choice.
7. Run race tests, vet, and static Linux/arm64 build; commit Part A with review findings in the body.

## Part B — outage timeline

1. Extend dish snapshots with history-reported outage records and explicit reachability/failure timing.
2. Add `internal/outage` with deterministic merge/dedup and state transitions for dish reports, gRPC reachability, and 30-second path failures.
3. Persist closed entries through a narrow persistence interface; add SQLite outage insert/query methods and retention-cap coverage.
4. Add an in-process bounded event bus for outage/alert transitions.
5. Add `/api/outages?span=` and fake-driven merge/API tests.

## Part B — alerts and delivery

1. Extend UCI alert config with explicit enable and threshold option names and parser tests.
2. Implement the catalog excluding the explicitly deferred `failover_event`: threshold-boundary, fire-once, clear-once, duration, path-clear hysteresis, and dish-unreachable suppression tests first.
3. Implement nonblocking bounded delivery with drop-oldest logging, exact webhook JSON, three attempts with injectable exponential backoff, and ntfy severity headers.
4. Persist fire/clear transitions to SQLite events and expose `/api/events?span=`.
5. Wire a one-second injectable evaluation loop to poller, WAN, outage timeline, RAM history, persistence, delivery, and event bus.

## Part B — WebSocket and completion

1. Add coder/websocket and `/api/ws` under the existing bearer/query-token authentication.
2. Send one-second `{t,dish,wan}` frames and async `{event}` frames using the same snapshot JSON types.
3. Bound subscriber buffers and disconnect on overflow; ensure request cancellation/server shutdown closes connections.
4. Add auth, cadence, async-event, and overflow tests.
5. Run race tests, vet, and CGO-disabled Linux/arm64 build; inspect the final diff and commit Task 3 separately.
