# Router Client Block Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add confirmed schedule-based client block/unblock and a topology-B client-management card.

**Architecture:** Extend the Phase 4 targeted mutation controller with one-mutation block/unblock operations that clone only the addressed `ClientConfig`. Retain request field 3017 because the fake demonstrates it applies the full client config including schedules. Drive the SPA card from `/api/router` and pure payload/retry helpers.

**Tech Stack:** Go, vendored Starlink protobufs, in-process gRPC Handle fake, Preact/HTM, embedded static assets.

## Global Constraints

- Base is `origin/main` at `688e1a6a`.
- One conventional feature commit, then push `origin/main`.
- The block encoding is one `starwatch-block` schedule with `[0,10080)` minutes-of-week.
- Use only targeted `WifiSetClientGivenName` field 3017; no `WifiSetConfig` or `ApplyClientConfigs`.
- Phase 5 allows rename, block, and unblock only; Wi-Fi/radio writes, packaging, and live mutation verification are excluded.
- JSON remains strict and 128 KiB; audit/live detail remains secret-free.

---

### Task 1: Schedule block/unblock controller and HTTP contract

**Files:**
- Modify: `router/internal/dish/router_control.go`
- Modify: `router/internal/api/router_control.go`
- Modify: `router/internal/api/router_control_test.go`
- Modify: `API.md`

**Interfaces:**
- Produces: `SetClientBlocked(context.Context, mac, revision string, blocked bool) (uint32, error)` and PATCH validation for one rename or block mutation.

- [ ] Add failing Handle-fake tests that assert block clones schedules and appends `{group_id:"starwatch-block", block_ranges:[{start_minutes:0,end_minutes:10080}]}`, preserves name/user schedules, and confirms `WifiClient.Blocked` true.
- [ ] Run `cd router && go test ./internal/api -run Block -count=1`; expect missing operation failures.
- [ ] Add a controller operation that clones only the target config, applies/removes only `starwatch-block`, and sends 3017.
- [ ] Add unblocking, user-managed-schedule refusal, confirmation/value validation, stale/unsupported/unconfirmed/error mappings, and secret-free confirmed audit actions.
- [ ] Rerun focused block tests; expect PASS.

### Task 2: Client-management SPA card and pure logic

**Files:**
- Modify: `router/web/app.js`
- Modify: `router/web/cards.js`
- Modify: `router/web/logic.js`
- Modify: `router/web/styles.css`
- Modify: `router/web/test.html`
- Modify: `router/internal/api/server_test.go`

**Interfaces:**
- Produces: topology-B-only client card, `clientMutationPayload`, and stale-retry helper behavior.

- [ ] Add failing browser harness assertions for rename/block payload confirmation, revision use, and 409 retry state.
- [ ] Run the browser logic harness; observe the missing helper failure.
- [ ] Add a client card with inline rename, typed block/unblock confirmation dialog, current revision display, 409 refresh/retry prompt, and verbatim 422 reason display.
- [ ] Verify card is omitted without router data, has no passphrase field, and remains touch/dark/light accessible.
- [ ] Rerun browser harness and `cd router && go test ./internal/api -run Static -count=1`; expect PASS.

### Task 3: Review, verification, commit, and push

- [ ] Run formatting, `git diff --check`, and grep mutation code for only 3017 writes.
- [ ] Run `cd router && go test -race ./...`.
- [ ] Run `cd router && go vet ./...`.
- [ ] Run `cd router && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build ./...`.
- [ ] Request independent review, fix findings, commit once documenting `[0,10080)` and targeted 3017, then push and compare SHAs.
