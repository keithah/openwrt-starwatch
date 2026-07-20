# Router Administration Milestone 3 — Task 15 verification and handoff

## Result

Status: **DONE**. This task made no feature change. It replaced the stale tracked Task 15 report
with this evidence-only handoff at reviewed head
`cfe205ca51a86c5ab538c1d8557c6241b9e1732f`.

All fresh required suite/build pipelines exited 0. The two required reversible mutations each
produced the named test failure, were restored exactly, and then produced a green rerun. No
sabotage was committed. Core remains exactly 156 tests. No Milestone 4/5 route or UI was begun.

Fresh unabridged command logs are ignored under `.superpowers/sdd/router-admin-m3-task-15-*.log`.
This report records the actual commands, outputs, and exit status needed to reproduce the audit.

## Step 0 — reviewed milestone history

Plan commit:

```text
e325cb76ff82ff857ecf0b509871d3c748b409bb  docs: plan router administration milestone 3
```

Task 12:

```text
9d345814be6dc18e33fd831ea4d8f88b5e71328f  feat: add typed router settings
d8d8a0094f998fb02f9d0f4cf947b0a20cfab71d  fix: redact router settings PIN
```

Task 13:

```text
1f18195c2dc57926d458ef22960573887cc6370c  feat: edit router configuration safely
8801d1c094de78a3ca0114792abde25cda62a4e8  fix: harden router settings migration
```

Task 14:

```text
f34dd037ee519fabe0e4511d388c8dd00be6edb7  feat: rotate router TLS pins safely
6469c1d371272d9a8b78f900dbf7b699c0cb5b14  fix: keep staged TLS promotion reachable
3bb4aef650cbb4b651dcaa5603217fc4b668f874  fix: serialize TLS promotion controls
cfe205ca51a86c5ab538c1d8557c6241b9e1732f  fix: harden TLS rotation invariants
```

## Fresh required verification

Commands were run with `setopt pipefail`; each command's pipeline status is recorded from
`pipestatus[1]` in `router-admin-m3-task-15-command-exits.log`.

```text
swift test --package-path peakdo/apple/WattlineCore
  Executed 156 tests, with 0 failures (0 unexpected)
  core_exit=0

swift test --package-path peakdo/apple/WattlineUI
  Executed 42 tests, with 0 failures (0 unexpected)
  ui_exit=0

swift test --package-path peakdo/apple/WattlineNetwork
  Executed 174 tests, with 0 failures (0 unexpected)
  network_exit=0

xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination "platform=iOS Simulator,name=Wattline-Tests-2" CODE_SIGNING_ALLOWED=NO
  ** TEST SUCCEEDED **
  ios_exit=0

xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineWidgets \
  -destination "platform=iOS Simulator,name=Wattline-Tests-2" CODE_SIGNING_ALLOWED=NO
  ** TEST SUCCEEDED **
  widgets_exit=0

xcodebuild build -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
  ** BUILD SUCCEEDED **
  build_exit=0
```

The Xcode commands emitted the already-known `DVTDeviceOperation` empty build-number and
`IDERunDestination` supported-platform diagnostics. They did not produce failures; both result
bundles report zero failures, skips, and expected failures.

### Authoritative xcresult summaries

The printed fresh bundles were:

```text
/Users/keith/Library/Developer/Xcode/DerivedData/Wattline-bllgkpgqobwktoceschihenjdzrq/Logs/Test/Test-Wattline-2026.07.19_17-29-05--0700.xcresult
/Users/keith/Library/Developer/Xcode/DerivedData/Wattline-bllgkpgqobwktoceschihenjdzrq/Logs/Test/Test-WattlineWidgets-2026.07.19_17-30-44--0700.xcresult
```

For each bundle, the exact `xcrun xcresulttool get test-results summary --format json` result was:

```text
result=Passed
totalTestCount=263
passedTests=263
failedTests=0
skippedTests=0
expectedFailures=0
deviceName=Wattline-Tests-2
modelName=iPhone 17e
platform=iOS Simulator
osVersion=26.5
osBuildNumber=23F77
architecture=arm64
deviceId=74C1DA4D-7190-4497-AAD5-9EB140B3A96A
```

Both extraction commands exited 0 (`ios_xcresult_exit=0`, `widgets_xcresult_exit=0`).
`xcrun simctl list devices available | rg "Wattline-Tests-2"` returned
`Wattline-Tests-2 (74C1DA4D-7190-4497-AAD5-9EB140B3A96A) (Shutdown)` with exit 0.

