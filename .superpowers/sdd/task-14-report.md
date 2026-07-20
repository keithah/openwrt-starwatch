# Task 14 report — TLS staged-pin rotation and atomic promotion

## Result

Implemented Milestone 3 Task 14 only, starting from reviewed Task 13 head
`8801d1c094de78a3ca0114792abde25cda62a4e8` on `codex/wattline-phase-2`.

The feature commit subject is exactly `feat: rotate router TLS pins safely`. Independent review
then identified two promotion-control races, addressed in the focused follow-up commits
`fix: keep staged TLS promotion reachable` and `fix: serialize TLS promotion controls`. All SHAs
are returned with the task handoff because recording the final commit's own SHA inside its contents
is self-referential.

## Behavior delivered

- `POST /api/v1/tls/rotate` sends the exact JSON body `{"confirm":true}` through the existing
  serialized administrator mutation path.
- Rotation accepts only an exact lowercase 64-character hexadecimal `sha256` and
  `restart_required: true`; uppercase, short, non-hex, and false-restart replies are rejected.
- Persisted fingerprints remain normalized uppercase. A staged fingerprint is stored separately
  and never changes the ordinary endpoint's active fingerprint before promotion.
- Legacy host JSON without a staged field decodes with `nil` staged state.
- Promotion constructs exactly one HTTPS trial endpoint with only the staged pin, uses the
  redirect-rejecting pinned URLSession factory, and sends the client credential only through that
  staged-pinned client.
- Promotion calls only `GET /api/v1/device`, normalizes and correlates its device ID, then performs
  an actor-isolated compare-and-swap from staged to active and clears staged state.
- Concurrent restaging, host replacement, and conditional-stage replacement are rejected as
  `hostChanged`; neither the stale trial nor stale rotation response overwrites newer metadata.
- After promotion, the ordinary endpoint contains only the promoted pin; deterministic leaf-DER
  tests prove the new bytes match and the old certificate bytes no longer match.
- The administrator settings UI exposes rotation only for HTTPS hosts, uses a destructive
  confirmation explaining that the active certificate remains in use until `wattlined` restarts,
  and exposes “Verify new certificate” only as a separate staged-pin action.
- After a restart makes the old active pin unusable, a reopened locked administration screen still
  offers the explicit staged-pin verification action. Successful promotion reattaches the
  administrator client to the promoted endpoint before a subsequent unlock.
- Lock and Unlock are both structurally disabled and model-guarded while staged verification is in
  flight, so neither can invalidate publication after the host-store promotion becomes durable.
- App publication is scoped to the captured host/session/admin/request generation. A stale
  completion after endpoint replacement does not stage into or publish over the replacement.

No TOFU, HTTP downgrade, fallback, automatic promotion, dual-pin trust, public-CA bypass, or
ordinary reconnect promotion was added.

## Strict TDD evidence

### Network RED

Command:

```text
swift test --package-path peakdo/apple/WattlineNetwork --filter RouterTLSRotationTests
```

Evidence: `/tmp/wattline-m3-task14-network-red.log`, exit 1. After correcting two test-harness-only
issues (`.ok` result inference and `await` inside XCTest autoclosures), RED failed specifically for
the missing `RouterTLSPinPromoter`, `RouterTLSPromotionError`, `rotateTLS`, staged metadata, and
host-store staging API. No production code existed for the feature at that point.

### Network GREEN

Command and result:

```text
swift test --package-path peakdo/apple/WattlineNetwork --filter RouterTLSRotationTests
12 tests, 0 failures, exit 0
```

Evidence: `/tmp/wattline-m3-task14-network-green.log`.

### App RED

Command:

```text
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination "platform=iOS Simulator,name=Wattline-Tests-2" CODE_SIGNING_ALLOWED=NO \
  -only-testing:WattlineTests/RouterAdministrationModelTests
```

Evidence: `/tmp/wattline-m3-task14-app-red.log`, exit 65. The build failed specifically for the
missing app `rotateTLS`, `promoteStagedTLSPin`, TLS state, and injected promotion HTTP factory.

### Focused compare-and-swap review RED/GREEN

Self-review added `testConditionalStageCannotWriteIntoConcurrentlyReplacedHost`. Its first run
failed non-vacuously because the compare-and-swap miss returned `invalidHost` rather than
`hostChanged` (1 test, 1 failure, exit 1). Splitting host validation from expected-host comparison
was the minimal fix; the next run passed (1 test, 0 failures), and the final 12-test focused suite
remained green.

### App GREEN

The same focused simulator command passed all 81 `RouterAdministrationModelTests`, including the
Task 14 app tests and the review regression, exit 0. Evidence:
`/tmp/wattline-m3-task14-app-green.log`.

### Independent review RED/GREEN

