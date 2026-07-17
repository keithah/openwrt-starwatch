# Router Client Rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the first safe topology-B router mutation: authenticated client rename with read-merge and readback confirmation.

**Architecture:** Keep router protocol reads/writes behind a small injectable controller that the HTTP handler calls. Reuse the existing typed router snapshot for topology, reachability, revision, and MAC lookup; use the targeted 3017 RPC only after a fresh config reread. Preserve all `ClientConfig` fields by protobuf cloning before changing `given_name`.

**Tech Stack:** Go, `net/http`, gRPC status codes, vendored Starlink protobufs, existing in-process Handle fake, history/live event publishers.

## Global Constraints

- Base is `origin/main` at `3ed9c742`.
- One conventional feature commit, then push `origin/main`.
- This phase permits client rename only; client block, Wi-Fi/radio writes, SPA write UI, packaging, and live mutation are excluded.
- Request JSON rejects unknown fields and is capped at 128 KiB.
- The only write RPC is `WifiSetClientGivenName` request field 3017.

---

### Task 1: Warming router API response

**Files:**
- Modify: `router/internal/api/router.go`
- Modify: `router/internal/api/router_test.go`

**Interfaces:**
- Produces: a 200 typed response with `reachable:false` and three unavailable
  router availability objects when topology B exists but no router snapshot is
  cached.

- [x] Write `TestRouterEndpointReturnsWarmingResponse` using a full-topology
  snapshot with `StarlinkRouter:nil`; assert 200, `reachable:false`, and
  reason `router telemetry warming up`.
- [x] Run `go test ./internal/api -run Warming -count=1`; observe the existing
  handler to return 503.
- [x] Add the warming branch before the unreachable 503 branch in `router.go`.
- [x] Rerun the focused test; PASS.

### Task 2: Targeted rename controller and endpoint

**Files:**
- Create: `router/internal/dish/router_control.go`
- Create: `router/internal/api/router_control.go`
- Modify: `router/internal/api/server.go`
- Modify: `router/internal/api/router_test.go`

**Interfaces:**
- Consumes: a `dish.RouterMutationClient` with `WifiGetConfig`,
  `WifiGetClients`, and `WifiSetClientGivenName` methods; current router
  snapshot; event publishers.
- Produces: `RenameClient(context.Context, mac, revision, givenName string)`
  and `PATCH /api/router/clients/{mac}`.

- [x] Write fake Handle-server tests for accepted rename, stale revision with
  no write, confirmation/empty-name/unknown-field failures, unsupported and
  upstream RPC mappings, readback mismatch, mixed MAC normalization, and
  rejected `blocked`/Wi-Fi fields.
- [x] Run `go test ./internal/api -run Rename -count=1`; observe missing route
  or controller failures.
- [x] Implement strict request decoding and status mapping; use only
  `WifiSetClientGivenName` after snapshot and fresh-incarnation checks.
- [x] Clone the matching `ClientConfig`, change only `GivenName`, and confirm
  post-write client/config readback before returning accepted.
- [x] Rerun focused rename tests; PASS.

### Task 3: Auditing, secret hygiene, and documentation

**Files:**
- Modify: `router/internal/api/router_control.go`
- Modify: `router/internal/api/router_test.go`
- Modify: `API.md`

**Interfaces:**
- Produces: one persistent/live `router_control` event with action,
  normalized MAC, requested name, result, and client ID after a confirmed
  rename.

- [x] Write a successful-rename assertion that event detail has rename fields
  and neither HTTP output nor event detail contains a surrounding config
  password or weekly schedule loss.
- [x] Run `go test ./internal/api -run Rename -count=1`; observe audit failure.
- [x] Add event emission through the existing API event dependencies and
  document rename-only scope and best-effort incarnation check in `API.md`.
- [x] Rerun focused tests; PASS.

### Task 4: Full verification and release

- [x] Run `gofmt`, `git diff --check`, and grep router-control sources for
  write RPCs other than `WifiSetClientGivenName`.
- [x] Run `cd router && go test -race ./...`.
- [x] Run `cd router && go vet ./...`.
- [x] Run `cd router && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build ./...`.
- [ ] Commit one conventional feature commit naming the targeted RPC and
  readback confirmation, then push `main` and compare local/remote SHAs.