```text
xcodebuild -version
Xcode 26.6
Build version 17F113
xcode_version_exit=0

swift --version
swift-driver version: 1.148.6 Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)
Target: arm64-apple-macosx26.0
swift_version_exit=0
```

## Required boundary, secret, scope, and repository audit

The prescribed audit commands were executed verbatim under `set +e`; complete transcript:
`.superpowers/sdd/router-admin-m3-task-15-audit.log`.

```text
rg URLSession|NWBrowser|NWConnection|import Network|import Security in Core/UI Sources  -> boundary_exit=1
rg import WattlineNetwork in UI Sources                                      -> ui_network_import_exit=1
rg print(|debugPrint(|dump(|Logger|os_log|NSLog in Network/app Sources        -> logging_exit=0
rg UserDefaults near token|pin in Network/app Sources                         -> userdefaults_secret_exit=1
rg deprecated /device/action|usbc-limit|bypass-threshold|schedules            -> deprecated_routes_exit=1
rg api/v1/(pairing/|rules|device/advanced|device/ota) in Network/app           -> m4_m5_scope_exit=1
git diff --check                                                               -> diff_check_exit=0
git status --short                                                             -> status_exit=0 (clean; ignored evidence logs omitted)
rg WattlineNetwork peakdo/apple/WattlineUI/Package.swift                      -> ui_package_network_exit=1
git diff 75016b27 -- peakdo/Wattline-SPEC.md peakdo/API.md peakdo/src \
  peakdo/scan.py peakdo/verify.py                                              -> contract_oem_diff_exit=0, no output
git -C /Users/keith/src/openwrt-wattline status --short                        -> external_status_exit=0
 M docs/API.md
```

`logging_exit=0` is a documented textual false positive, not a production logging violation:
the only matches are identifiers/calls containing the substring `fingerprint(`, for example
`RouterTLSFingerprintPolicy.fingerprint(of:)`, `normalizeFingerprint(...)`, and TLS staging or
promotion names. The transcript contains no `print(`, `debugPrint(`, `dump(`, `Logger`,
`os_log`, or `NSLog` invocation. No code was changed to conceal that grep result.

The external router repository modification is pre-existing and untouched by this task:
`/Users/keith/src/openwrt-wattline/docs/API.md`. The milestone diff name-status contains no
contract, OEM source, router-repository, Core source, or UI package-manifest change. Core remains
free of network/security imports; UI does not depend on WattlineNetwork.

Whole-milestone review (`git diff 75016b27`, exit 0) found the M3 production routes only:

```text
GET  /api/v1/settings
PUT  /api/v1/settings
POST /api/v1/tls/rotate
GET  /api/v1/device
```

No M4/M5 route/UI is present. The changed M3 production files have no `TODO`, `TBD`,
`fatalError`, or `preconditionFailure` (`rg` exit 1). Manual diff review found redacted public
PIN descriptions, no secret interpolation, no UserDefaults PIN/token persistence, no dual-pin
trust or TOFU/downgrade/fallback, readback-only settings publication (no optimistic draft
assignment), no new transport owner, and staged-only TLS trial/promotion guarded by endpoint and
device identity compare-and-swap.

## Required mutation checks

Both mutations touched exactly one production comparison/validation line, were never committed,
and were restored before the next check.

```text
Sparse patch mutation:
RouterSettingsPresentation.swift
  tokenStore: tokenStore == original.tokenStore ? nil : tokenStore
  temporarily changed == to !=

swift test --package-path peakdo/apple/WattlineUI \
  --filter RouterSettingsPresentationTests.testUnchangedDraftProducesNoPatch
  Executed 1 test, with 1 failure (0 unexpected)
  XCTAssertEqual failed
  mutation_sparse_red_exit=1

After exact restoration, same command:
  Executed 1 test, with 0 failures (0 unexpected)
  mutation_sparse_green_exit=0
  post_sparse_restore_diff_check_exit=0

TLS lowercase-hex mutation:
RouterTLSRotation.swift
  temporarily accepted (65...70) uppercase hexadecimal bytes

swift test --package-path peakdo/apple/WattlineNetwork \
  --filter RouterTLSRotationTests.testRotateRejectsUppercaseShortNonHexAndRestartFalse
  Executed 1 test, with 1 failure (0 unexpected)
  Expected expression to throw
  mutation_tls_red_exit=1

After exact restoration, same command:
  Executed 1 test, with 0 failures (0 unexpected)
  mutation_tls_green_exit=0
  post_tls_restore_diff_check_exit=0
```