Independent review found that a freshly reopened administration screen could be locked after the
router restart while staged-pin verification was gated on unlocked access, making promotion
unreachable unless the original screen remained alive. The regression
`testLockedStagedHostCanPromoteAfterRestartThenUnlockOnPromotedPin` initially failed with three
assertions because locked promotion was a no-op (exit 65; evidence:
`/tmp/wattline-m3-task14-review-red.log`). The narrow fix permits only the explicit staged-pin
verification action while locked, reattaches administration to the atomically promoted endpoint,
and retains generation checks against the captured access state. The focused regression then
passed (exit 0; evidence: `/tmp/wattline-m3-task14-review-green.log`).

Re-review then found that Lock or Unlock could begin while the staged `/device` probe was gated,
invalidate the TLS generation, and suppress publication after the host-store compare-and-swap had
already promoted and cleared the staged pin. Two gated tests proved both overlaps non-vacuously:
`testUnlockCannotInvalidateLockedStagedPromotionInFlight` and
`testLockCannotInvalidateUnlockedStagedPromotionInFlight` both failed before the guard (exit 65;
evidence: `/tmp/wattline-m3-task14-overlap-red.log`). Model guards plus matching disabled UI states
were the minimal fix; both focused tests passed afterward (exit 0; evidence:
`/tmp/wattline-m3-task14-overlap-green.log`).

## Fresh verification

- `swift test --package-path peakdo/apple/WattlineNetwork --filter RouterTLSRotationTests`:
  **12 tests, 0 failures**, exit 0.
- `swift test --package-path peakdo/apple/WattlineNetwork`:
  **171 tests, 0 failures**, exit 0. Evidence: `/tmp/wattline-m3-task14-network.log`.
- `swift test --package-path peakdo/apple/WattlineUI`:
  **42 tests, 0 failures**, exit 0. Evidence: `/tmp/wattline-m3-task14-ui.log`.
- Focused iOS `RouterAdministrationModelTests`:
  **81 tests passed**, exit 0.
- `xcodebuild build -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`:
  **exit 0**. Evidence: `/tmp/wattline-m3-task14-build.log`.
- `git diff --check`: exit 0.
- Placeholder scan of changed lines: no new `TODO`, `TBD`, `fatalError`, or
  `preconditionFailure` matches (expected `rg` exit 1).
- ABI guard retained the original RouterTransport public initializer declarations, including the
  six-argument initializer, and retained
  `func credential(for endpoint: RouterEndpoint) async throws -> RouterCredential`.
- Route/scope audit found only the Task 14 production additions `/api/v1/tls/rotate` and
  `/api/v1/device`; no Milestone 4/5 surface was introduced.
- `RouterTLSPinning.swift`, contracts, OEM code, and router repository files are unchanged.

Xcode printed its existing `DVTDeviceOperation` empty-build-number and
`IDERunDestination: Supported platforms ... is empty` diagnostics, but both the focused test run
and generic build exited 0.

## Changed files

- `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterTLSRotation.swift` (new)
- `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterHostStore.swift`
- `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterTLSRotationTests.swift` (new)
- `peakdo/apple/Wattline/Wattline/RouterConnectionModel.swift`
- `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterAdministrationModel.swift`
- `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterAdministrationView.swift`
- `peakdo/apple/Wattline/Wattline/RouterAdministration/RouterSettingsView.swift`
- `peakdo/apple/Wattline/WattlineTests/RouterAdministrationModelTests.swift`
- `.superpowers/sdd/task-14-report.md`

## Deviations and rationale

- The brief's prose named `RouterURLSessionFactory.make(endpoint:)` for the production promoter.
  The dispatch requirement explicitly called out the current redirect-rejecting migration factory,
  so production uses `makeMigration(endpoint:)`. It preserves the exact staged-only pinning policy
  while additionally preventing bearer-bearing redirect follow-up requests.
- Added a conditional staging compare-and-swap overload and one extra Network test. This closes the
  narrow race between a valid rotation response and concurrent same-ID host replacement; the
  original simple staging method remains available as specified.
- Independent review expanded the separate verification action to the locked administration
  surface only when a staged pin exists. Rotation remains HTTPS-only inside unlocked Settings, and
  verification remains explicit: there is still no reconnect-time or automatic promotion.
- Re-review added model-level Lock/Unlock exclusion during promotion as well as disabled button
  states. This preserves the exact captured generation through durable compare-and-swap and model
  publication without broadening TLS authorization.
- Staging also requires an existing active pin. This enforces the no-TOFU requirement for rotation.
- Ran the explicitly requested generic iOS build in addition to the brief's focused suites.
- The pre-existing report at this path described an unrelated earlier widget task; it was replaced
  with the Task 14 evidence required by this dispatch.

## Remaining external concern

Unit and simulator tests prove endpoint construction, staged-only pin policy, redirect rejection,
credential-call ordering, correlation, persistence, and old-pin policy rejection. They cannot
perform a real router certificate rollover across a `wattlined` restart. A live-router check should
confirm the daemon returns the announced lowercase fingerprint, the pre-restart active session
continues to work, the post-restart staged-only trial succeeds, the old leaf is rejected, and the
promoted host reconnects normally. No implementation blocker remains.
