# Task 13 Report — Safe Settings Editor and Endpoint Migration Validation

## Outcome

- Status: DONE_WITH_CONCERNS
- Starting reviewed Task 12 head: `d8d8a0094f998fb02f9d0f4cf947b0a20cfab71d`
- Branch: `codex/wattline-phase-2`
- Commit: `feat: edit router configuration safely` (this amended commit)
- Scope stayed within Task 13. No contracts, OEM sources, router repository, Task 14, M4, or M5 work was changed.

## Delivered behavior

- Added UI-local settings value/draft/patch mirrors with sparse nested diffs, explicit empty mDNS interfaces, string-backed editable ports and BLE PIN, strict port/PIN validation, save blockers, same-device endpoint correlation, purpose-specific confirmations, and exact restart/token-store copy.
- Added a Network-owned endpoint migration validator that probes exactly the selected endpoint at `/api/v1/device`, authenticates with the source endpoint's administrator credential, validates a complete device response and normalized MAC, returns no credential, and performs no discovery, scheme rewriting, retry, or fallback.
- Added readback-only settings publication to `RouterAdministrationModel`. GET and complete PUT readbacks are generation guarded; drafts are never assigned to model state; begin/end/lock/auth-failure transitions clear settings and validation state.
- Added replacement validation using known saved/discovered hosts. Verified state is published only after a correlated probe and only while both session and replacement request generations remain current.
- Added the unlocked-only router configuration section and a SwiftUI editor covering HTTP, HTTPS, TLS paths/fingerprint, token store, pairing TTL/always-on, Advanced, mDNS/interfaces, WAN, and BLE PIN.
- BLE PIN uses `SecureField`, one-time-code content type, numeric keyboard, and monospaced digits. No PIN logging or interpolation was introduced.
- Save is absent for unchanged/invalid/zero-listener drafts. Listener migration, insecure WAN HTTP, and token-store cutover have separate confirmations. Restart-required copy is rendered only when an authoritative PUT readback sets `restart_required`.
- Self-review corrected two view defects before commit: failed saves now retain the user's draft, and restart-required copy is not used speculatively in the listener confirmation.

## TDD cycles and evidence

### WattlineUI

1. Unchanged draft
   - RED `/tmp/wattline-m3-task13-ui-cycle1-red.log`: `cannot find type 'RouterSettingsValue' in scope` / missing `RouterSettingsDraft`.
   - GREEN `/tmp/wattline-m3-task13-ui-cycle1-green.log`: `Executed 1 test, with 0 failures`.
2. Sparse nested changes and explicit empty interfaces
   - RED `/tmp/wattline-m3-task13-ui-cycle2-red.log`: expected HTTP port `9000` and mDNS `interfaces: []`, received `nil`.
   - GREEN `/tmp/wattline-m3-task13-ui-cycle2-green.log`: both presentation tests passed.
3. BLE PIN and port validation
   - RED `/tmp/wattline-m3-task13-ui-cycle3-red.log`: eight `XCTAssertThrowsError failed: did not throw an error` failures.
   - GREEN `/tmp/wattline-m3-task13-ui-cycle3-green.log`: validation test passed; 3/3 focused tests passed.
4. Zero-listener structural blocker
   - RED `/tmp/wattline-m3-task13-ui-cycle4-red.log`: missing `RouterSettingsSavePolicy`.
   - GREEN `/tmp/wattline-m3-task13-ui-cycle4-green.log`: 4/4 focused tests passed.
5. Correlated replacement requirement
   - RED `/tmp/wattline-m3-task13-ui-cycle5-red.log`: blocker was `nil` instead of `.validatedReplacementRequired`; wrong device incorrectly allowed save.
   - GREEN `/tmp/wattline-m3-task13-ui-cycle5-green.log`: 5/5 focused tests passed.
6. Purpose-specific confirmations
   - RED `/tmp/wattline-m3-task13-ui-cycle6-red.log`: empty confirmation sets instead of insecure-WAN/listener/token-store confirmations.
   - GREEN `/tmp/wattline-m3-task13-ui-cycle6-green.log`: 6/6 focused tests passed.
7. Honest copy
   - RED `/tmp/wattline-m3-task13-ui-cycle7-red.log`: missing `RouterSettingsCopy`.
   - GREEN `/tmp/wattline-m3-task13-ui-green.log`: 7/7 focused tests passed.

### WattlineNetwork

