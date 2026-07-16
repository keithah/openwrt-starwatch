# Starwatch Task 4 Implementation Plan

> **For Codex:** Execute this plan test-first, preserving the two requested commit boundaries.

**Goal:** Address the Task 3 review findings, then add audited dish controls, obstruction-map delivery, and an honest asynchronous speed-test state machine.

**Architecture:** Keep dish RPC details in `internal/dish`, HTTP parsing/rendering in `internal/api`, lifecycle wiring in `cmd/starwatchd`, and durable rows in the existing `internal/history` SQLite tier. Extend the poller snapshot for obstruction grids, use narrow interfaces for controls and speed tests, and reuse the event bus plus outage/alert suppression hooks.

**Tech Stack:** Go 1.22, gRPC/protobuf, modernc.org/sqlite, stdlib HTTP/image/png, coder/websocket.

---

### Task 1: Review fixes

- [ ] Add regressions for bounded outage dedup state, 60-second obstruction-average caching, and alert-default parity.
- [ ] Prune stale dish outage keys, cache successful 24-hour obstruction averages, and derive config defaults from `alert.DefaultRules`.
- [ ] Run race tests, vet, and the requested Linux cross-build; commit Part A with findings in the body.

### Task 2: Dish RPC and control layer

- [ ] Add fake-server tests for every new request and exact `apply_*` flags.
- [ ] Add typed wrappers for controls, obstruction maps, and speed-test RPCs.
- [ ] Add an audited controller that re-reads config after writes and invokes reboot/clear-map hooks.

### Task 3: Obstruction map pipeline and API

- [ ] Test periodic/on-demand map refresh, cache invalidation, JSON, unreachable handling, and PNG pixel classes.
- [ ] Add poller map cadence and snapshot types.
- [ ] Add `/api/obstruction-map` JSON/PNG rendering with stale inline refresh.

### Task 4: Speed-test state machine and persistence

- [ ] Test running/conflict/completion/unsupported states, durable result writes, and event publication.
- [ ] Implement a single-flight asynchronous manager around `start_speedtest` and `get_speedtest_status`.
- [ ] Extend SQLite flushing for completed speed-test rows and expose GET/POST `/api/speedtest`.

### Task 5: Integration and verification

- [ ] Wire poll-map cadence, controls, suppression hooks, speed tests, persistence, and API dependencies in `main.go`.
- [ ] Run focused tests, then `go test -race ./...`, `go vet ./...`, and the requested aarch64-or-arm64 static build.
- [ ] Review the diff for scope exclusions and commit Part B conventionally.
