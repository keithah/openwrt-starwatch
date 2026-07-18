# Router Wi-Fi Phase 6 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add confirmed, guarded Starlink-router Wi-Fi and radio updates without exposing or erasing credentials.

**Architecture:** Extend the existing router mutation controller with `WifiSetConfig` operations. Scalar changes construct a fresh `WifiConfig` containing one value, incarnation, and one paired apply flag; BSS changes clone the complete readback collection, enforce the sibling-credential guard, then use `ApplyNetworks`. The HTTP layer validates strict JSON and the SPA builds only safe, write-only payloads.

**Tech Stack:** Go, vendored Starlink protobufs, in-process gRPC Handle fake, Preact/HTM, embedded static assets.

## Global Constraints

- Base is `origin/main` at `d05959bf`.
- Use `{ssid, band}` to select a BSS; `new_ssid` is the rename value. Do not use fictional IDs or runtime BSSID.
- No live router mutation during verification; all writes use the fake gRPC server.
- `WifiSetConfig` scalar payloads contain only incarnation, one value, and its one paired apply flag.
- Network writes are the only `ApplyNetworks` path and refuse when any sibling PSK BSS has no returned password.
- Passphrases are write-only and never returned, logged, persisted, or audited.
- Excluded router-write categories return `422 excluded`; no client, mesh, DHCP, route, firewall, or regulatory writes are added.
- One conventional feature commit then push `origin/main`.

---

### Task 1: Correct the public selector contract and add strict HTTP tests

**Files:**
- Modify: `API.md`
- Modify: `router/internal/api/router_control.go`
- Modify: `router/internal/api/router_control_test.go`

**Interfaces:**
- Produces `PATCH /api/router/wifi` using `routerWifiPatchRequest`, strict 128 KiB parsing, `config_revision`, and `confirmation` validation.

- [ ] Write failing API tests asserting `{ssid,band}` selection, `new_ssid` rename semantics, excluded fields returning 422, and missing/mismatched confirmation returning 400.
- [ ] Run `cd router && go test ./internal/api -run Wifi -count=1`; expect failure because the Wi-Fi endpoint does not exist.
- [ ] Replace fictional network/BSS IDs in API.md with the `{ssid,band}` selector and implement the authenticated PATCH route plus strict validation.
- [ ] Rerun the focused API tests; expect PASS.

### Task 2: Add safe scalar `WifiSetConfig` writes with readback confirmation

**Files:**
- Modify: `router/internal/dish/router_control.go`
- Modify: `router/internal/api/router_control.go`
- Modify: `router/internal/api/router_control_test.go`

**Interfaces:**
- Produces `ApplyRouterWifi(context.Context, RouterWifiMutation) error` and error values for unsupported, unsafe channel, and unconfirmed Wi-Fi updates.

- [ ] Add failing Handle-fake tests for band enable, channel, width, tx-power, steering, outdoor mode, and DNS; each test asserts exactly one apply flag and no collection flag.
- [ ] Run `cd router && go test ./internal/api -run 'Wifi.*Scalar' -count=1`; expect missing-controller failures.
- [ ] Implement scalar field mapping, real tx-power enum validation, advertised non-DFS channel validation, incarnation recheck, `WifiSetConfig`, and readback comparisons.
- [ ] Map unsupported gRPC status to 422, stale to 409, and failed confirmation to 502; append secret-free confirmed `router_control` audit/live messages.
- [ ] Rerun the focused scalar tests; expect PASS.

### Task 3: Add atomic BSS edits behind the credential-preservation guard

**Files:**
- Modify: `router/internal/dish/router_control.go`
- Modify: `router/internal/api/router_control.go`
- Modify: `router/internal/api/router_control_test.go`

**Interfaces:**
- Produces guarded `{ssid,band}` BSS collection mutation and `ErrRouterNetworkCredentialsUnavailable`.

- [ ] Add failing fake tests for clone-only-target behavior, rename to `new_ssid`, password omission preservation, passphrase redaction, OPEN confirmation, readback mismatch, and both credential-guard branches.
- [ ] Run `cd router && go test ./internal/api -run 'Wifi.*(Network|Credential|SSID)' -count=1`; expect failure before network mutation exists.
- [ ] Clone `WifiConfig.Networks`, locate exactly one selected BSS, reject unavailable sibling PSK credentials, apply permitted BSS changes, and set only `ApplyNetworks`.
- [ ] Confirm target SSID/security/hidden/disabled by readback and confirm only `credential_set` for a supplied passphrase; never compare or surface the secret.
- [ ] Rerun focused network tests and grep marshalled response/audit/live/log fixture output for the supplied secret; expect PASS and zero matches.

### Task 4: Add the topology-B guarded Wi-Fi editor

**Files:**
- Modify: `router/web/logic.js`
- Modify: `router/web/cards.js`
- Modify: `router/web/app.js`
- Modify: `router/web/styles.css`
- Modify: `router/web/test.html`
- Modify: `router/internal/api/server_test.go`

**Interfaces:**
- Produces pure `wifiMutationPayload` and stale-retry helper behavior plus an accessible Wi-Fi editor inside the router card.

- [ ] Add failing browser harness assertions for `{ssid,band}` + `new_ssid`, omitted empty passphrase, open-network confirmation, and 409 retry behavior.
- [ ] Run the browser harness; expect a missing helper/component failure.
- [ ] Implement topology-B-only BSS, radio, steering, outdoor, DNS controls; leave passphrase empty and labelled “unchanged”; use typed confirmation dialogs with focus, Escape, and status announcements.
- [ ] Surface 422 reasons verbatim, preserve dark/light/touch styling, and verify no editor markup displays an existing password.
- [ ] Rerun browser harness and `cd router && go test ./internal/api -run Static -count=1`; expect PASS.

### Task 5: Verification, review, commit, and push

- [ ] Run `gofmt`, `git diff --check`, and focused fake-router tests.
- [ ] Run `cd router && go test -race ./...`.
- [ ] Run `cd router && go vet ./...`.
- [ ] Run `cd router && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build ./...`.
- [ ] Confirm the embedded binary static-asset test and browser logic harness pass.
- [ ] Review the diff for no prohibited write RPC/fields and no passphrase leaks; commit with body documenting `{ssid,band}`, the credential guard, and scalar-vs-atomic split; push `origin/main` and compare SHAs.
