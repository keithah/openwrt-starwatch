# Starwatch Daemon Telemetry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first Starwatch increment: a statically cross-compilable daemon that loads UCI configuration, polls and backfills Starlink dish telemetry, retains second-resolution RAM history, and exposes authenticated status/history APIs.

**Architecture:** `internal/dish` owns the gRPC transport, topology state, availability counters, and the current typed snapshot. It writes time-series samples through the narrow `history.Writer` interface; `internal/api` reads snapshots and history through interfaces so later WAN and sqlite implementations can be added without changing callers. Generated upstream protobuf Go sources are kept in a local replacement module under `third_party/`.

**Tech Stack:** Go 1.22, gRPC-Go plaintext transport, protobuf generated sources from `github.com/clarkzjw/starlink-grpc-golang`, `net/http`, UCI text configuration.

## Global Constraints

- Module path is exactly `starwatch`, with `go 1.22`.
- Production builds use `CGO_ENABLED=0`; `GOOS=linux GOARCH=arm64 go build ./...` must pass.
- Dish API is `SpaceX.API.Device.Device/Handle`, plaintext, no authentication, default address `192.168.100.1:9200`.
- No tests may access the network outside their in-process listeners.
- Do not add sqlite, WAN probes/mwan3, alerts, WebSocket, SPA, or packaging.

---

### Task 1: Module and UCI configuration

**Files:**
- Create: `starlink/openwrt/router/go.mod`
- Create: `starlink/openwrt/router/internal/config/uci.go`
- Create: `starlink/openwrt/router/internal/config/config.go`
- Test: `starlink/openwrt/router/internal/config/uci_test.go`
- Test: `starlink/openwrt/router/internal/config/config_test.go`

**Interfaces:**
- Produces: `config.Load(path string) (*Config, error)` with typed `Main`, `History`, and `Alerts` settings and spec defaults.

- [ ] Write parser/load tests covering quoted UCI sections, all spec fields, defaults, whitespace-separated probe hosts, invalid numeric values, and validation.
- [ ] Run `go test ./internal/config` and confirm failure because the package does not exist.
- [ ] Port PeakDo's small UCI parser and implement typed loading with explicit range validation.
- [ ] Run `go test ./internal/config` and confirm success.

### Task 2: RAM history store

**Files:**
- Create: `starlink/openwrt/router/internal/history/store.go`
- Create: `starlink/openwrt/router/internal/history/ring.go`
- Test: `starlink/openwrt/router/internal/history/store_test.go`

**Interfaces:**
- Produces: `Store.Append(series string, point Point)`, `Store.Query(series string, since time.Time, limit int) ([]Point, error)`, and `Store.Series() []string`.
- Produces: `Reader` and `Writer` interfaces used by dish/API callers and replaceable by a later tiered sqlite store.

- [ ] Write tests for overwrite order, all §8.1 series names, span filtering, unknown-series errors, and deterministic downsampling to at most 1000 points.
- [ ] Run `go test ./internal/history` and observe the missing-package failure.
- [ ] Implement fixed-capacity float32/timestamp rings protected by a read/write mutex.
- [ ] Run `go test ./internal/history` and confirm success.

### Task 3: Vendored protobufs and typed dish client

**Files:**
- Create: `starlink/openwrt/router/third_party/starlink-grpc-golang/go.mod`
- Vendor: `starlink/openwrt/router/third_party/starlink-grpc-golang/pkg/**`
- Create: `starlink/openwrt/router/internal/dish/client.go`
- Test: `starlink/openwrt/router/internal/dish/client_test.go`

**Interfaces:**
- Produces: `Dial(ctx, addr)`, `Client.Close()`, and typed `GetStatus`, `GetDeviceInfo`, `GetHistory`, `DishGetConfig` methods.

- [ ] Copy the current upstream generated protobuf package and pin compatible gRPC/protobuf runtimes in the local replacement module.
- [ ] Write an in-process fake `DeviceServer` test that verifies each request oneof and typed response extraction.
- [ ] Run `go test ./internal/dish -run TestClient` and observe failure.
- [ ] Implement the plaintext gRPC connection and four request/response wrappers with deadlines inherited from callers.
- [ ] Run the client tests and confirm success.

### Task 4: Polling, backfill, topology, and availability

**Files:**
- Create: `starlink/openwrt/router/internal/dish/poller.go`
- Create: `starlink/openwrt/router/internal/dish/snapshot.go`
- Test: `starlink/openwrt/router/internal/dish/poller_test.go`

**Interfaces:**
- Produces: `Poller.Run(context.Context)`, `Poller.Snapshot() Snapshot`, topology values `full`/`wan-only`, and field availability map values.
- Consumes: the four-call `dish.API` interface and `history.Writer`.

- [ ] Write fake-server tests for startup history backfill, status cadence, 60-second metadata/config cadence via injectable intervals, three consecutive failures marking fields unavailable, first-success recovery, and unreachable-startup WAN-only retry.
- [ ] Run focused tests and confirm expected failures.
- [ ] Implement startup discovery, backfill, fast/slow tickers, telemetry projection, consecutive-failure accounting, and clean context cancellation.
- [ ] Run `go test ./internal/dish` and confirm success.

### Task 5: Authenticated HTTP API

**Files:**
- Create: `starlink/openwrt/router/internal/api/server.go`
- Test: `starlink/openwrt/router/internal/api/server_test.go`

**Interfaces:**
- Produces: `api.NewServer(Deps) http.Handler` with `GET /api/status` and `GET /api/history`.
- Consumes: a snapshot provider and `history.Reader`.

- [ ] Write handler tests for Bearer and query-token auth, empty-token denial, method routing, status JSON, series/span validation, RAM reads, and the 1000-point cap.
- [ ] Run `go test ./internal/api` and confirm failure.
- [ ] Implement constant-time auth and JSON handlers without CORS.
- [ ] Run `go test ./internal/api` and confirm success.

### Task 6: Daemon wiring and shutdown

**Files:**
- Create: `starlink/openwrt/router/cmd/starwatchd/main.go`
- Test: `starlink/openwrt/router/cmd/starwatchd/main_test.go`

**Interfaces:**
- Produces: `run(ctx, configPath, dependencies) error`, used by `main` with SIGINT/SIGTERM cancellation.

- [ ] Write tests for bind-address construction and cancellation-driven HTTP/poller shutdown using injectable construction hooks.
- [ ] Run `go test ./cmd/starwatchd` and confirm failure.
- [ ] Implement flag parsing, config load, RAM sizing, dish dial/poller wiring, HTTP serving, and bounded shutdown.
- [ ] Run daemon tests and confirm success.

### Task 7: Full verification and commit

**Files:**
- Modify only files created above as verification reveals issues.

- [ ] Run `gofmt` over authored Go files and `go mod tidy`.
- [ ] Run `go test -race ./...` and resolve every failure.
- [ ] Run `CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build ./...` and resolve every failure.
- [ ] Re-read the task and spec §§2.1, 3, 4.1, 4.2, 8.1, 8.2, and 9; inspect `git diff --check` and scoped status.
- [ ] Commit only `starlink/openwrt/router/` and this plan with `feat(starwatch): add daemon telemetry pipeline`.
