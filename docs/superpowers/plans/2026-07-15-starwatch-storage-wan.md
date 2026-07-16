# Starwatch Review Fixes, Storage, and WAN Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Correct the reviewed telemetry edge cases, then add Starwatch's pure-Go sqlite history tier and read-only WAN monitor as a separate commit.

**Architecture:** Part A keeps monotonic time-series ingestion inside the dish poller, makes history reconciliation clock-aware, and stabilizes API-facing dish types. Part B composes the existing RAM store with a sqlite persistence layer behind tier-aware reader interfaces, while an injectable WAN monitor writes router/probe samples and publishes a snapshot consumed by both status and `/api/wan`.

**Tech Stack:** Go 1.22, gRPC-Go, `modernc.org/sqlite`, Linux routing/sysfs/socket APIs with non-Linux stubs, `net/http`.

## Global Constraints

- Preserve module name `starwatch`, static `CGO_ENABLED=0` Linux/arm64 builds, and Go 1.22 compatibility.
- Tests use only in-process fakes, temp files, and loopback servers; WAN probing is injected.
- Part A and Part B are separate conventional commits, each independently race-tested, vetted, and cross-compiled.
- Do not add alerts processing, WebSocket, SPA, mwan3 integration, obstruction maps, dish controls, or packaging.

---

### Task 1: Part A telemetry regressions

**Files:**
- Modify: `starlink/openwrt/router/internal/dish/poller.go`
- Modify: `starlink/openwrt/router/internal/dish/snapshot.go`
- Modify: `starlink/openwrt/router/internal/dish/poller_test.go`

**Interfaces:**
- Produces: monotonic `append` guarded by a per-series high-water timestamp, hourly `get_history`, clock-sane deferred startup backfill, power fallback, and local JSON outage/alert models.

- [x] Add failing fake-gRPC tests for recovery reconciliation ordering/deduplication, ring-wrap decode, hourly history reconciliation/power fallback, and bad-clock-to-sane deferred backfill.
- [x] Run focused dish tests and confirm each regression fails for the intended reason.
- [x] Add a history interval option, two-second RPC default, per-series high-water marks, and `backfillDone` state; centralize guarded appends and newest-history power projection.
- [x] Replace protobuf snapshot fields with local outage and named-alert JSON structures.
- [x] Run focused and package tests until green.

### Task 2: Part A parser and daemon hardening

**Files:**
- Modify: `starlink/openwrt/router/internal/config/uci.go`
- Modify: `starlink/openwrt/router/internal/config/uci_test.go`
- Modify: `starlink/openwrt/router/cmd/starwatchd/main.go`
- Modify: `starlink/openwrt/router/cmd/starwatchd/main_test.go`

**Interfaces:**
- Produces: whitespace-agnostic UCI token splitting and an HTTP server with `ReadHeaderTimeout: 5*time.Second` plus empty-token startup warning.

- [x] Add failing tab-delimited UCI and server-configuration tests.
- [x] Run focused tests and confirm failures.
- [x] Implement whitespace splitting, timeout, and warning.
- [x] Run Part A verification and commit with a body enumerating all review findings addressed.

### Task 3: Persistent sqlite history tier

**Files:**
- Create: `starlink/openwrt/router/internal/history/sqlite.go`
- Create: `starlink/openwrt/router/internal/history/tiered.go`
- Test: `starlink/openwrt/router/internal/history/sqlite_test.go`
- Modify: `starlink/openwrt/router/internal/history/store.go`

**Interfaces:**
- Produces: `OpenPersistent`, one-transaction `Flush`, lifecycle `AddEvent`, tier-aware `QuerySpan`, corruption recovery, and schemas for minute, quarter, events, outages, and speedtests.

- [x] Add failing temp-database tests for schema, minute/quarter min-average-max aggregation, retention, event caps, clock sanity, and corruption recovery.
- [x] Run focused history tests and confirm failures.
- [x] Implement pure-Go sqlite open/verify/recreate, aggregation, pruning, and tier selection.
- [x] Run focused history tests until green.

### Task 4: Tier-aware history API and daemon persistence wiring

**Files:**
- Modify: `starlink/openwrt/router/internal/api/server.go`
- Modify: `starlink/openwrt/router/internal/api/server_test.go`
- Modify: `starlink/openwrt/router/cmd/starwatchd/main.go`
- Modify: `starlink/openwrt/router/cmd/starwatchd/main_test.go`

**Interfaces:**
- Produces: `/api/history` responses containing `tier`, average `value`, and optional `min`/`max`; daemon lifecycle events and periodic single-transaction flushes.

- [x] Add failing API tier-selection and daemon graceful-sqlite-failure tests.
- [x] Run focused tests and confirm failures.
- [x] Wire the persistent store, flush cadence, lifecycle events, and tiered reader without making sqlite fatal.
- [x] Run focused tests until green.

### Task 5: Read-only WAN monitor

**Files:**
- Create: `starlink/openwrt/router/internal/wan/monitor.go`
- Create: `starlink/openwrt/router/internal/wan/discovery_linux.go`
- Create: `starlink/openwrt/router/internal/wan/discovery_other.go`
- Create: `starlink/openwrt/router/internal/wan/probe_linux.go`
- Create: `starlink/openwrt/router/internal/wan/probe_other.go`
- Test: `starlink/openwrt/router/internal/wan/monitor_test.go`
- Modify: `starlink/openwrt/router/internal/dish/snapshot.go`
- Modify: `starlink/openwrt/router/internal/api/server.go`
- Modify: `starlink/openwrt/router/internal/api/server_test.go`
- Modify: `starlink/openwrt/router/cmd/starwatchd/main.go`

**Interfaces:**
- Produces: injectable `Prober`, interface discovery, 30-second/5-minute probe windows, sysfs byte-rate sampling, WAN snapshot, and authenticated `GET /api/wan`.

- [x] Add failing tests using a fake prober and fake sysfs tree for discovery fallbacks, rolling loss/RTT, byte-rate history writes, snapshot JSON, and `/api/wan`.
- [x] Run focused tests and confirm failures.
- [x] Implement platform-specific discovery/probing and portable monitor logic, then wire it into the daemon and API.
- [x] Run focused tests until green.

### Task 6: Part B verification and commit

**Files:**
- Modify only files above as verification reveals defects.

- [x] Run `gofmt`, `go mod tidy`, `go test -race ./...`, `go vet ./...`, and `CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build ./...`.
- [x] Re-read spec §§6, 8, 9, and 11; inspect scoped diff and `git diff --check` for scope or contract gaps.
- [x] Commit Part B with a conventional commit message and confirm the scoped worktree is clean.
