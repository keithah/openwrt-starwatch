# Starwatch Diagnostics Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add corrected dish diagnostic status fields and a token-authenticated, read-only derived diagnostics summary endpoint.

**Architecture:** Copy protobuf status fields into typed `internal/dish` models, retain router ping values from the existing router status poll, and derive summaries in a new pure `internal/diagnostics` package. Keep `internal/api` responsible for span validation, dependency reads, and JSON delivery only.

**Tech Stack:** Go 1.24, vendored protobuf/gRPC types, bounded RAM history, sqlite aggregate tiers, `net/http`, table-driven unit tests.

## Global Constraints

- One conventional feature commit.
- Read-only and pure derivation: no gRPC writes or new router RPCs.
- No battery, `/api/router`, Wi-Fi/client work, dish control, SPA, or packaging changes.
- Corrected JSON is `pnt_filter_state`; protobuf enum strings are emitted verbatim.
- Supported spans are exactly `15m`, `3h`, `24h`, `7d`, and `30d`.
- Histogram edges are inclusive `20, 40, 60, 80, 100, 150, 200, 500`, then open `null`.

---

### Task 1: Dish and Existing-Router Snapshot Inputs

**Files:**
- Modify: `router/internal/dish/snapshot.go`
- Modify: `router/internal/dish/poller.go`
- Modify: `router/internal/dish/client_test.go`
- Modify: `router/internal/dish/poller_test.go`
- Modify: `router/internal/dish/router.go`
- Modify: `router/internal/dish/router_test.go`

**Interfaces:**
- Produces: `dish.GPS`, optional `dish.Status.GPS`, status slot/disablement fields, and local `dish.StarlinkRouter` ping fields.
- Consumes: the existing `DishGetStatusResponse` and `WifiGetStatusResponse` returned by current polls.

- [x] **Step 1: Add failing status tests**

  Extend `cannedResponse` with `DishGpsStats`, `SecondsToFirstNonemptySlot`, and `DisablementCode`. Assert `FILTER_CONVERGED`, `OKAY`, scalar values, and the `pnt_filter_state` JSON key. Add three absent-GPS polls asserting no `gps` object and unavailable `gps` availability.

- [x] **Step 2: Run the dish tests and confirm RED**

  Run: `go test ./internal/dish -run 'GPS|Diagnostic|RouterPing'`

  Expected: compile/assertion failure because the typed fields do not exist.

- [x] **Step 3: Add the typed local snapshot fields**

  Add:

  ```go
  type GPS struct {
      Valid bool `json:"valid"`
      Satellites uint32 `json:"satellites"`
      Inhibited bool `json:"inhibited"`
      NoSatellitesAfterTTFF bool `json:"no_satellites_after_ttff"`
      PNTFilterState string `json:"pnt_filter_state"`
  }
  ```

  Add `GPS *GPS`, `SecondsToFirstNonemptySlot float32`, and
  `DisablementCode string` to `dish.Status`, plus `FieldGPS`. Copy all enum
  values with `.String()`. On absent GPS call `failed(FieldGPS)` and leave the
  pointer nil; on status RPC failure include `FieldGPS` in the existing failure
  set.

  Extend `StarlinkRouter` with optional/local router ping latency, success, and
  last-success age derived from the existing `WifiGetStatus` response.

- [x] **Step 4: Run dish tests and confirm GREEN**

  Run: `go test ./internal/dish`

  Expected: PASS.

### Task 2: Pure Diagnostics Derivation

**Files:**
- Create: `router/internal/diagnostics/diagnostics.go`
- Create: `router/internal/diagnostics/diagnostics_test.go`
- Modify: `router/internal/history/store.go`
- Modify: `router/internal/history/sqlite.go`
- Modify: `router/internal/history/sqlite_test.go`

**Interfaces:**
- Consumes: `diagnostics.Input{Now, Since, Span, Latency, Power, Snapshot, WAN, Outages}`.
- Produces: `diagnostics.Response` and `diagnostics.Summarize(Input) Response`.
- History points gain internal `Samples int64` with `json:"-"`; raw samples default to weight one and sqlite aggregate queries populate stored sample counts.

