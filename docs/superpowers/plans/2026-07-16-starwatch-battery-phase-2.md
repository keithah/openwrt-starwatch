# Starwatch Battery Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add live-managed battery UCI configuration and honest terminal-only runtime estimates to diagnostics.

**Architecture:** Extend the existing loss-preserving config manager and DTOs for a dedicated battery section. Keep battery math pure in `internal/diagnostics`, fed by a separate 15-minute power query and the current public battery configuration.

**Tech Stack:** Go 1.24, OpenWrt UCI text persistence, `net/http`, RAM/sqlite history readers, table-driven tests.

## Global Constraints

- Base is canonical root-layout `main` at `171a3086`.
- One conventional feature commit, then push `origin/main`.
- No gRPC writes, `/api/router`, router telemetry, Wi-Fi/client work, dish-control changes, SPA, or packaging.
- UCI section is exactly `config battery`; SOC staleness is strictly greater than 24 hours.
- PUT rejects unknown JSON fields and bodies over 128 KiB through the existing handler.

---

### Task 1: Battery Configuration and UCI Persistence

**Files:**
- Modify: `router/internal/config/config.go`
- Modify: `router/internal/config/config_test.go`
- Modify: `router/internal/config/manager.go`
- Modify: `router/internal/config/manager_test.go`
- Modify: `router/internal/config/uci_test.go`
- Modify: `router/internal/api/config_test.go`

**Interfaces:**
- Produces: `config.BatteryConfig`, `config.BatteryView`, and `config.BatteryUpdate`.
- Consumes: the existing `ManagerOptions.Now`, `RewriteUCI`, audit, and live apply paths.

- [x] **Step 1: Write failing config/parser/API tests**

  Add battery load/view/update tests, table-driven bound violations, partial
  round-trip assertions, client timestamp rejection, server timestamp stamping,
  audit-event coverage, and unknown UCI section/option preservation.

- [x] **Step 2: Verify RED**

  Run: `go test ./internal/config ./internal/api -run 'Battery|ConfigAPI'`

  Expected: compile/assertion failures because battery DTOs and persistence do not exist.

- [x] **Step 3: Implement config types, parsing, validation, stamping, and UCI changes**

  Add typed battery fields with explicit JSON tags. Parse/write the dedicated
  section, validate capacity `(0,100000]`, SOC `[0,100]`, reserve `[0,95]`, and
  efficiency `[1,100]`. Stamp RFC3339Nano UTC time only when SOC is supplied.

- [x] **Step 4: Verify GREEN**

  Run: `go test ./internal/config ./internal/api -run 'Battery|ConfigAPI'`

  Expected: PASS.

### Task 2: Pure Battery Runtime Derivation

**Files:**
- Modify: `router/internal/diagnostics/diagnostics.go`
- Modify: `router/internal/diagnostics/diagnostics_test.go`

**Interfaces:**
- Consumes: `diagnostics.Input.Battery` and `diagnostics.Input.BatteryPower`.
- Produces: `diagnostics.Response.Battery` with typed runtime availability fields.

- [x] **Step 1: Write failing formula and honesty tests**

  Cover exact full/remaining runtime, disabled configuration, non-positive and
  non-finite loads, missing/stale power, insane clock, reserve at/above SOC,
  and SOC exactly 24 hours versus one nanosecond older.

- [x] **Step 2: Verify RED**

  Run: `go test ./internal/diagnostics -run Battery`

  Expected: compile failure because battery inputs and response do not exist.

- [x] **Step 3: Implement minimal battery summary math**

  Compute the weighted positive 15-minute mean, validate time freshness, derive
  Wh/W hours, and omit unavailable fields with reasons. Keep full-charge runtime
  independent from SOC staleness/reserve exhaustion.

- [x] **Step 4: Verify GREEN**

  Run: `go test ./internal/diagnostics -run Battery`

  Expected: PASS.

### Task 3: Diagnostics Handler Wiring

**Files:**
- Modify: `router/internal/api/diagnostics.go`
- Modify: `router/internal/api/diagnostics_test.go`

**Interfaces:**
- Consumes: the settings public battery view and a 15-minute `power_w` query.
- Produces: the Phase 2 battery object on every successful diagnostics response.

- [x] **Step 1: Write failing endpoint tests**

  Assert configured battery JSON, separate 15-minute power query, exact runtime
  values, disabled response shape, and absence of Phase 3 fields.

- [x] **Step 2: Verify RED**

  Run: `go test ./internal/api -run DiagnosticsBattery`

  Expected: missing battery response assertions fail.

- [x] **Step 3: Wire config and rolling load inputs**

  Query power with `since=now-15m`, map `Settings.View().Battery` to the pure
  input, and leave requested-span power statistics unchanged.

- [x] **Step 4: Verify GREEN and regressions**

  Run: `go test ./internal/api ./cmd/starwatchd`

  Expected: PASS.

### Task 4: Verify, Commit, and Push

**Files:**
- Review all scoped Phase 2 files and documents.

- [x] **Step 1: Format and inspect scope**

  Run `gofmt`, `git diff --check`, and inspect status/diff for forbidden Phase 3,
  SPA, package, control, and vendored-protobuf changes.

- [x] **Step 2: Run race tests**

  Run: `cd router && go test -race ./...`

- [x] **Step 3: Run vet**

  Run: `cd router && go vet ./...`

- [x] **Step 4: Cross-build**

  Run: `cd router && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build ./...`

- [x] **Step 5: Create and push one commit**

  Commit as `feat(battery): add runtime estimates`. The body names `config
  battery` and the strict `>24h` SOC staleness threshold, then push `main` to
  `origin/main` and verify identical SHAs.
