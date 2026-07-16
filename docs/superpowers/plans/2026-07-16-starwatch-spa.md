# Starwatch Task 6 SPA Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Repair mwan3 failover-assist defaults and ship Starwatch's fully offline, embedded monitoring and control SPA.

**Architecture:** A conservative mwan3 parser recognizes only the exact pristine OpenWrt sample configuration and emits a complete, tracked Starwatch policy. A `starwatch/web` Go package embeds a modular Preact/htm/uPlot application; `internal/api` mounts static content separately from authenticated API routes and exposes one alert-delivery test endpoint.

**Tech Stack:** Go 1.22+, `net/http`, `embed`, Preact ESM, htm ESM, uPlot ESM/CSS, handwritten browser modules, Go race tests.

## Global Constraints

- No npm, bundler, runtime CDN, analytics, remote fonts, or browser request outside the daemon.
- Preserve all existing endpoint shapes; add only `POST /api/alerts/test`.
- Keep every `/api/*` endpoint token-authenticated and `/` iframe-safe.
- No packaging, LuCI/GL integration, new dish RPCs, or WebSocket protocol changes.
- Finish with exactly two implementation commits: Part A review fixes, then Part B SPA.

---

### Task 1: Recognize Pristine mwan3 and Propose a Functional Policy

**Files:**
- Modify: `starlink/openwrt/router/internal/mwan/manager.go`
- Modify: `starlink/openwrt/router/internal/mwan/manager_test.go`

**Interfaces:**
- Consumes: `Manager.Assist(context.Context, []string)` and parsed `uci show mwan3` assignments.
- Produces: conservative pristine-example classification and structured `[]Change` including tracked interface sections.

- [ ] **Step 1: Add failing fixture tests**

Add complete `uci show mwan3` fixtures for a pristine OpenWrt install and a genuinely modified install. Assert the pristine fixture is available, the modified fixture returns `custom mwan3 configuration exists`, and the pristine proposal contains interface changes and removal/disablement of the sample default rule.

```go
func TestAssistAcceptsPristineOpenWrtExample(t *testing.T) {
	manager := fixtureManager(pristineMwan3Show)
	assist, err := manager.Assist(context.Background(), []string{"wan", "wwan"})
	if err != nil || !assist.Available {
		t.Fatalf("Assist() = %#v, %v", assist, err)
	}
	assertChange(t, assist.Proposed, "mwan3", "starwatch_primary", "track_ip", "1.1.1.1")
	assertChange(t, assist.Proposed, "mwan3", "starwatch_primary", "track_ip", "8.8.8.8")
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `go test ./internal/mwan -run 'TestAssist(AcceptsPristine|RefusesCustomized|Proposes)' -count=1`

Expected: failure because sample sections are treated as custom and interface changes are missing.

- [ ] **Step 3: Implement exact sample recognition and complete changes**

Represent the shipped example as an allowlist of section names, types, and option values. Ignore `globals`, accept only exact known sample sections, and keep all unexpected sections/options custom. Extend `proposedChanges` with `starwatch_primary` and `starwatch_backup` interface sections containing `enabled`, `family`, repeated `track_ip`, and `reliability`. Emit the explicit change that neutralizes the pristine sample default rule when detected. Retain the §13.4 on-device verification comment.

- [ ] **Step 4: Verify GREEN and regression suite**

Run: `go test ./internal/mwan -count=1`

Expected: PASS.

- [ ] **Step 5: Verify and create Part A commit**

Run from `starlink/openwrt/router`:

```sh
go test -race ./...
go vet ./...
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build ./...
```

Fold the design/plan checkpoint into this commit so the final history preserves the requested boundary. Commit with a body listing both review findings.

---

### Task 2: Embed and Serve Static Assets

**Files:**
- Create: `starlink/openwrt/router/web/embed.go`
- Create: `starlink/openwrt/router/web/embed_test.go`
- Modify: `starlink/openwrt/router/internal/api/server.go`
- Modify: `starlink/openwrt/router/internal/api/server_test.go`

**Interfaces:**
- Produces: `web.FileSystem() (fs.FS, error)` selecting embedded assets or `STARWATCH_WEB_DIR`.
- Consumes: `http.FileServerFS` mounted by `api.NewServer` on unauthenticated static routes.

- [ ] **Step 1: Add failing server tests**

Test that `GET /` returns the SPA marker, an asset returns 200, a temp `STARWATCH_WEB_DIR` replaces the embedded index, responses omit `X-Frame-Options`, and unauthenticated `GET /api/status` remains 401.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `go test ./web ./internal/api -run 'Test(Embedded|Static|WebDir|APIAuth)' -count=1`

Expected: compile or assertion failure because the web package/static handler does not exist.

- [ ] **Step 3: Implement the embedded filesystem boundary**

Use `//go:embed` over the web asset tree, return a sub-filesystem rooted at static content, validate development overrides, and mount the file handler after the more-specific API patterns. Do not add security headers that prevent framing.

