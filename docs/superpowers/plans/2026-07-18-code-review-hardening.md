# Code Review Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Starwatch resilient to malformed telemetry, power loss, slow integrations, transient network failures, partial configuration, and authentication misuse while preserving its public API and read/write scope.

**Architecture:** Cross-cutting safety behavior is placed at existing boundaries: JSON serialization, SQLite/UCI persistence, alert endpoint workers, network runners, and SPA normalization helpers. Stateful alert recovery uses a narrow interface backed by SQLite rather than coupling the alert engine to SQL. Existing signed-feed, fixed-span, and buffered-PNG behavior is retained and regression-tested instead of rewritten.

**Tech Stack:** Go 1.22, `net/http`, coder/websocket, modernc SQLite, OpenWrt UCI/opkg/usign shell tooling, Preact + htm static ES modules.

---

## File map

- `router/internal/api/json.go`: JSON-safe recursive clone and pre-header encoding.
- `router/internal/api/server.go`, `server_test.go`: HTTP/WS serialization, token scope, span/static behavior, deterministic WS tests.
- `router/internal/history/sqlite.go`, `sqlite_test.go`: WAL, busy timeout, bounded pending data, alert state persistence.
- `router/internal/history/store.go`, `store_test.go`, `tiered.go`, `tiered_test.go`: sorted timestamps and retention-aware tier selection.
- `router/internal/config/manager.go`, `manager_test.go`, `uci.go`, `uci_test.go`: durable writes, lock release, validation, round trips.
- `router/internal/alert/engine.go`, `engine_test.go`: resolve-on-disable and restart recovery.
- `router/internal/alert/delivery.go`, `delivery_test.go`: secret-safe logs, independent workers, retry classification.
- `router/internal/mwan/manager.go`, `manager_test.go`: last-good state and serialized reload.
- `router/internal/wan/probe_linux.go`, `probe_linux_test.go`: hostname resolution and UDP fallback.
- `router/internal/dish/speedtest.go`, `speedtest_test.go`, `poller.go`, `poller_test.go`: timeouts, status classification, alignment mapping.
- `router/cmd/starwatchd/main.go`, `main_test.go`: HTTP timeouts and alert-state wiring.
- `router/web/api.js`, `logic.js`, `views.js`, `cards.js`, `test.html`: frontend correctness and harness assertions.
- `package/mkfeed.sh`, `Makefile`, `tests/feed-artifact-test.sh`, `README.md`: optional local signing.
- `package/luci-app-starwatch/usr/share/rpcd/acl.d/luci-app-starwatch.json`: token ACL.
- `package/starwatchd/etc/config/starwatch`, `README.md`: listener/firewall documentation.

The full gate after every task is:

```sh
cd router
go build ./...
go vet ./...
go test ./...
```

### Task 1: P1 JSON-safe HTTP and WebSocket serialization

**Files:** create `router/internal/api/json.go`; modify `router/internal/api/server.go` and `router/internal/api/server_test.go`.

- [ ] Add `TestStatusSanitizesNonFiniteFloats` with `NaN`, `+Inf`, and `-Inf` in status, obstruction, power pointer, WAN, and obstruction-map fields; assert status 200, valid JSON, scalar zero, and pointer null/omission.
- [ ] Add `TestWebSocketSanitizesNonFiniteFloats` using injectable `WSWrite` to call `json.Marshal(value)` and capture the decoded frame. Make the overflow test wait for subscription readiness instead of racing the first publish.
- [ ] Run the new tests and the overflow test with `-count=20`; expect finite tests to fail with unsupported-value errors and the stabilized overflow test to pass repeatedly.
- [ ] Implement `jsonSafeClone(value any) any` using reflection. Preserve nils, interfaces, arrays, maps, slices, pointers, and structs; leave custom `json.Marshaler` values intact; set non-finite scalar floats to zero and non-finite float pointers to nil.
- [ ] Marshal `jsonSafeClone(value)` before `WriteHeader` in `writeJSON`, and pass the safe clone into `WSWrite` from `writeWS`.
- [ ] Run focused tests, the full gate, and commit `fix(api): sanitize non-finite telemetry JSON`.

### Task 2: P2 crash-safe SQLite journaling

**Files:** modify `router/internal/history/sqlite.go` and `router/internal/history/sqlite_test.go`.

- [ ] Replace the memory-journal assertion with `TestSQLiteUsesCrashSafeWAL`, asserting `journal_mode=wal`, `synchronous=2`, and `busy_timeout=5000`.
- [ ] Run it and observe the current `memory` mismatch.
- [ ] Apply `PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=5000;`, preserving quick-check/recovery.
- [ ] Run history tests, the full gate, and commit `fix(history): use crash-safe sqlite WAL`.

