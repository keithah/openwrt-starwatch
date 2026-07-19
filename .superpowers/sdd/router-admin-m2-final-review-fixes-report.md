# Wattline Router Administration M2 — Final Review Fixes

Date: 2026-07-19

Worktree: `/Users/keith/.codex/worktrees/wattline-phase-2`

Branch: `codex/wattline-phase-2`
Starting HEAD: `6d0ad0b841228999b33288ee6d409e64d55bc83b`

## Scope and authority

Implemented only the four confirmed M2 final-review findings against:

- `peakdo/apple/docs/superpowers/specs/2026-07-18-wattline-router-administration-design.md`
- `peakdo/apple/docs/superpowers/plans/2026-07-18-wattline-router-administration-m2.md`

The canonical router repository and contracts were read-only. No M3 settings,
TLS, router BLE pairing, advanced device controls, or rules work was started.
The Task 11 report was not modified.

## Finding 1 — FIFO privileged mutations and atomic revocation readback

Root cause: Swift actors are reentrant at each `await`. The client serialized
individual actor entries, but the model composed token DELETE and authoritative
GET as two separate actor calls. A second revoke could therefore issue its
DELETE before the first workflow's GET and the older workflow could later
publish stale tokens.

Changes:

- Added an actor-owned FIFO privileged-mutation gate.
- Held the gate through each revoke DELETE and its authoritative token-list GET.
- Added `revokeTokenAndReload`, returning the final authoritative token list.
- Changed `RouterAdministrationModel` to use the atomic API.
- Kept standalone pairing open/close and standalone revoke mutations inside the
  same FIFO mutation discipline.
- Added a typed post-DELETE readback failure that contains only a coarse error
  category. This lets the model perform lease-conditional local cleanup after a
  confirmed durable DELETE without publishing guessed state or exposing a
  credential/error body.
- Revalidated the captured attachment before readback so an old durable DELETE
  can never relist through a replacement endpoint or newly unlocked session.

TDD evidence:

1. Network RED:

   `swift test --package-path peakdo/apple/WattlineNetwork --filter RouterPairingAdministrationTests/testConcurrentRevokeAndReloadWorkflowsRunFIFOThroughAuthoritativeReadback`

   Failed to compile because `RouterAdministrationClient` had no
   `revokeTokenAndReload` member. This was the intended missing-behavior failure.

2. Network GREEN:

   The same command passed 1/1. Individually released gates proved the exact
   order `DELETE first -> GET tokens -> DELETE second -> GET tokens`; the first
   result contained only `second` and the final result was exactly `[]`.

3. Model RED:

   `xcodebuild test ... -only-testing:WattlineTests/RouterAdministrationModelTests/testConcurrentModelRevocationsUseAtomicFIFOReadbacksAndPublishFinalList`

   Failed with the first/stale list still published, a visible request error,
   and interleaved model call order.

4. Model GREEN:

   The same focused simulator test passed 1/1 after model adoption.

5. Adjacent-race audit:

   The first full model-class run exposed two stale-attachment regressions:
   readback could run through a re-unlocked or replacement admin session after
   an old DELETE completed. After attachment revalidation, both focused tests
   passed, and the final complete model class passed 69/69. Existing durable
   session-end cleanup, same-endpoint reenrollment, credential-lease, failed
   cleanup, stale-auth, and replacement-endpoint tests also remained green.

## Finding 2 — exact HTTP 200 administration contracts

Root cause: the underlying HTTP client correctly returned all 2xx responses,
but administrator verification and route helpers ignored the actual
`HTTPURLResponse.statusCode`. That allowed undocumented 201/202/204 responses to
prove administrator role or validate route success.

Changes:

- Manual and stored administrator verification now require exactly 200.
- Non-200 2xx verification throws `RouterAdministrationError.invalidResponse`.
- Manual verification does not save a credential on that failure.
- Stored verification neither rewrites nor deletes the existing administrator
  credential on that failure; only the existing exact 401 path deletes it.
- Shared admin GET/mutation and durable-mutation helpers require exactly 200.
- Existing exact 401, exact 403 `admin_required`, URL cancellation, stale
  generation, and durable-success translations remain unchanged.

TDD evidence:

1. A first test invocation found an XCTest async-autoclosure compile issue in
   the test itself. Values were awaited into locals before accepting RED.
2. Correct behavioral RED command:

   `swift test --package-path peakdo/apple/WattlineNetwork --filter 'RouterAdministrationClientTests/test(ManualVerificationRejectsNon200SuccessWithoutSavingCredential|StoredVerificationRequires200WithoutRewritingOrDeletingCredential)|RouterPairingAdministrationTests/testAdminRouteHelpersRejectUndocumentedNon200SuccessStatuses'`

   Executed 3 tests with 8 expected assertion failures: manual 201/204 both
   saved/unlocked, stored 204 verified, and token-list/pairing/durable-revoke
   helpers accepted 201/204/202.

