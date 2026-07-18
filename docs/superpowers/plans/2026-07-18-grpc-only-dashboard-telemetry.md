# gRPC-only Dashboard Telemetry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make dashboard telemetry exclusively dish-gRPC sourced and replace every current-data card with an explicit Starlink-disconnected state whenever the dish is unreachable.

**Architecture:** Put the source allowlist and reachability predicate in `dashboard-model.js`, then make `app.js` use those pure decisions for history selection and section rendering. Keep WAN collection/API behavior unchanged; components receive only the allowed dish data and render a dedicated disconnected state rather than hiding content with CSS alone.

**Tech Stack:** Preact, `htm`, static ES modules, browser logic harness, Go embedded filesystem and API tests.

## Global Constraints

- Dashboard telemetry uses only `dish_down_bps`, `dish_up_bps`, `latency_ms`, `drop_rate`, and `power_w`.
- Never fall back to router counters or WAN probes in the Telemetry card or header.
- When `dish_reachable:false`, render no current-data cards and show `STARLINK DISCONNECTED` plus `WAITING FOR DISH`.
- Settings and historical Events remain reachable.
- Do not change daemon polling, REST endpoints, history storage, routing, controls, packaging, or feed behavior.
- Use no new dependencies or build step.

---

### Task 1: Enforce the gRPC-only telemetry allowlist

**Files:**
- Modify: `router/web/test.html`
- Modify: `router/web/dashboard-model.js`
- Modify: `router/web/logic.js`
- Modify: `router/web/app.js`
- Modify: `router/web/cards.js`

**Interfaces:**
- Produces: `DISH_GRAPH_SERIES`, an object mapping graph tabs to dish-only history series arrays.
- Produces: `starlinkConnected(snapshot)`, returning true only for `dish_reachable === true`.
- Produces: `liveFrameValues(frame)`, returning only live dish-series values.

- [ ] **Step 1: Write the failing source-boundary tests**

In `router/web/test.html`, import `DISH_GRAPH_SERIES` and `starlinkConnected`
from `dashboard-model.js`, replace the router-append assertion, and add:

```js
assert('throughput history is dish gRPC only', DISH_GRAPH_SERIES.throughput.join(',') === 'dish_down_bps,dish_up_bps');
assert('latency history is dish gRPC only', DISH_GRAPH_SERIES.latency.join(',') === 'latency_ms');
assert('loss history is dish gRPC only', DISH_GRAPH_SERIES.loss.join(',') === 'drop_rate');
assert('power history is dish gRPC only', DISH_GRAPH_SERIES.power.join(',') === 'power_w');
assert('WAN-only frame yields no telemetry values', Object.values(liveFrameValues(disconnectedFrame)).every(value => value == null));
assert('strict reachability controls dashboard data', starlinkConnected({dish_reachable: true}) && !starlinkConnected({dish_reachable: false}) && !starlinkConnected({}));
```

- [ ] **Step 2: Run the browser harness and verify RED**

Run a local static server and Chromium:

```bash
cd router
python3 -m http.server 8765 --bind 127.0.0.1 --directory web
chromium --headless --no-sandbox --disable-gpu --virtual-time-budget=15000 --dump-dom http://127.0.0.1:8765/test.html
```

Expected: the harness reports missing `DISH_GRAPH_SERIES` or the WAN-only live
frame still exposes `router_down_bps`.

- [ ] **Step 3: Add the pure source policy**

In `router/web/dashboard-model.js`, export:

```js
export const DISH_GRAPH_SERIES = Object.freeze({
  throughput: Object.freeze(['dish_down_bps', 'dish_up_bps']),
  latency: Object.freeze(['latency_ms']),
  loss: Object.freeze(['drop_rate']),
  power: Object.freeze(['power_w']),
});

export function starlinkConnected(snapshot = {}) {
  return snapshot.dish_reachable === true;
}
```

In `router/web/logic.js`, make `liveFrameValues` return only:

```js
return {
  dish_down_bps: dish?.downlink_throughput_bps,
  dish_up_bps: dish?.uplink_throughput_bps,
  latency_ms: dish?.latency_ms,
  drop_rate: dish?.drop_rate,
  power_w: dish?.power_w,
};
```

In `router/web/app.js`, import and use `DISH_GRAPH_SERIES` instead of the local
`graphSeries` object. In `router/web/cards.js`, remove router/WAN graph labels,
remove the WAN-only branch, use eyebrow `1 Hz · dish gRPC`, and replace the
throughput note with `Throughput comes directly from the Starlink terminal.`

- [ ] **Step 4: Run the browser harness and verify GREEN**

Run the same server and Chromium command. Expected: all source-boundary
assertions pass and `body[data-result="pass"]` is present.

---

### Task 2: Render a single explicit disconnected state

**Files:**
- Modify: `router/web/test.html`
- Modify: `router/web/logic.js`
- Modify: `router/web/dashboard.js`
- Modify: `router/web/app.js`
- Modify: `router/web/styles.css`

**Interfaces:**
- Consumes: `starlinkConnected(snapshot)` from Task 1.
- Produces: `DisconnectedState`, a presentational component with no WAN values.
- Produces: `SectionHeader` behavior that omits `.header-metrics` when disconnected.