### Task 3: P3 durable UCI writes

**Files:** modify `router/internal/config/manager.go` and `router/internal/config/manager_test.go`.

- [ ] Add an injectable filesystem seam and tests proving temp-file sync precedes rename, parent-directory sync follows rename, and errors clean up the temp file.
- [ ] Run tests and observe missing sync calls.
- [ ] Update `atomicWrite` to call `file.Sync()`, close, rename, open the parent directory, and call directory `Sync()`.
- [ ] Run config tests, the full gate, and commit `fix(config): fsync atomic UCI writes`.

### Task 4: P4 optional local opkg signing

**Files:** modify `package/mkfeed.sh`, `package/Makefile`, `package/tests/feed-artifact-test.sh`, and `README.md`.

- [ ] Extend shell tests with fake usign: unset `SIGN_KEY` creates no signature; set `SIGN_KEY` invokes `usign -S -m Packages -s <key> -x Packages.sig` and stages it.
- [ ] Run `make -C package test` and observe failure.
- [ ] Make `mkfeed.sh` sign only when `SIGN_KEY` is non-empty; copy an optional signature in `feed-artifact` while retaining strict CI `signed-feed-artifact` verification.
- [ ] Document unsigned local artifacts versus signed HTTPS production/release artifacts.
- [ ] Run package tests, the full Go gate, and commit `fix(package): support optional local feed signing`.

### Task 5: Security boundary corrections

**Files:** modify `router/internal/alert/delivery.go`, `delivery_test.go`, `router/internal/api/server.go`, `server_test.go`, `router/cmd/starwatchd/main.go`, `main_test.go`, LuCI ACL JSON, shipped UCI config, and `README.md`.

- [ ] Add tests that secret URL paths never appear in logs, query tokens fail on `/api/status` but work on `/api/ws`, bearer auth works, and the HTTP server has read/header/idle timeouts with zero `WriteTimeout`.
- [ ] Run tests and observe URL leakage, broad query-token acceptance, and missing timeouts.
- [ ] Add `safeDeliveryError(err)` returning only network class or HTTP status; logs include endpoint kind and alert name, never URL.
- [ ] Permit query tokens only in the WebSocket auth wrapper. Preserve default coder/websocket same-origin checks.
- [ ] Set `IdleTimeout: 60*time.Second`; leave `ReadTimeout` and `WriteTimeout` zero because hijacked WebSocket connections can retain those deadlines.
- [ ] Move LuCI token RPC to write scope, confirm GL has no equivalent ACL, and document the firewall reliance of `0.0.0.0`.
- [ ] Run focused tests, JSON-parse ACL, run full gate, and commit `fix(security): tighten API and integration boundaries`.

### Task 6: Alert lifecycle and independent delivery

**Files:** modify `router/internal/alert/engine.go`, `engine_test.go`, `delivery.go`, and `delivery_test.go`.

- [ ] Test that disabling a firing rule emits one resolve.
- [ ] Test webhook/ntfy concurrent start, blocked webhook isolation, HTTP 400 single-attempt, and retry of network/429/5xx failures.
- [ ] Run tests and observe missing resolve, serial delivery, and retry of 400.
- [ ] Emit `StateResolved` before deleting active disabled state.
- [ ] Give endpoints independent bounded worker queues. Fan out without waiting; classify retryable network, 429, and 5xx outcomes explicitly.
- [ ] Run alert tests, full gate, and commit `fix(alerts): isolate delivery and resolve disabled rules`.

### Task 7: Persist alert and failover state

**Files:** modify `router/internal/history/sqlite.go`, `sqlite_test.go`, `router/internal/alert/engine.go`, `engine_test.go`, and `router/cmd/starwatchd/main.go`.

- [ ] Define `alert.StateStore` with `LoadAlertState() ([]byte,error)` and `SaveAlertState([]byte) error`; test SQLite round trip and engine restart without duplicate firing, with later resolve and no duplicate failover notification.
- [ ] Run focused tests and observe absent persistence.
- [ ] Add singleton `alert_state` table and mutex-guarded load/upsert methods.
- [ ] Serialize rule timing/detail plus failover set/readiness. Restore in `NewEngine`; persist after firing, resolving, disable, clear-hold changes, and failover initialization/change. Log persistence errors without stopping monitoring.
- [ ] Wire SQLite into engine options, run history/alert/main tests and full gate, then commit `fix(alerts): persist runtime state across restart`.

### Task 8: MWAN and WAN probing correctness

**Files:** modify `router/internal/mwan/manager.go`, `manager_test.go`, `router/internal/wan/probe_linux.go`, and `probe_linux_test.go`.

