# Starwatch Router, Dish Route, and Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the complete read-only topology-B router API, VPN-proof dish host-route healing, and accessible local dashboard card customization.

**Architecture:** Keep gRPC orchestration in the existing router poller and isolate typed mapping/math. Add an injectable dish-route reconciler to the dish discovery lifecycle. Drive dashboard cards from a stable registry and normalize versioned local preferences with pure functions.

**Tech Stack:** Go 1.24, vendored Starlink protobufs, OpenWrt ubus/ip/UCI, Preact/HTM, embedded static assets, POSIX shell.

## Global Constraints

- Base is canonical root-layout `main` at `a3de8a10`.
- One conventional feature commit, then push `origin/main`.
- Router RPCs are read-only; no Wi-Fi, client, or radio writes.
- Route writes may target only `192.168.100.1/32`; no default-route or firewall changes.
- No external frontend dependencies or network access.

---

### Task 1: Typed router mapping and polling

**Files:**
- Modify: `router/internal/dish/router.go`
- Create: `router/internal/dish/router_model.go`
- Modify: `router/internal/dish/snapshot.go`
- Modify: `router/internal/dish/router_test.go`

**Interfaces:**
- Produces: a deep-copyable `dish.StarlinkRouter` local model.
- Consumes: read-only `RouterAPI` methods for status, history, clients, config, radio stats, diagnostics, and interfaces.

- [x] Write fake-gRPC mapping tests covering device, ping, networks/security, credentials, clients, radios, and interfaces.
- [x] Run focused router-model tests.
- [x] Add typed DTOs and pure mapping functions, ensuring password values are never copied.
- [x] Extend the poller with per-read three-failure caches and deep-copy snapshots.
- [x] Verify focused router tests are green.

### Task 2: Authenticated router endpoint

**Files:**
- Create: `router/internal/api/router.go`
- Create: `router/internal/api/router_test.go`
- Modify: `router/internal/api/server.go`
- Modify: `API.md`

**Interfaces:**
- Consumes: the combined typed snapshot.
- Produces: authenticated `GET /api/router`, returning 503 without topology B/reachability.

- [x] Write endpoint tests for auth, topology/reachability 503, typed JSON, availability, enum names, and absence of passphrases/write routes.
- [x] Register and implement the thin endpoint.
- [x] Correct the API example and identifier notes.
- [x] Verify focused router API tests are green.

### Task 3: Daemon-managed dish host route

**Files:**
- Create: `router/internal/dishroute/manager.go`
- Create: `router/internal/dishroute/manager_test.go`
- Modify: `router/internal/dish/poller.go`
- Modify: `router/internal/dish/poller_test.go`
- Modify: `router/internal/config/config.go`
- Modify: `router/internal/config/config_test.go`
- Modify: `router/cmd/starwatchd/main.go`
- Modify: `router/cmd/starwatchd/main_test.go`

**Interfaces:**
- Produces: `Ensure(context.Context) error` with an injectable runner.
- Consumes: WAN ubus status, `ip` output, logging, persistence, and live events.

- [x] Write fake-runner tests for Speedify rejection, Starlink fallback, link scope, gate-off, idempotency, duplicate cleanup, exact-/32-only writes, logs, and events.
- [x] Implement derivation and reconciliation without shell execution in tests.
- [x] Add the config gate and call Ensure before startup/retry discovery.
- [x] Wire persistence/live events in daemon startup and verify focused config/poller/main tests.

### Task 4: First-boot fallback and policy docs

**Files:**
- Modify: `package/starwatchd/etc/uci-defaults/99-starwatch`
- Create: `package/tests/uci-defaults-route-test.sh`
- Modify: `package/Makefile`
- Modify: `package/starwatchd/etc/config/starwatch`
- Modify: `README.md`
- Modify: `STARWATCH-SPEC.md`

- [x] Add shell fixtures that reject a tunnel gateway, select on-link WAN/Starlink routes, preserve existing coverage, and use link scope only without a gateway.
- [x] Rewrite the first-boot derivation with documented Speedify/VPN defenses and idempotent guards.
- [x] Document the gate and narrow routing exception; verify existing kmwan/theme fixes remain.
- [x] Verify `make -C package test` is green.

### Task 5: Accessible dashboard customization

**Files:**
- Modify: `router/web/app.js`
- Modify: `router/web/cards.js`
- Modify: `router/web/logic.js`
- Modify: `router/web/styles.css`
- Modify: `router/web/test.html`
- Modify: `router/internal/api/server_test.go`

**Interfaces:**
- Produces: stable card registry, `normalizeCardPreferences`, `visibleCardOrder`, and drawer UI.
- Consumes: versioned/keyed localStorage and existing card components.

- [x] Add browser logic assertions for saved order, inserted new cards, hidden values, reset, and unknown pruning.
- [x] Implement pure normalization and versioned persistence.
- [x] Refactor dashboard rendering through the registry, including a separate router card when data exists.
- [x] Add modal drawer, pointer reorder, keyboard buttons, focus management, mobile sheet styling, theme parity, and reduced motion.
- [x] Extend static-serve assertions for the drawer assets and verify the static endpoint test.

### Task 6: Review, verify, commit, and push

- [x] Run formatting, shell syntax checks, `git diff --check`, and inspect scope for any write RPC.
- [x] Run `cd router && go test -race ./...`.
- [x] Run `cd router && go vet ./...`.
- [x] Run `cd router && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build ./...`.
- [x] Run `make -C package all` and inspect the built package assets.
- [x] Request an independent read-only review and fix substantive findings.
- [ ] Commit once with a conventional feature message whose body names derived ping fields, auth/tx-power mappings, and the exact dish `/32` exception.
- [ ] Push `main` and verify local/origin SHAs match.