1. Selected endpoint and source administrator credential
   - RED `/tmp/wattline-m3-task13-network-cycle1-red.log`: missing `RouterEndpointMigrationValidator`.
   - GREEN `/tmp/wattline-m3-task13-network-cycle1-green.log`: 1/1 passed.
2. Device mismatch and missing administrator credential
   - RED `/tmp/wattline-m3-task13-network-cycle2-red.log`: mismatch probe did not throw.
   - GREEN `/tmp/wattline-m3-task13-network-cycle2-green.log`: 2/2 passed.
3. No scheme change or fallback
   - First run `/tmp/wattline-m3-task13-network-cycle3-first-run.log`: passed 1/1 without a new production edit. The explicit candidate factory call and normal error propagation added by the first tracer bullet already guaranteed this behavior.

### iOS administration model

1. Authoritative settings GET/PUT publication
   - RED `/tmp/wattline-m3-task13-app-cycle1-red.log`: model lacked `reloadSettings`, `settings`, `saveSettings`, and restart state.
   - GREEN `/tmp/wattline-m3-task13-app-cycle1-green.log`: `TEST SUCCEEDED`; focused test passed.
2. Locked/unlocked structural section visibility
   - RED `/tmp/wattline-m3-task13-app-cycle2-red.log`: presentation section lacked `.routerConfiguration`.
   - GREEN `/tmp/wattline-m3-task13-app-cycle2-green.log`: focused test passed.
3. No optimistic draft publication
   - First run `/tmp/wattline-m3-task13-app-cycle3-first-run.log`: passed. The model implementation from cycle 1 publishes only complete client results, so this incremental assertion required no production change.
4. Stale save after endpoint replacement
   - First run `/tmp/wattline-m3-task13-app-cycle4-first-run.log`: passed. The existing `performAdmin` session/admin guard plus the new settings request generation already rejected the completion.
5. Correlated replacement publication
   - RED `/tmp/wattline-m3-task13-app-cycle5-red.log`: model lacked `validateReplacement` and `validatedReplacement`.
   - GREEN `/tmp/wattline-m3-task13-app-cycle5-green.log`: focused test passed.

## Final verification after the last source edit

- `swift test --package-path peakdo/apple/WattlineUI`: 40 tests, 0 failures (`/tmp/wattline-m3-task13-ui-final.log`). Baseline 33 + 7 Task 13 tests.
- `swift test --package-path peakdo/apple/WattlineNetwork`: 158 tests, 0 failures (`/tmp/wattline-m3-task13-network-final.log`). Includes 3 Task 13 migration tests.
- Focused iOS `RouterAdministrationModelTests`: 75 tests passed (`/tmp/wattline-m3-task13-app-final.log`).
- Generic iOS simulator build: exit 0 (`/tmp/wattline-m3-task13-build-final.log`).
- `git diff --check`: exit 0.

## Changed files

- Created `peakdo/apple/WattlineUI/Sources/WattlineUI/RouterSettingsPresentation.swift`
- Created `peakdo/apple/WattlineUI/Tests/WattlineUITests/RouterSettingsPresentationTests.swift`
- Created `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterEndpointMigration.swift`
- Created `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterEndpointMigrationTests.swift`
- Modified `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterAdministrationModel.swift`
- Created `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterSettingsView.swift`
- Modified `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterAdministrationView.swift`
- Modified `peakdo/apple/Wattline/WattlineTests/RouterAdministrationModelTests.swift`

## Deviations

- The brief's test sketches referenced hypothetical `makeUnlockedHarness`, `settings(...)`, and `replacementHost()` helpers. Tests were adapted to the reviewed Task 12 fixture (`makeFixture` and `AdminScriptedHTTP`) without changing the asserted behavior.
- The migration harness is `async throws` because the real credential store's save API is asynchronous, and the scripted success helper is called as `ScriptedRouterHTTPClient.ok(...)` for unambiguous Swift type inference.
- Three incremental tests were born green as described above because earlier minimal production slices already guaranteed their behavior. No artificial fallback, optimistic publication, or stale-publication defect was introduced solely to force RED.

## Concerns

- Process-only TDD concern: the no-fallback, no-optimistic-publication, and stale-save tests passed on their first focused run rather than producing independent RED failures. They are non-vacuous and remain in the permanent suites, but they did not each require a new production delta.
- Xcode emits the environment's existing `DVTDeviceOperation` / empty supported-platform diagnostic while resolving the simulator destination; both focused tests and the generic simulator build exit successfully.
- No known product defect remains from self-review.