- [ ] Test last-good retention after dual refresh failure, non-overlapping concurrent Apply, `mwan3 reload`, hostname resolution before ICMP, and resolver failure enabling UDP fallback.
- [ ] Run tests and observe nil overwrite, overlap/restart, and nil IP writes.
- [ ] Replace status only on successful parse; otherwise return last-good. Serialize Assist/write/reload/refresh with `applyMu` and use reload.
- [ ] Resolve hostnames before `IPAddr`; return ICMP unavailable on resolution failure.
- [ ] Run WAN/MWAN tests, full gate, and commit `fix(network): retain status and serialize failover applies`.

### Task 9: UCI round trips and truthful config updates

**Files:** modify `router/internal/config/uci.go`, `uci_test.go`, `manager.go`, and `manager_test.go`.

- [ ] Add round trips for spaces and `O'Brien`; newline endpoint rejection; unsupported threshold/hold rejection without mutation/write; and an Apply callback re-entering `View()`.
- [ ] Run tests and observe corruption, acceptance, transient mutation, and deadlock.
- [ ] Decode shell apostrophe sequences, reject CR/LF, validate persisted option availability before assignment, and invoke Apply/audit after unlocking with a clone.
- [ ] Run config tests, full gate, and commit `fix(config): preserve UCI values and release update lock`.

### Task 10: Retention-aware and bounded history

**Files:** modify `router/internal/history/sqlite.go`, `sqlite_test.go`, `tiered.go`, `tiered_test.go`, `store.go`, and `store_test.go`.

- [ ] Test two-day minute retention selecting quarter data after two days, bounded pre-NTP queues, and sorted queries that exclude zero timestamps.
- [ ] Run tests and observe seven-day hardcode, unbounded slices, and bad search results.
- [ ] Add mutex-protected `MinuteRetention()`, use it as tier boundary, cap pending collections to database limits, filter zero times, and stable-sort only unordered snapshots.
- [ ] Run history tests, full gate, and commit `fix(history): honor retention and bound invalid-clock queues`.

### Task 11: Dish RPC and alignment correctness

**Files:** modify `router/internal/dish/speedtest.go`, `speedtest_test.go`, `poller.go`, and `poller_test.go`.

- [ ] Test a blocking status RPC canceled by per-call timeout, `Unavailable` remaining transient, only `Unimplemented` becoming unsupported, and AlignmentStats az/el winning over deprecated fields.
- [ ] Run tests and observe the reported failures.
- [ ] Add `RPCTimeout` with existing timeout default, wrap status calls in `context.WithTimeout`, restrict unsupported classification, and map boresight fields from AlignmentStats.
- [ ] Run dish tests, full gate, and commit `fix(dish): bound speedtest polls and use alignment stats`.

### Task 12: Frontend resilience

**Files:** modify `router/web/api.js`, `logic.js`, `views.js`, `cards.js`, and `test.html`.

- [ ] Extend browser harness for unauthorized WS without polling/retry, empty/text 2xx returning null, partial settings, omitted blank numerics, stable list identity, and null history gaps.
- [ ] Run browser harness and observe failures.
- [ ] Return immediately on 1008; parse successful response text defensively; normalize settings sections/arrays; omit blank numeric payload members; add keys by stable domain identifiers; preserve null before numeric conversion.
- [ ] Run browser harness, Go static tests, full gate, and commit `fix(web): tolerate partial and empty live data`.

### Task 13: Lower-tail regression guards

**Files:** modify `router/internal/api/server_test.go`, `router/internal/api/obstruction.go`, and `router/internal/api/obstruction_test.go`.

- [ ] Test rejection of arbitrary/huge day spans and test that a PNG encode/render failure returns one clean error response without committing image headers first.
- [ ] Run tests; confirm fixed spans already pass and observe the PNG handler's premature content-type/header behavior.
- [ ] Render PNG into `bytes.Buffer`; only set `Content-Type` and copy bytes to the response after encoding succeeds.
- [ ] Run full gate and commit `test(api): guard fixed spans and buffered PNG output`.

### Task 14: Final verification and finding ledger

**Files:** modify `CHANGELOG.md`, `README.md`, and this plan.

- [ ] Document WAL/FULL/busy timeout, fsync, token transport, alert persistence/workers, network last-good behavior, dish timeout semantics, frontend gaps, listener/firewall policy, and already-correct review items.
- [ ] Mark completed plan checks and run `git diff --check`.
- [ ] Run:

```sh
cd router
go test -race ./...
go vet ./...
go build ./...
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build ./...
cd ..
make -C package test
make -C package all
```

- [ ] Run the browser harness against the embedded server with zero failures.
- [ ] Review status/diff and confirm no public JSON names, origin checks, routing/firewall scope, or `WriteTimeout` changed.
- [ ] Commit `docs: summarize code review hardening`.
