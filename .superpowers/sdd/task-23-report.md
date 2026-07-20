# Task 23 implementation report

## Scope and base

- Branch: `codex/wattline-phase-2`
- Starting HEAD: `6a3049e21ffae2233a6a0bffb1a12dc84788e849` (approved Task 22 HEAD)
- Scope: Task 23 only. Task 24, OTA, and Timers were not started.

## TDD evidence

Tests were written before the Demo fixture, Demo service boundary, platform composition, and accessibility semantics.

- `/tmp/wattline-m5-task23-ios-red.log`: the focused iOS test target failed to compile because `RouterAdministrationDemo` and `.demo` did not exist.
- `/tmp/wattline-m5-task23-mac-red.log`: the existing Mac tests passed while the new complete-navigation and semantic-identifier assertions failed.
- `/tmp/wattline-m5-task23-navigation-red.log`: the lifecycle regression failed because leaving Demo administration discarded its host; `/tmp/wattline-m5-task23-navigation-green.log` passed after preserving the in-memory session.
- The first full iOS GREEN attempt found one UI regression: changing the real-device control's accessibility label broke its established query. Restoring the exact visible label made the focused UI test and corrected full suite pass.

The fixture's first focused run also exposed malformed JSON in the new test data. The decoder crash attachment identified the exact lines; the JSON was corrected and all fixture `try!` calls were removed so fixture construction now propagates errors while `.demo` remains a safe, nonthrowing no-external-access boundary.

## Implementation

- Added a deterministic `RouterAdministrationDemo.fixture(now:)` containing fixed router identity and settings, 24 history samples, redacted pairing state, client metadata, paired and nearby BlueZ devices, all advanced values, a compatible `no_input_shutdown` preset, a known rule, and an unknown preserved rule.
- Added injected in-memory credential and host backends. Demo initialization, loads, and mutations do not enter discovery, HTTP, Keychain, app-group defaults, or production host persistence; mutations remain in the fixture across administration navigation.
- Wired iOS Demo settings to every administration surface and replaced the administration model only at explicit Demo/real-device transitions.
- Made macOS start in the same complete Demo administration state. BLE, discovery, and the production router stack are activated only by the explicit real-device action; transport ownership remains in `MacAppModel`.
- Applied the required identifiers and useful spoken labels to actual secret fields, charts, rule toggles, destructive actions, stale/unavailable states, Demo badges, and real-device controls on both platforms.
- Added focused fixture/no-write/lifecycle/semantic/navigation regressions and expanded the Mac composition tests.

## Verification

- `swift test --package-path peakdo/apple/WattlineUI`: 64 passed, 0 failed.
- Full iOS `Wattline` scheme: `/tmp/Wattline-Task23-Green-2.xcresult` reports 319 total, 319 passed, 0 failed, 0 skipped, and 0 expected failures on Wattline-Tests-2, iPhone 17e, iOS Simulator 26.5 (23F77).
- Full macOS `WattlineMac` scheme: `/tmp/WattlineMac-Task23-Green.xcresult` reports 14 total, 14 passed, 0 failed, 0 skipped, and 0 expected failures on My Mac, arm64 MacBook Pro, macOS 26.5.2 (25F84).
- Focused Demo tests: 6 passed, 0 failed. Focused Mac administration tests: 8 passed, 0 failed.
- `git diff --check`: clean. The project file passes `plutil -lint`.
- Static audits found exactly one macOS `BLETransport(` and one `DeviceSession(`, both in `MacAppModel`; no Demo crash traps, secret logging/persistence, forbidden endpoints, or Task 24 scope were introduced.

## Review hardening

Five review findings were reproduced with tests before production changes:

- `/tmp/wattline-m5-task23-review-ios-red2.log`: the new Demo tests showed a submitted BLE PIN retained in settings, unknown raw rules overwritten/deleted by name, lifecycle-cleared pairing state not reloaded, and missing concrete accessibility semantics.
- `/tmp/wattline-m5-task23-review-mac-red.log`: the live Mac administration view lacked a service-generation key, state reset, and generation-driven production-host reload.
- `/tmp/wattline-m5-task23-review-mac-model-red.log`: the behavioral Mac model regression failed to compile before the injectable router-service boundary existed.

The correction discards every submitted Demo BLE PIN after acknowledging the save, permits Demo update/delete only for matched known rules, republishes redacted fixture pairing state after lifecycle clearing, and keys Mac administration to a single-increment router-service generation. A real-device transition replaces the services exactly once; the visible view refreshes in place, clears Demo selection/secrets, preserves a newly consumed pairing route, reloads production hosts, and initializes without leave/re-entry. Accessibility checks now target the listener-migration destructive action and actual Advanced, Rules, and API-client empty/error states.

Final evidence:

- Focused Demo/accessibility suite: 11 passed, 0 failed (`/tmp/wattline-m5-task23-review-ios-green.log`).
- Focused Mac administration suite: 9 passed, 0 failed (`/tmp/wattline-m5-task23-review-mac-green.log`).
- Focused Mac service-transition behavior: 1 passed, 0 failed (`/tmp/wattline-m5-task23-review-mac-model-green.log`).
- WattlineUI: 64 passed, 0 failed (`/tmp/wattline-m5-task23-review-ui-green.log`).
- Full iOS: `/tmp/Wattline-Task23-Review.xcresult` reports 324 total, 324 passed, 0 failed, 0 skipped, and 0 expected failures on Wattline-Tests-2, iPhone 17e, iOS Simulator 26.5 (23F77).
- Final full macOS: `/tmp/WattlineMac-Task23-Review-Final.xcresult` reports 16 total, 16 passed, 0 failed, 0 skipped, and 0 expected failures on My Mac, arm64 MacBook Pro, macOS 26.5.2 (25F84).
- Final diff, ownership, crash-trap, secret-log/persistence, forbidden-endpoint, and Task 24 scope audits are clean.

## Pairing-route re-review

- `/tmp/wattline-m5-task23-route-red.log`: the focused Mac regression failed because `MacRootView` identity-keyed administration to the service generation, so a deep-link service switch tore down the old view and its disappearance cleanup cleared the newly accepted pairing route.
- The fix removes only that identity teardown. The existing generation-driven task still resets transient administration state through `invalidatePreservingRoute()`, reloads production hosts, and presents the accepted payload; genuine view disappearance retains its destructive route cleanup.
- `/tmp/wattline-m5-task23-route-green.log`: the focused regression passed after the fix.
- `/tmp/WattlineMac-Task23-Route-Final.xcresult`: 16 total, 16 passed, 0 failed, 0 skipped, and 0 expected failures on My Mac, arm64 MacBook Pro, macOS 26.5.2 (25F84).
- Final diff, whitespace, transport/session ownership, and Task 24 scope audits are clean.
