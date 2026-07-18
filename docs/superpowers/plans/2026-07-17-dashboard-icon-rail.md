# Dashboard Icon-Rail Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the long dashboard stack with an accessible seven-section icon-rail shell while retaining existing cards and live data.

**Architecture:** Add pure route and Overview-preference helpers in `logic.js`; use them from the existing `App` to render a rail, sticky section header, and per-section card grids. CSS provides the desktop expanding rail, mobile drawer, slideout, density, and motion behavior without new dependencies.

**Tech Stack:** Preact, HTM, static ES modules, localStorage, Fullscreen API, existing browser harness, Go static-asset tests.

## Global Constraints

- No bundler, React, dependency, API, or daemon changes.
- Keep `htm.bind(h)` and the existing live/token data flow.
- Routes are `#/`, `#/telemetry`, `#/connectivity`, `#/power`, `#/controls`, `#/events`, and `#/settings`.
- Use only existing CSS `var(--*)` tokens; preserve light mode and reduced-motion support.
- Overview preferences persist as `starwatch.overview.cards` and `starwatch.density`.
- Rail and drawers are keyboard accessible: semantic controls, visible focus, Escape, focus restoration, and focus trapping for modal panels.

---

### Task 1: Pure navigation and Overview-preference state

**Files:**
- Modify: `router/web/logic.js`
- Modify: `router/web/test.html`

**Interfaces:**
- Produces `dashboardSection(hash)`, `normalizeOverviewPreferences(saved)`, and `visibleOverviewCards(cards, preferences)`.

- [ ] Add harness assertions that `#/telemetry` resolves to telemetry, unknown hashes resolve to overview, persisted hidden cards are pruned to the six Overview IDs, and compact state is preserved.
- [ ] Serve `router/web/test.html` and observe the new helper assertions fail because the functions are absent.
- [ ] Add pure helpers with these exact allowed IDs: `live-telemetry`, `wan-health`, `power`, `obstruction`, `alignment`, and `alerts`; default every card visible and compact false.
- [ ] Rerun the browser harness; expect the helper assertions to pass.

### Task 2: Rail, header, section composition, and controls

**Files:**
- Modify: `router/web/app.js`
- Modify: `router/web/cards.js`
- Modify: `router/web/test.html`

**Interfaces:**
- Consumes: Task 1 helper functions and existing snapshot, connection, card, and view props.
- Produces: `IconRail`, `SectionHeader`, and `CustomizePanel` rendered by `App`.

- [ ] Add harness assertions for all seven rail destinations, active-route content grouping, `LIVE` connection labeling, and Overview-only customize visibility.
- [ ] Run the browser harness; expect missing rail/header/component assertions to fail.
- [ ] Replace the dashboard stack with a route-derived section renderer: Overview in product-priority order; Telemetry graph/obstruction/alignment; Connectivity WAN/outages; Power power plus controls sleep row; Controls controls/speed; Events alerts/events view; Settings settings view.
- [ ] Implement semantic rail links with inline SVG icons/title labels, fullscreen state from `fullscreenchange`, and a modal customize panel with escape/backdrop/focus restoration.
- [ ] Rerun the browser harness; expect section and control assertions to pass.

### Task 3: Responsive visual system and persistence wiring

**Files:**
- Modify: `router/web/app.js`
- Modify: `router/web/styles.css`
- Modify: `router/web/test.html`

**Interfaces:**
- Consumes: Task 1 preferences and Task 2 controls.
- Produces: persisted Overview visibility/density, desktop hover-expanding rail, mobile drawer, and token-based responsive layout.

- [ ] Add harness assertions that localStorage keys restore visibility/density, a reset returns all Overview cards, and the customize dialog focus trap and Escape behavior work.
- [ ] Run the browser harness; expect persistence and interaction assertions to fail.
- [ ] Persist `starwatch.overview.cards` and `starwatch.density`; apply compact class to content. Add token-only CSS for the 74px/224px rail, 328px customize panel, toggle controls, sticky header, desktop grid, sub-720px rail drawer, and reduced motion.
- [ ] Rerun browser harness and verify the rendered DOM contains no hidden Overview card and restores the customize trigger after Escape.

### Task 4: Integration verification and release-ready review

**Files:**
- Test: `router/web/test.html`
- Test: `router/internal/api/server_test.go`

- [ ] Run the browser harness and record the assertion count.
- [ ] Run `cd router && go test ./internal/api -run Static -count=1` to confirm embedded assets remain served.
- [ ] Run `cd router && go test -race ./...`, `go vet ./...`, and `CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build ./...`.
- [ ] Run `git diff --check`; inspect the diff for raw new colors, external assets, direct telemetry mutation, or inaccessible icon controls.
- [ ] Commit the focused UI change and push only after all checks pass.