- [x] **Step 1: Write failing pure-function tests**

  Add table-driven tests for nearest-rank P95 boundaries, inclusive bucket
  assignment, aggregate `Approximate`, drop-rate clamps at `0`, `1`, and `>1`,
  overlapping clipped outages, known power values, and empty input availability.

- [x] **Step 2: Run diagnostics tests and confirm RED**

  Run: `go test ./internal/diagnostics`

  Expected: package or symbol missing.

- [x] **Step 3: Implement minimal pure summaries**

  Define typed response models with explicit JSON tags. Filter with
  `math.IsNaN`/`math.IsInf`; use positive-only power; compute weighted mean;
  sort latency values for nearest-rank P95; place values in the first bucket
  whose inclusive edge contains them; clamp success with `min(max(1-drop,0),1)`;
  clip and union outage intervals; emit availability reasons when a summary has
  no valid values.

- [x] **Step 4: Preserve aggregate sample weights**

  Add `Samples int64` with JSON tag `json:"-"` to `history.Point`, select `samples` in
  `QueryTier`, and test that persisted points retain the count without adding a
  JSON field.

- [x] **Step 5: Run diagnostics and history tests and confirm GREEN**

  Run: `go test ./internal/diagnostics ./internal/history`

  Expected: PASS.

### Task 3: Authenticated HTTP Endpoint and Span Allowlist

**Files:**
- Create: `router/internal/api/diagnostics.go`
- Create: `router/internal/api/diagnostics_test.go`
- Modify: `router/internal/api/server.go`
- Modify: `router/cmd/starwatchd/main.go`
- Modify: `router/cmd/starwatchd/main_test.go`

**Interfaces:**
- Consumes: existing `Deps.Snapshot`, `Deps.History`, `Deps.WAN`, `Deps.Outages`, plus `RAMRetention time.Duration`.
- Produces: token-authenticated `GET /api/diagnostics?span=<allowed>`.

- [x] **Step 1: Add failing handler tests**

  Test authentication, a populated response, `approximate:true` from a non-RAM
  tier, empty availability objects, and 400 responses for arbitrary parseable
  durations such as `1h` on both diagnostics and history.

- [x] **Step 2: Run API tests and confirm RED**

  Run: `go test ./internal/api -run 'Diagnostics|HistoryRejectsUnsupportedSpan'`

  Expected: 404 or assertion failure before the route/allowlist exists.

- [x] **Step 3: Add the thin handler and runtime wiring**

  Register `GET /api/diagnostics` through `s.auth`. Parse an allowed span,
  query latency and power with limit zero, query outages from the same `since`,
  merge the current WAN snapshot, call `diagnostics.Summarize`, and map unknown
  series/span to 400. Pass configured RAM retention from `runConfig`.

- [x] **Step 4: Run API and command tests and confirm GREEN**

  Run: `go test ./internal/api ./cmd/starwatchd`

  Expected: PASS.

### Task 4: Full Verification and One Commit

**Files:**
- Review all files changed by Tasks 1-3 and the approved design/plan.

- [x] **Step 1: Format and inspect scope**

  Run: `gofmt -w` on changed Go files, then `git diff --check` and
  `git diff --stat`. Confirm no battery, `/api/router`, SPA, packaging, control,
  Wi-Fi/client, or protobuf-vendor changes.

- [x] **Step 2: Run race tests**

  Run: `cd router && go test -race ./...`

  Expected: PASS with zero failing packages.

- [x] **Step 3: Run vet**

  Run: `cd router && go vet ./...`

  Expected: exit 0.

- [x] **Step 4: Cross-build**

  Run: `cd router && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build ./...`

  Expected: exit 0.

- [x] **Step 5: Commit once**

  Stage only scoped files and create `feat(diagnostics): add phase one summaries`.
  The body lists GPS/PNT, slot, disablement fields and the inclusive
  `20/40/60/80/100/150/200/500/null ms` distribution edges.