- [ ] **Step 4: Verify GREEN**

Run: `go test ./web ./internal/api -count=1`

Expected: PASS.

---

### Task 3: Add Alert Delivery Test Endpoint

**Files:**
- Modify: `starlink/openwrt/router/internal/api/server.go`
- Modify: `starlink/openwrt/router/internal/api/server_test.go`
- Modify: `starlink/openwrt/router/cmd/starwatchd/main.go`

**Interfaces:**
- Consumes: an injected `interface { Enqueue(alert.Notification) }`.
- Produces: authenticated `POST /api/alerts/test`, returning accepted status after bounded-queue enqueue.

- [ ] **Step 1: Add failing endpoint tests**

Inject a recording notification sink. Assert POST without token is 401, GET is 405, and authenticated POST enqueues one informational `test` firing notification.

- [ ] **Step 2: Verify RED**

Run: `go test ./internal/api -run TestAlertTest -count=1`

Expected: failure because the route and dependency are absent.

- [ ] **Step 3: Implement and wire the endpoint**

Add the narrow sink interface and dependency, register only `POST /api/alerts/test`, construct the existing exact notification type, enqueue it, and return JSON success. Pass the running dispatcher from `main.go`.

- [ ] **Step 4: Verify GREEN**

Run: `go test ./internal/api ./cmd/starwatchd -count=1`

Expected: PASS.

---

### Task 4: Vendor Browser Dependencies and Build Pure Logic

**Files:**
- Create: `starlink/openwrt/router/web/vendor/preact.module.js`
- Create: `starlink/openwrt/router/web/vendor/htm.module.js`
- Create: `starlink/openwrt/router/web/vendor/uPlot.esm.js`
- Create: `starlink/openwrt/router/web/vendor/uPlot.min.css`
- Create: `starlink/openwrt/router/web/vendor/README.md`
- Create: `starlink/openwrt/router/web/logic.js`
- Create: `starlink/openwrt/router/web/test.html`

**Interfaces:**
- Produces: `deriveState`, `availabilityValue`, `localMinutesToUTC`, `utcMinutesToLocal`, `friendlyModel`, and `assembleSeries` as pure named exports.

- [ ] **Step 1: Write browser assertions before logic**

Create `test.html` importing `logic.js` and asserting all state labels, reason-preserving unavailable output, timezone wraparound, unknown-model fallback, timestamp alignment, and min/max retention. Initial load must visibly report failures because exports are absent.

- [ ] **Step 2: Implement minimal pure functions**

Keep these functions independent of DOM and Preact. Treat only `null`/`undefined` as absent so valid zero telemetry remains visible.

- [ ] **Step 3: Vendor pinned upstream distributions**

Check in exact single-file ESM distributions and uPlot CSS. Record versions, source package paths, licenses, and update procedure in `vendor/README.md`. Verify imports contain no HTTP URLs and no unresolved package specifiers.

- [ ] **Step 4: Run the manual harness**

Serve the web directory locally and open `test.html`; expected output is all assertions passed. Record that this is a manual harness, not a CI dependency.

---

### Task 5: Implement Token, REST, and Live Data Clients

**Files:**
- Create: `starlink/openwrt/router/web/api.js`
- Create: `starlink/openwrt/router/web/charts.js`

**Interfaces:**
- Produces: token bootstrap/session management, authenticated `apiFetch`, `LiveClient`, cancellable history loading, and uPlot lifecycle functions.
- Consumes: relative daemon routes and pure `assembleSeries` logic.