3. GREEN: the identical command passed 3/3 with zero failures.

## Finding 3 — self-revocation returns the saved endpoint to enrollment

Root cause: self-revocation removed the matching Keychain client credential,
but scan records inferred connectability from saved host metadata alone. The
row therefore still selected router connection even though enrollment was now
required.

Changes:

- Added a secret-free connection availability enum: available,
  enrollment-required, or unknown.
- `RouterConnectionModel` refreshes availability when saved hosts load and
  after every lease-conditional client credential deletion, including failure
  and stale-lease outcomes.
- Connection records carry that availability without carrying credential data.
- A saved endpoint without a client credential selects PIN enrollment when the
  router is currently discovered, or a prefilled manual existing-token recovery
  sheet otherwise. It never selects `connectRouter` in the enrollment-required
  state.
- Saved host metadata and administrator credential remain intact.
- The lease-protected delete still removes only the matching endpoint's client
  credential. A newly saved successor credential wins and availability refresh
  observes it as available.

TDD evidence:

1. RED focused simulator build failed on the intentionally missing connection
   availability property, enrollment-required enum case, record initializer
   argument, and manual-enrollment action. An inaccessible synthesized
   `DiscoveredRouter` initializer in the app test target was removed from the
   test fixture; the production discovered-router branch is driven by the same
   availability decision and the non-vacuous saved-host recovery regression
   remained.
2. GREEN focused command passed 2/2:
   `testScanPresentationOffersAdministrationOnlyForSavedHost` and
   `testRevokingCurrentClientDeletesOnlyClientCredentialPreservesHostAndRelists`.
3. The self-revoke regression additionally proves:
   final scan availability is enrollment-required, primary action is manual
   enrollment recovery, saved host/admin metadata survive, the matching client
   credential is nil, and an unrelated endpoint's client credential is
   unchanged.
4. Final model-class run passed 69/69, including cleanup-failure and
   same-endpoint reenrollment lease races.

## Finding 4 — aggregate, DC, and Type-C history series with gaps

Root cause: the pure presentation exposed only aggregate power and the chart
filtered nil samples before drawing one line. Individual DC/Type-C values were
not rendered, and filtering nil values let a line visually bridge missing
samples.

Changes:

- Preserved the existing aggregate series semantics: both missing -> nil;
  otherwise sum the available exact port values.
- Added exact nil-preserving aggregate, DC, and Type-C series points.
- Added deterministic segment identifiers; a missing sample terminates the
  current line segment and the next observed value begins a new one.
- Swift Charts now renders all three logical series, groups line segments so
  gaps remain gaps, and distinguishes them with legend style, symbols, width,
  and Type-C dashing.

TDD evidence:

1. RED:

   `swift test --package-path peakdo/apple/WattlineUI --filter RouterHistoryPresentationTests/testPowerSeriesPreserveExactValuesSortingAndMissingValueGaps`

   Failed to compile because `powerSeriesPoints` and its series types did not
   exist.
2. GREEN: the identical command passed 1/1.
3. The regression checks unsorted input, exact sorted timestamps, exact
   aggregate/DC/Type-C values, nils, segment changes across gaps, and preservation
   of the original aggregate `powerPoints` API.

## Final verification

- `swift test --package-path peakdo/apple/WattlineNetwork`
  - PASS: 144 tests, 0 failures.
- `swift test --package-path peakdo/apple/WattlineUI`
  - PASS: 33 tests, 0 failures.
- Focused `RouterAdministrationModelTests` simulator run
  - PASS: 69 tests, 0 failures.
- `xcodebuild test -quiet -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination 'platform=iOS Simulator,name=Wattline-Tests-2' CODE_SIGNING_ALLOWED=NO`
  - PASS: 246 tests, 0 failures, 0 skipped, including UI tests.
  - Result bundle summary: iPhone 17e, iOS Simulator 26.5.
  - Xcode emitted transient `DebuggerVersionStore ... no debugger version`
    launch diagnostics while retrying UI runners; the command completed exit 0
    and the result bundle reports Passed.
- `xcodebuild build -quiet -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`
  - PASS, exit 0.
- `git diff --check`
  - PASS, no whitespace errors.

## Commits and exact change count

- `1cb6cd54 fix: preserve router history power series`
  - Finding 4.
- `ba94480c fix: harden router administration workflows`
  - Findings 1–3, including exact status enforcement, FIFO atomic mutation
    workflows, stale/durable cleanup semantics, and enrollment availability.

From `6d0ad0b8` through `ba94480c`: 2 commits, 12 files changed, 674
insertions, 68 deletions.

## Remaining real-router checks

Unit/simulator tests cannot prove daemon and physical-device behavior. Before a
release, verify against live `wattlined`: exact administrator verification,
two near-simultaneous token revocations and relists, revoked-token SSE closure,
self-revocation returning the saved row to PIN/manual enrollment, and visible
chart gaps/series using real bounded history payloads.
