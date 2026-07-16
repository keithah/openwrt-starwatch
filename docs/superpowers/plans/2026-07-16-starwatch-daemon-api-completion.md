# Starwatch Daemon API Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete Starwatch's stable daemon API with safe settings mutation, mwan3 integration, opt-in location, and read-only Starlink-router telemetry.

**Architecture:** Add focused `internal/mwan` and runtime settings components behind injected interfaces, extend the dish poller only for location, and add a separate router poller. API handlers consume narrow interfaces and publish through the existing history/event infrastructure.

**Tech Stack:** Go 1.22, gRPC/protobuf, OpenWrt UCI/ubus/mwan3 commands behind interfaces, stdlib HTTP/JSON/crypto.

## Global Constraints

- Static build with `CGO_ENABLED=0 GOOS=linux GOARCH=arm64`.
- No real network, UCI, ubus, or mwan3 execution in tests.
- No SPA/static assets, packaging, or WebSocket frame changes.
- Only explicit failover-assist POST may modify system routing, and only `starwatch_*` sections.
- Final API wire formats match the approved design document.

---

### Task 1: GPS review fix

**Files:**
- Modify: `starlink/openwrt/router/internal/dish/controls.go`
- Test: `starlink/openwrt/router/internal/dish/controls_test.go`

**Interfaces:**
- Produces: `ControlParams.Enabled *bool`; `gps` requires a non-nil value.

- [ ] Write `TestGPSControlRequiresExplicitEnabled` using `ControlParams{Action:"gps"}` and assert `errors.Is(err, ErrInvalidControl)`.
- [ ] Run `go test ./internal/dish -run TestGPSControlRequiresExplicitEnabled` and observe the old silent-disable behavior fail.
- [ ] Change `Enabled` to `*bool`, reject nil for `gps`, dereference it for GPS, and adapt sleep schedule/API tests with a pointer helper.
- [ ] Run the package tests and the full verification matrix.
- [ ] Amend the design commit as `fix(starwatch): require explicit GPS state`, listing the review finding in the body.

### Task 2: Final availability and location contract

**Files:**
- Modify: `internal/dish/client.go`, `poller.go`, `snapshot.go`, associated tests
- Modify: `internal/config/config.go`, tests

**Interfaces:**
- Produces: `Availability{Available bool, Reason string}`, `Location`, `API.GetLocation`, and `Poller.SetLocationEnabled(bool)`.

- [ ] Add failing tests asserting object-valued availability, disabled-by-default location, successful LLA polling, and PermissionDenied/Unavailable reason text.
- [ ] Add `location_enabled` parsing and typed location RPC handling.
- [ ] Poll location at metadata cadence only when enabled; clear it when disabled and update detailed availability after successes/failures.
- [ ] Run `go test ./internal/config ./internal/dish` until green.

### Task 3: Starlink-router read-only poller

**Files:**
- Create: `internal/dish/router.go`, `router_test.go`
- Modify: `internal/dish/client.go`, `snapshot.go`, `cmd/starwatchd/main.go`

**Interfaces:**
- Produces: `RouterPoller`, `RouterSnapshot`, injected `GatewayResolver` and `RouterDialer`.

- [ ] Add a fake gRPC server test that records `get_device_info`, `wifi_get_clients`, and `wifi_get_status`, and fails if any other request appears.
- [ ] Implement plaintext dialing, typed read wrappers, topology gating, 60-second refresh, reachability transitions, and snapshot copying.
- [ ] Wire the router snapshot into `/api/status` without changing WS frames.
- [ ] Run focused dish/API tests.

### Task 4: mwan3 status and failover alert

**Files:**
- Create: `internal/mwan/manager.go`, `parse.go`, and tests
- Modify: `internal/dish/snapshot.go`, `internal/wan/monitor.go`
- Modify: `internal/alert/engine.go`, tests
- Modify: `internal/config/config.go`, tests

**Interfaces:**
- Produces: `Runner.Run(ctx,name,args,stdin)`, normalized `mwan.Status`, and event-only `failover_event` inputs.

- [ ] Add table tests for healthy/degraded ubus JSON, text fallback, and absent mwan3.
- [ ] Implement parsers and periodic status refresh; expose optional status through WAN snapshot.
- [ ] Add a failing alert test proving the first set is baseline, a changed active/online set fires once, identical sets do not repeat, and no clear event occurs.
- [ ] Add the default warning rule and UCI `failover_event_enabled` parsing, then implement canonical-set comparison.
- [ ] Run focused mwan/wan/alert/config tests.

### Task 5: Failover assist

**Files:**
- Create: `internal/mwan/assist.go`, tests
- Create: `internal/api/failover.go`, tests
- Modify: `internal/api/server.go`, `cmd/starwatchd/main.go`

**Interfaces:**
- Produces: `AssistResult{Available,Reason,Proposed}`, ordered `Change` tuples, `GET/POST /api/wan/failover-assist`.

- [ ] Add matrix tests for missing mwan3, custom config, fewer than two interfaces, and conservative GL ownership detection.
- [ ] Add an eligible fixture asserting exact `starwatch_*` tuples and deterministic backup selection.
- [ ] Implement GET eligibility and POST conflict behavior.
- [ ] Test that POST sends only the displayed changes through one UCI batch, restarts mwan3, refreshes status, and emits no commands when unavailable.
- [ ] Run focused mwan/API tests.

### Task 6: Loss-preserving UCI writer and runtime settings

**Files:**
- Modify: `internal/config/uci.go`, tests
- Create: `internal/config/manager.go`, tests
- Create: `internal/api/config.go`, tests
- Modify: `internal/api/server.go`, `cmd/starwatchd/main.go`

**Interfaces:**
- Produces: nested config view/update structs, `Manager.Snapshot`, `Manager.Update`, `Manager.RegenerateToken`, dynamic token provider, and component update callbacks.

- [ ] Add a fixture with comments, unknown options, lists, and sections; mutate known values and assert unknown source content survives.
- [ ] Implement line-preserving option replacement/insertion and atomic temp-file rename.
- [ ] Add HTTP tests for masked GET, safe partial PUT, every restart-managed rejection, persistence failure rollback, audit publication, and immediate token rotation.
- [ ] Implement candidate validation, serialized persistence-before-publication, `crypto/rand` token creation, and runtime callbacks for supported intervals/endpoints/rules/retention.
- [ ] Change auth to read the active token per request and add the config routes.
- [ ] Run config/API/main tests.

### Task 7: Integration and final verification

**Files:**
- Modify: `cmd/starwatchd/main.go`, `main_test.go`
- Update tests across affected packages

**Interfaces:**
- Consumes all prior managers and pollers.

- [ ] Wire lifecycles and shutdown joins; ensure missing optional facilities only omit fields.
- [ ] Run `gofmt`, `git diff --check`, and all focused tests.
- [ ] Run `go test -race ./...` and confirm zero failures.
- [ ] Run `go vet ./...` and confirm exit zero.
- [ ] Run `CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build ./...` and confirm exit zero.
- [ ] Review scope and commit as `feat(starwatch): complete daemon API surface`.