- [ ] **Step 1: Extend manual assertions for token and URL helpers**

Assert query-token removal preserves unrelated query keys/hash, WebSocket URL uses the current origin and relative API path, and history query generation encodes series/span.

- [ ] **Step 2: Verify the new assertions fail**

Open `test.html`; expected failures name the missing helpers.

- [ ] **Step 3: Implement client lifecycle**

Bootstrap into `sessionStorage`, strip only `token`, centralize 401 callbacks, reconnect WebSocket exponentially, and guarantee only one REST fallback interval. Implement history cancellation with `AbortController`.

- [ ] **Step 4: Implement chart lifecycle**

Create uPlot options for throughput, latency, loss, and power; distinguish dish/router labels; render aggregate envelopes; use `ResizeObserver`; and expose deterministic destroy/update operations.

- [ ] **Step 5: Re-run manual assertions**

Expected: all assertions passed.

---

### Task 6: Build the Dashboard Cards and Product Styling

**Files:**
- Create: `starlink/openwrt/router/web/index.html`
- Create: `starlink/openwrt/router/web/app.js`
- Create: `starlink/openwrt/router/web/cards.js`
- Create: `starlink/openwrt/router/web/views.js`
- Create: `starlink/openwrt/router/web/styles.css`

**Interfaces:**
- Consumes: current daemon response shapes, API/live clients, pure logic, and chart adapter.
- Produces: hash-routed SPA with dashboard, settings, and events views.

- [ ] **Step 1: Create the accessible shell and hydration path**

Add semantic landmarks, status region, skip link, root mount, vendored styles/scripts, token entry, initial concurrent REST hydration, and persistent status shell across routes.

- [ ] **Step 2: Implement dashboard cards in fixed order**

Implement all requested cards with source-based auto-hide, shared availability output, row-major grid, full-width graphs, responsive canvas/SVG/chart rendering, honest derived labels, source-colored outages, and friendly/raw hardware naming.

- [ ] **Step 3: Implement guarded action flows**

Map existing control, speed-test, obstruction, WAN-assist, and config APIs. Enforce exact confirmations, typed phrases, UTC conversion display, dish-unreachable disabling, motorless stow hiding, unsupported/error states, and session speed-test history.

- [ ] **Step 4: Implement settings and events routes**

Render only safe mutable config fields, alert rule enable/threshold controls, location explanation, alert-delivery test, masked/regenerated token flow, and filterable parsed audit history.

- [ ] **Step 5: Complete the design system**

Define every color as a custom property, dark/light schemes, 8 px spacing rhythm, tabular metrics, cyan traces, state colors, focus-visible states, reduced-motion handling, 720/1100 px layouts, and restrained load/connection transitions.

- [ ] **Step 6: Exercise the manual harness and responsive UI**

Open `/test.html`, then `/` at narrow, middle, and wide sizes. Confirm all pure assertions, card ordering, graph spanning, token entry, and hash routes.

---

### Task 7: Full Verification, Embedded Smoke Test, and Part B Commit

**Files:**
- Modify only files required by failures discovered during verification.

**Interfaces:**
- Confirms the complete Task 6 contract.

- [ ] **Step 1: Measure the pre-embed baseline**

Build the Part A tree to a temporary binary and record byte size before Part B asset embedding.

- [ ] **Step 2: Run the required verification**

Run from `starlink/openwrt/router`:

```sh
go test -race ./...
go vet ./...
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build ./...
```

Expected: all commands exit 0.

- [ ] **Step 3: Run the real-server smoke test**

Start `starwatchd` on an unused development port with a temporary config/environment, allow WAN-only mode, then curl `/` and `/vendor/preact.module.js`. Assert HTML/JavaScript content, 200 statuses, no external references, and unauthenticated API 401.

- [ ] **Step 4: Measure embedded binary delta**

Build the final native binary, record its byte size, and calculate the difference from Step 1.

- [ ] **Step 5: Review scope and diff**

Run `git diff --check`, inspect all changed paths, search web assets for `https://`, `http://`, CDN/font/analytics references, and confirm only the allowed API route was added.

- [ ] **Step 6: Create Part B commit**

Commit with a conventional `feat(starwatch): ...` subject. Confirm the final two-commit boundary contains Part A followed by Part B.