The mutation logs are retained as `router-admin-m3-task-15-mutation-{sparse,tls}-{red,green}.log`.
After both restorations `git diff --name-only` was empty, `git diff --check` exited 0, and
`git status --short` was empty before this report was replaced.

## Task 12–14 evidence and deviations

### Task 12

Report: `.superpowers/sdd/task-12-report.md`.

RED excerpt: `swift test --package-path peakdo/apple/WattlineNetwork --filter RouterSettingsTests`
failed because `RouterAdministrationClient.settings`, `RouterSettingsPatch`, and
`updateSettings` did not yet exist. GREEN: the focused suite passed 7 tests; after the redaction
fix it passed 8 tests, and the full Network suite passed 155 tests with 0 failures.

The documented small interface deviations were: use the existing
`ScriptedRouterHTTPClient.ok(...)` factory rather than hypothetical `.ok(...)`; relocate the
unchanged file-private credential test fixture to shared test support; add a local async-throws
assertion helper; order `advanced` before `mdns` to satisfy Swift argument-label ordering. The
review fix added redacted `CustomStringConvertible`/`CustomDebugStringConvertible` output for the
three PIN-bearing Network values. An unrelated existing Sendable warning in an HTTP test harness
was observed in a focused rebuild; it did not affect the full green suite.

### Task 13

Report: `.superpowers/sdd/task-13-report.md`.

RED excerpts established missing UI settings types, sparse nested patches, validators, save policy,
replacement validation, confirmations, settings model methods, and configuration-section state.
GREEN excerpts progressed from 1 through 7 focused UI tests, 1 through 2 focused Network tests,
and a 75-test focused app model suite. The final corrective verification was UI 42/0, Network
159/0, app model 75 passing, and generic build exit 0.

Documented deviations: task sketches used hypothetical fixtures, so the reviewed
`makeFixture`/`AdminScriptedHTTP` helpers were used; the migration harness is `async throws`
because production credential storage is asynchronous; and three incremental assertions were born
green because earlier minimal slices already guaranteed no fallback, no optimistic publication,
and stale-save rejection. Review fixes added exact post-edit listener survival, redirect rejection
before a credential-bearing follow-up, and UI-local PIN redaction. The report notes existing Xcode
destination diagnostics but no task defect.

### Task 14

Report: `.superpowers/sdd/task-14-report.md`.

RED excerpt: `swift test --package-path peakdo/apple/WattlineNetwork --filter RouterTLSRotationTests`
failed for missing rotation/promotion APIs and staged metadata; app RED failed for missing model
rotation/promotion controls. GREEN initially reached 12 focused Network tests and 81 focused app
tests. Subsequent independent review RED/GREEN cycles covered unreachable locked staged promotion,
Lock/Unlock overlap, malformed stored/response device IDs, endpoint-only replacement, exact body
bytes, and complete action exclusion. Final Task 14 verification: focused TLS 15/0, full Network
174/0, full UI 42/0, focused app model 86 passing, generic build exit 0.

Documented deviations: use the redirect-rejecting `makeMigration(endpoint:)` factory rather than
the brief's older `make(endpoint:)` wording; add conditional staging CAS to close a same-ID host
replacement race; expose explicit staged verification when locked only if a staged pin exists;
and expand TLS-operation exclusion across Lock, Unlock, Rotate, and Verify. These changes retain
active-pin-only ordinary connections, no automatic promotion, and no new authorization path.

## External validation still required

Unit/simulator tests cannot prove live-router behavior. Before release, perform:

1. A live settings save followed by `wattlined`/router restart and complete authoritative readback.
2. Listener migration while preserving a reachable, same-device replacement endpoint.
3. TLS rotation across restart: announced lowercase fingerprint, staged-only trial, promotion,
   ordinary reconnect, and rejection of the old leaf DER/pin.
4. Token-store cutover and confirmation that managed SSE streams close without claiming token
   migration.

## Stop condition

Task 15 stops here for review. No Task 16, Milestone 4, or Milestone 5 implementation has been
started.