- [ ] **Step 1: Write failing disconnected-state tests**

In `router/web/test.html`, import `SectionHeader` and `DisconnectedState`, then
render a snapshot containing stale dish and active WAN values:

```js
const disconnectedUI = document.createElement('div');
document.body.append(disconnectedUI);
render(h(SectionHeader, {
  section: 'overview',
  snapshot: {
    topology: 'wan-only',
    dish_reachable: false,
    dish: {downlink_throughput_bps: 999999},
    wan: {router_down_bps: 888888},
  },
  connection: 'live',
}), disconnectedUI);
assert('disconnected header is explicit', disconnectedUI.textContent.includes('STARLINK DISCONNECTED'));
assert('disconnected header waits for dish', disconnectedUI.textContent.includes('WAITING FOR DISH'));
assert('disconnected header has no telemetry strip', !disconnectedUI.querySelector('.header-metrics'));
render(h(DisconnectedState), disconnectedUI);
assert('disconnected panel mentions no WAN data', disconnectedUI.textContent.includes('Starlink disconnected') && !disconnectedUI.textContent.includes('WAN'));
render(null, disconnectedUI);
disconnectedUI.remove();
```

Update the existing `deriveState` expectation from `WAN-only` to
`STARLINK DISCONNECTED`.

- [ ] **Step 2: Run the browser harness and verify RED**

Run the Task 1 Chromium harness. Expected: `DisconnectedState` is not exported,
the header still contains `.header-metrics`, or the state label remains
`WAN-only`.

- [ ] **Step 3: Implement disconnected rendering**

In `router/web/logic.js`, return `STARLINK DISCONNECTED` when topology is
`wan-only` or `dish_reachable` is false.

In `router/web/dashboard.js`:

```js
export function DisconnectedState() {
  return html`<section class="card disconnected-state" role="status">
    <span class="eyebrow">TERMINAL</span>
    <h2>Starlink disconnected</h2>
    <p>No Starlink terminal is reachable over gRPC. Telemetry will resume automatically when the dish reconnects.</p>
  </section>`;
}
```

Make `SectionHeader` use dish fields only. When disconnected, omit
`.header-metrics`, render `WAITING FOR DISH`, and do not render Customize.

In `router/web/app.js`, import `starlinkConnected` and `DisconnectedState`.
Before rendering section cards, return `DisconnectedState` for every section
except Settings and Events. On Events while disconnected, render only
`EventsView`. Gate every card's `available` value with the reachability
predicate so the Customize model cannot present stale current-data cards.

In `router/web/styles.css`, add a centered `.disconnected-state` treatment using
existing `--amber`, `--muted`, `--border`, and background tokens. Add no raw
colors.

- [ ] **Step 4: Run the browser harness and verify GREEN**

Run the Task 1 Chromium harness. Expected: every assertion passes, including
the disconnected header and panel tests.

---

### Task 3: Align documentation and verify the complete artifact

**Files:**
- Modify: `README.md`
- Modify: `STARWATCH-SPEC.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: final behavior from Tasks 1 and 2.
- Produces: public documentation that does not promise WAN telemetry in the disconnected dashboard.

- [ ] **Step 1: Update public behavior text**

Document that dashboard Telemetry is dish-gRPC-only, a disconnected dish hides
all current-data cards, Settings and Events remain reachable, and data cards
return automatically after reconnection. Replace the Unreleased changelog text
that currently says router/WAN history remains visible.

- [ ] **Step 2: Run documentation and source scans**

Run:

```bash
rg -n "Router/WAN history may still be shown|WAN-only mode.*WAN health|router_down_bps|wan_probe_rtt_ms" README.md STARWATCH-SPEC.md CHANGELOG.md router/web
git diff --check
```

Expected: no stale UI promises or router/WAN graph series remain; the only
source-code references are backend/API responsibilities outside this SPA scope.

- [ ] **Step 3: Run full verification**

Run from `router/`:

```bash
go test -race ./...
go vet ./...
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build ./...
```

Then rerun the headless browser harness and require `body[data-result="pass"]`.
Expected: all commands exit zero.

- [ ] **Step 4: Commit and push**

```bash
git add README.md STARWATCH-SPEC.md CHANGELOG.md router/web/app.js router/web/cards.js router/web/dashboard.js router/web/dashboard-model.js router/web/logic.js router/web/styles.css router/web/test.html docs/superpowers/plans/2026-07-18-grpc-only-dashboard-telemetry.md
git commit -m "fix(dashboard): require dish gRPC for telemetry"
git push origin main
```

- [ ] **Step 5: Deploy and verify the router without changing packaging**

Build `package/out/starwatchd-bin`, transfer it to
`100.87.232.42:/tmp/starwatchd.new`, verify its SHA-256, stop only Starwatch,
atomically replace `/usr/bin/starwatchd`, and start Starwatch. Confirm:

```text
/etc/init.d/starwatch status => running
/proc/<pid>/exe SHA-256 => local build SHA-256
/api/status => topology=wan-only, dish_reachable=false
```

Open the embedded dashboard and verify it contains `STARLINK DISCONNECTED`,
`WAITING FOR DISH`, no header metric strip, and no WAN/Telemetry cards.
