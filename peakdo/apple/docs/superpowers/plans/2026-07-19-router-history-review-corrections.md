# Router History Review Corrections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Correct Task 8 so router-history refreshes are latest-request-wins, host opening is deterministically orchestrated, loading and empty states are honest, replacement sessions quarantine in-flight work, and production wiring is behavior-tested.

**Architecture:** `RouterAdministrationModel` owns session generation, an independent history-request generation, and a small history load-state machine. `WattlineUI` remains Network-free and adds a pure screen presentation derived from local history values plus local load state. `RouterAdministrationView` runs one keyed `open(host:)` task; a model factory centralizes shared credential-store wiring for AppModel and tests.

**Tech Stack:** Swift 6, Observation, SwiftUI, Charts, XCTest, Swift Package Manager, Xcode iOS Simulator tests.

## Global Constraints

- Work only on Wattline Router Administration Milestone 2 Task 8 corrections; no M3+ work.
- Decode exact router keys `at/level/status/dc_w/typec_w`; preserve signed status and nil port-power honesty.
- History authenticates with the client role and never weakens Task 7 administrator credential serialization.
- WattlineUI remains Network-free and uses local value types.
- Every production behavior change follows RED, minimal GREEN, and focused verification.
- Final verification runs both full package suites and the full executed Wattline iOS scheme on `Wattline-Tests-2`.

---

### Task 1: Latest-request-wins history refresh

**Files:**
- Modify: `peakdo/apple/Wattline/WattlineTests/RouterAdministrationModelTests.swift`
- Modify: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterAdministrationModel.swift`

**Interfaces:**
- Consumes: existing `reloadHistory() async`, session generation, gated scripted HTTP fixture.
- Produces: request generation guards ensuring only the newest same-session request publishes data, `fetchedAt`, error, or load state.

- [x] Write deterministic tests that gate request 1, complete request 2 first, then release request 1 for both older-success and older-error cases.
- [x] Run focused model tests and observe older success overwrite newer samples and older error overwrite newer success.
- [x] Increment a private `historyRequestGeneration` at refresh start, capture it, and require both session and request generations to match before every publication.
- [x] Run focused model tests and observe both out-of-order tests pass.

### Task 2: Pure honest load-state presentation

**Files:**
- Modify: `peakdo/apple/WattlineUI/Tests/WattlineUITests/RouterHistoryPresentationTests.swift`
- Modify: `peakdo/apple/WattlineUI/Sources/WattlineUI/RouterHistoryPresentation.swift`
- Modify: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterAdministrationModel.swift`
- Modify: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterHistoryView.swift`

**Interfaces:**
- Produces: local `RouterHistoryLoadState` and `RouterHistoryScreenPresentation` with falsifiable properties for never-loaded, initial-loading, successful-empty, failed-empty, and refreshing-existing-data.

- [x] Add WattlineUI tests asserting each state yields distinct initial progress, empty-success, empty-failure, chart, and refresh-progress behavior.
- [x] Run focused UI tests and observe missing presentation types.
- [x] Implement the local pure types without importing networking.
- [x] Add app-model tests proving refresh start clears stale error, initial loading replaces no data, and refreshing preserves existing history.
- [x] Run focused app tests and observe missing/incorrect model load state.
- [x] Implement model load-state transitions and render `RouterHistoryView` solely from the pure screen presentation.
- [x] Run focused UI and app tests GREEN.

### Task 3: Deterministic host opening orchestration

**Files:**
- Modify: `peakdo/apple/Wattline/WattlineTests/RouterAdministrationModelTests.swift`
- Modify: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterAdministrationModel.swift`
- Modify: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterAdministrationView.swift`
- Modify: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterHistoryView.swift`

**Interfaces:**
- Produces: `open(host:) async`, which awaits `begin(host:)` and then performs exactly one initial `reloadHistory()`.

- [x] Add a behavior test asserting `open(host:)` establishes the host before exactly one history request.
- [x] Run focused model tests and observe `open(host:)` missing.
- [x] Implement `open(host:)` with cancellation/session checks.
- [x] Replace the parent `.task` with one `.task(id: host.endpoint.peripheralID)` calling `open`; remove the child history `.task`.
- [x] Run focused app tests GREEN.

### Task 4: Replacement-session quarantine

**Files:**
- Modify: `peakdo/apple/Wattline/WattlineTests/RouterAdministrationModelTests.swift`

**Interfaces:**
- Consumes: session generation and gated history fixture.
- Produces: deterministic coverage for success and error released only after replacement `begin/open` completes.

- [x] Add gated stale-success and stale-error replacement-session tests.
- [x] Temporarily remove/bypass the session guard only if needed to confirm the tests fail for the intended reason, then restore it; otherwise run against the pre-correction commit logic in the recorded RED command.
- [x] Run the focused suite with production session guards and observe both tests pass.

### Task 5: Behavior-tested production factory

**Files:**
- Modify: `peakdo/apple/Wattline/WattlineTests/RouterAdministrationModelTests.swift`
- Modify: `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterAdministrationModel.swift`
- Modify: `peakdo/apple/Wattline/Wattline/AppModel.swift`

**Interfaces:**
- Produces: `RouterAdministrationModel.production(connections:httpFactory:)` with a production default HTTP factory; both administrator and history clients share `connections.credentialStore`.

- [x] Add a test that injects scripted HTTP into the production factory, saves a client token only in the supplied connection store, and observes `/api/v1/history` with that token.
- [x] Run focused model tests and observe missing factory.
- [x] Implement the factory and change AppModel to consume it.
- [x] Run focused app tests GREEN.

### Task 6: Verification, review, report, and commit

**Files:**
- Modify: `.superpowers/sdd/router-admin-m2-task-8-report.md`

- [x] Run `swift test --package-path peakdo/apple/WattlineNetwork` and record the exact count.
- [x] Run `swift test --package-path peakdo/apple/WattlineUI` and record the exact count.
- [x] Run focused `RouterAdministrationModelTests` on `Wattline-Tests-2` and record the exact count.
- [x] Run the full Wattline scheme on `Wattline-Tests-2`, inspect the xcresult summary, and record exact passed/failed/skipped counts.
- [x] Audit diffs for request/session races, load-state honesty, Network-free UI, structural role gating, shared credential wiring, and scope.
- [x] Append RED/GREEN evidence and self-review to the Task 8 report.
- [x] Commit the complete correction wave with a focused message.
