# Task 24 final verification report

## Result

Milestone 5 verification is complete at source HEAD `c8406363b24f77909fcf1d81561b75b84b1f967f` on branch `codex/wattline-phase-2`.

- All three Swift package suites passed.
- All three exact Xcode test schemes passed from fresh result bundles.
- Both generic platform builds passed.
- `WattlineCore` remains exactly 156 tests.
- The architecture, dependency, endpoint, ownership, webhook, scope, secret/logging, forbidden-file, frozen-interface, and ABI audits passed.
- This task changes documentation only: this report and the planned Task 19 correction to owner-authoritative clean combined `293/293` results for both schemes.
- No production source, router repository, OTA, or Timers work was changed or started.

The Milestone 5 implementation started from `35d8b321c005c64d20b4c1978415c192114cce41`. The plan-specified cross-milestone audit base is `845d8529`. The verified pre-report source HEAD is `c8406363b24f77909fcf1d81561b75b84b1f967f`.

Task 19 correction provenance: the clean combined `293/293` Wattline and WattlineWidgets results were confirmed by an independent review/owner rerun after the original Task 19 report. Those post-review artifacts are not retained at the old Milestone 4 paths or in the current evidence set. The retained old app and split-widget artifacts show only the earlier undercount/decomposed runs and are not cited as evidence for the corrected counts.

## Milestone 5 commits

Task 20:

- `270df4f4c839a33fd9db04e5d4f8cd420f6830b5` — `feat: add router automation rules`
- `58b136332bff0adc7275ddd5f094e22a6cad4d6e` — `fix: preserve forward-compatible router rules`

Task 21:

- `4d2d8356c1a610055134e6c2a0d66d1f5c18e7b1` — `feat: present router automation rules`
- `a5e46b787c4ca61b4c7d3743444375ae3261a36c` — `fix: complete router rule editing`
- `2068f4aae286dc6b1fa24a10378e8a728a85c1bc` — `fix: keep rule names immutable on update`

Task 22:

- `11a4edadf87255d897176f28c82fbe9f146fc9df` — `feat: add Wattline macOS menu bar app`
- `78ccdc7594edd695d3075659c2d1a7a2a1d7d1f2` — `fix: complete shared mac administration`
- `6a3049e21ffae2233a6a0bffb1a12dc84788e849` — `fix: harden mac enrollment lifecycle`

Task 23:

- `a253b2ef5165af9f3cfef95eda323ac7148991d2` — `feat: complete router administration demo`
- `a2eb5122c3c8a494a20148e1e96628f1d733fc42` — `fix: harden router administration demo`
- `c8406363b24f77909fcf1d81561b75b84b1f967f` — `fix: preserve mac pairing route during service switch`

## Fresh final verification

Every final command was run from `/Users/keith/.codex/worktrees/wattline-phase-2` with `set -o pipefail`. Each transcript records the pipeline exit explicitly as `EXIT_CODE=0`.

### Swift packages

```bash
swift test --package-path peakdo/apple/WattlineCore 2>&1 | tee /tmp/wattline-m5-core.log
swift test --package-path peakdo/apple/WattlineUI 2>&1 | tee /tmp/wattline-m5-ui.log
swift test --package-path peakdo/apple/WattlineNetwork 2>&1 | tee /tmp/wattline-m5-network.log
```

Final output:

| Suite | XCTest result | Failures | Exit | Transcript |
|---|---:|---:|---:|---|
| WattlineCore | 156/156 | 0 | 0 | `/tmp/wattline-m5-core.log` |
| WattlineUI | 64/64 | 0 | 0 | `/tmp/wattline-m5-ui.log` |
| WattlineNetwork | 240/240 | 0 | 0 | `/tmp/wattline-m5-network.log` |

The package logs also contain Swift Testing's separate `0 tests in 0 suites` footer. Counts above are the XCTest totals and are not added to that footer. The Core invariant is exactly 156.

### Exact Xcode test schemes

Pre-existing result paths were removed only after confirming that each resolved under `/tmp` with one of the exact names below.

```bash
WATTLINE_SIMULATOR_NAME=${WATTLINE_SIMULATOR_NAME:-Wattline-Tests-2}
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination "platform=iOS Simulator,name=${WATTLINE_SIMULATOR_NAME}" CODE_SIGNING_ALLOWED=NO -resultBundlePath /tmp/Wattline-M5.xcresult 2>&1 | tee /tmp/wattline-m5-ios.log
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineWidgets -destination "platform=iOS Simulator,name=${WATTLINE_SIMULATOR_NAME}" CODE_SIGNING_ALLOWED=NO -resultBundlePath /tmp/WattlineWidgets-M5.xcresult 2>&1 | tee /tmp/wattline-m5-widgets.log
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -resultBundlePath /tmp/WattlineMac-M5.xcresult 2>&1 | tee /tmp/wattline-m5-mac.log
```

The fresh `xcresulttool` summaries, rather than scheme overlap or passing-line counts, are authoritative:

| Scheme | Result | Total | Passed | Failed | Skipped | Expected failures | Exit | Result bundle |
|---|---|---:|---:|---:|---:|---:|---:|---|
| Wattline | Passed | 324 | 324 | 0 | 0 | 0 | 0 | `/tmp/Wattline-M5.xcresult` |
| WattlineWidgets | Passed | 324 | 324 | 0 | 0 | 0 | 0 | `/tmp/WattlineWidgets-M5.xcresult` |
| WattlineMac | Passed | 16 | 16 | 0 | 0 | 0 | 0 | `/tmp/WattlineMac-M5.xcresult` |

The two iOS schemes overlap by design. They are reported independently; their counts are not added or otherwise inferred.

### Generic builds

```bash
xcodebuild build -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/wattline-m5-ios-build.log
xcodebuild build -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineMac -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/wattline-m5-mac-build.log
```

- Wattline generic iOS Simulator: `** BUILD SUCCEEDED **`, exit 0. The build produced the simulator app for arm64/x86_64.
- WattlineMac generic macOS: `** BUILD SUCCEEDED **`, exit 0. The universal arm64/x86_64 build validated the embedded `WattlineWidgets.appex`.

### Result extraction and identities

For each fresh bundle, these commands were run with `--compact`; every command exited 0:

```bash
xcrun xcresulttool get test-results summary --path /tmp/Wattline-M5.xcresult --compact
xcrun xcresulttool get test-results tests --path /tmp/Wattline-M5.xcresult --compact
xcrun xcresulttool get test-results test-details --path /tmp/Wattline-M5.xcresult --test-id '<selected-test-id>' --compact
xcrun xcresulttool get test-results summary --path /tmp/WattlineWidgets-M5.xcresult --compact
xcrun xcresulttool get test-results tests --path /tmp/WattlineWidgets-M5.xcresult --compact
xcrun xcresulttool get test-results test-details --path /tmp/WattlineWidgets-M5.xcresult --test-id '<selected-test-id>' --compact
xcrun xcresulttool get test-results summary --path /tmp/WattlineMac-M5.xcresult --compact
xcrun xcresulttool get test-results tests --path /tmp/WattlineMac-M5.xcresult --compact
xcrun xcresulttool get test-results test-details --path /tmp/WattlineMac-M5.xcresult --test-id '<selected-test-id>' --compact
```

Extracted files:

- summaries: `/tmp/wattline-m5-ios-summary.json`, `/tmp/wattline-m5-widgets-summary.json`, `/tmp/wattline-m5-mac-summary.json`;
- test trees: `/tmp/wattline-m5-ios-tests.json`, `/tmp/wattline-m5-widgets-tests.json`, `/tmp/wattline-m5-mac-tests.json`;
- representative details: `/tmp/wattline-m5-ios-test-details.json`, `/tmp/wattline-m5-widgets-test-details.json`, `/tmp/wattline-m5-mac-test-details.json`.

iOS identity for both Wattline and WattlineWidgets:

- device: `Wattline-Tests-2`, iPhone 17e;
- UDID: `74C1DA4D-7190-4497-AAD5-9EB140B3A96A`;
- platform: iOS Simulator 26.5, build 23F77;
- architecture: arm64.

macOS identity for WattlineMac:

- device: `My Mac`, MacBook Pro;
- device ID: `00006050-0002482A0131401C`;
- platform: macOS 26.5.2, build 25F84;
- architecture: arm64.

Representative detail extraction resolved:

- `AppModelReconnectTests/testAppDeclaresGlobalDarkAppearance()` from Wattline;
- `WattlineDemoUITests/testDemoModeDrivesEveryPhase1Surface()` from WattlineWidgets;
- `MacRouterAdministrationTests/testDeepLinkServiceGenerationRefreshesVisibleAdministrationInPlace()` from WattlineMac.

### Simulator runner initialization diagnostics

The first Wattline attempt and the required single rerun both contain one `FBSOpenApplicationServiceErrorDomain` / `RequestDenied` diagnostic for a cloned `WattlineUITests-Runner`. Xcode retried internally, executed the UI tests, printed `** TEST SUCCEEDED **`, produced a complete passing bundle, and exited 0. The first attempt remains at `/tmp/wattline-m5-ios-runner-init-attempt.log` and `/tmp/Wattline-M5-runner-init-attempt.xcresult`; the final run is the bundle reported above.

The WattlineWidgets run contains the same one-clone environmental launch denial, then recovered internally, executed all tests, printed `** TEST SUCCEEDED **`, and exited 0. WattlineMac did not show this diagnostic. There was no assertion failure in any final bundle, and repeated retry loops were intentionally avoided.

## Tasks 20–23 RED-to-GREEN provenance

The following historical logs were re-read during Task 24. Their direct failure/success excerpts establish that the milestone behavior was driven through RED before GREEN.

### Task 20 — rule model, CRUD, preset, and forward compatibility

- `/tmp/wattline-m5-task20-model-red.log`: `cannot find 'RouterRuleDocument' in scope`, `cannot find 'RouterRuleDuration' in scope`, and `cannot find 'RouterRule' in scope`; compilation failed as intended.
- `/tmp/wattline-m5-task20-crud-red.log`: `RouterAdministrationClient` had no `rules`, `createRule`, `updateRule`, or `deleteRule`, and `RouterPowerLossPreset` was absent.
- `/tmp/wattline-m5-task20-green.log`: `RouterRulesTests` executed 19 tests with 0 failures; selected tests passed, exit 0.
- `/tmp/wattline-m5-task20-fix-red.log`: future known-family enum values threw `invalidRule`; `Int64.max` failed to decode; exact large-number assertions failed. It executed 22 tests with 4 failures (2 unexpected), exit 1.
- `/tmp/wattline-m5-task20-fix-green.log`: 23 focused rule tests passed with 0 failures.
- `/tmp/wattline-m5-task20-fix-full-green.log`: WattlineNetwork executed 240 tests with 0 failures.

### Task 21 — rule presentation, full editing, protection, and immutable names

- `/tmp/wattline-m5-task21-ui-red.log`: missing `RouterRulePresentationValue`, `RouterRulesPresentation`, and `RouterPowerLossPresentation` diagnostics.
- `/tmp/wattline-m5-task21-app-red.log`: `** TEST FAILED **` with missing `reloadRules`, `rules`, `rulesFetchedAt`, `rulesLoadState`, `createRule`, `updateRule`, `deleteRule`, and `savePowerLossPreset` model APIs.
- `/tmp/wattline-m5-task21-ui-green.log`: 4 focused presentation tests passed, 0 failures.
- `/tmp/wattline-m5-task21-app-green.log`: full iOS scheme printed `** TEST SUCCEEDED **`, exit 0.
- `/tmp/wattline-m5-task21-fix-ui-red.log`: compilation failed before `RouterRuleDurationDraft` and its units existed.
- `/tmp/wattline-m5-task21-fix-app-red.log`: compilation failed before `RouterRuleDraft` and `RouterRuleActionDraft` existed.
- `/tmp/wattline-m5-task21-fix-protection-red.log`: reserved-name and unknown-rule collision protections failed before implementation.
- `/tmp/wattline-m5-task21-fix-no-action-red.log`: a network-valid known rule with no actions did not round-trip before the fix.
- `/tmp/wattline-m5-task21-fix-ui-focused-green.log`: 6 focused UI tests passed, 0 failures.
- `/tmp/wattline-m5-task21-fix-ui-full-green.log`: 64 UI package tests passed, 0 failures.
- `/tmp/wattline-m5-task21-fix-app-focused-green.log`: 131 focused model test-case lines passed, 0 failures.
- `/tmp/wattline-m5-task21-fix-app-full-green.log`: full iOS scheme printed `** TEST SUCCEEDED **`, exit 0, with 307 passing and 0 failed test-case lines.
- `/tmp/wattline-m5-task21-fix-protection-green.log` and `/tmp/wattline-m5-task21-fix-no-action-green.log`: the added protection and empty-action regressions passed.
- `/tmp/wattline-m5-task21-rename-red.log`: immutable-name regression failed 0/1, exit 65; update mode still dispatched a rename.
- `/tmp/wattline-m5-task21-rename-focused-green.log`: immutable-name regression passed 1/1.
- `/tmp/wattline-m5-task21-rename-model-green.log`: administration model suite passed 132/132.
- `/tmp/wattline-m5-task21-rename-full-green.log`: full iOS scheme passed 309/309, exit 0.

### Task 22 — macOS app, shared administration, explicit schemes, and enrollment lifecycle

- `/tmp/wattline-m5-task22-red.log`: `The project named "Wattline" does not contain a scheme named "WattlineMac"`.
- `/tmp/wattline-m5-task22-green.log`: new Mac scheme printed `** TEST SUCCEEDED **`; 4/4 passed in its fresh result.
- `/tmp/wattline-m5-task22-controller-widgets.log`: the initial direct widget command exited 70 because the auto-generated scheme had an incompatible destination intersection.
- `/tmp/wattline-m5-task22-review-red.log`: three Mac administration regressions failed against the placeholder/non-actionable implementation.
- `/tmp/wattline-m5-task22-widget-scheme-test-red.log`: explicit widget-scheme configuration regression failed before the shared scheme existed.
- `/tmp/wattline-m5-task22-explicit-app-schemes-red.log`: adding only the widget scheme removed the auto-generated `Wattline` scheme and established the need for all three explicit schemes.
- `/tmp/wattline-m5-task22-selection-red.log`: nearby enrollment source selection was not atomic before the fix.
- `/tmp/wattline-m5-task22-review-green-final.log`: the corrected Mac administration suite passed.
- `/tmp/wattline-m5-task22-lifecycle-red.log`: compilation failed before `MacRouterEnrollmentLifecycle` existed.
- `/tmp/wattline-m5-task22-image-import-red.log`: compilation failed before source-operation generations and non-publishing image parsing existed.
- `/tmp/wattline-m5-task22-lifecycle-green-final.log`: 5 focused lifecycle tests passed, 0 failed.
- `/tmp/wattline-m5-task22-lifecycle-full-green-final.log`: full Mac result passed 12/12 with 0 failed/skipped/expected.
- `/tmp/wattline-m5-task22-lifecycle-mac-build-final.log`: universal Mac app and embedded widget build succeeded.

Task 22's earlier report names `/tmp/WattlineWidgets-M5.xcresult` for its then-current 313/313 result. Task 24 intentionally replaced that same planned `/tmp` path with the fresh final-source bundle, which now reports 324/324. Historical Task 22 evidence is therefore taken from its log/report, not misattributed to the overwritten Task 24 bundle.

### Task 23 — deterministic Demo, no-write boundary, accessibility, and route lifecycle

- `/tmp/wattline-m5-task23-ios-red.log`: iOS tests failed to compile before `RouterAdministrationDemo` and the model `.demo` factory existed.
- `/tmp/wattline-m5-task23-mac-red.log`: complete navigation and semantic-identifier assertions failed before the Mac Demo composition.
- `/tmp/wattline-m5-task23-navigation-red.log`: leaving Demo administration discarded its in-memory host.
- `/tmp/wattline-m5-task23-navigation-green.log`: navigation preservation regression passed after the fix.
- `/tmp/wattline-m5-task23-review-ios-red2.log`: five focused regressions exposed retained BLE PIN state, unknown-rule mutation by name, pairing-state reload, and missing concrete accessibility semantics.
- `/tmp/wattline-m5-task23-review-ios-green.log`: 11 focused Demo/accessibility tests passed, 0 failed.
- `/tmp/wattline-m5-task23-review-mac-red.log`: the live Mac administration view lacked service-generation reset/reload behavior.
- `/tmp/wattline-m5-task23-review-mac-green.log`: 9 focused Mac administration tests passed, 0 failed.
- `/tmp/wattline-m5-task23-review-mac-model-red.log`: the Mac service-transition model test failed to compile before the injectable router-service boundary existed.
- `/tmp/wattline-m5-task23-review-mac-model-green.log`: focused service-transition behavior passed 1/1.
- `/tmp/wattline-m5-task23-review-ui-green.log`: WattlineUI passed 64/64.
- `/tmp/wattline-m5-task23-route-red.log`: deep-link service replacement tore down the old view and cleared the newly accepted pairing route.
- `/tmp/wattline-m5-task23-route-green.log`: the focused route regression passed after removing only the identity teardown.
- `/tmp/WattlineMac-Task23-Route-Final.xcresult`: historical final Mac route result passed 16/16. Task 24's fresh Mac bundle independently confirms 16/16 at final source.

## Final audit transcript

The combined raw transcript is `/tmp/wattline-m5-audits.log`. The broad logging/secret matches are also retained separately at `/tmp/wattline-m5-logging-scan.log`. Commands, meaningful output, and exits follow.

### Architecture, dependency, route, ownership, webhook, and scope commands

```bash
rg -n 'URLSession|NWBrowser|NWConnection|import Network|import Security' peakdo/apple/WattlineCore/Sources peakdo/apple/WattlineUI/Sources; echo "boundary=$?"
# no matches
# boundary=1

rg -n 'import WattlineNetwork' peakdo/apple/WattlineUI/Sources; echo "ui_source_dependency=$?"
# no matches
# ui_source_dependency=1

rg -n 'WattlineNetwork' peakdo/apple/WattlineUI/Package.swift; echo "ui_manifest_dependency=$?"
# no matches
# ui_manifest_dependency=1

rg -n '/device/action|/device/usbc-limit|/device/bypass-threshold|/device/schedules' peakdo/apple/WattlineCore/Sources peakdo/apple/WattlineUI/Sources peakdo/apple/WattlineNetwork/Sources peakdo/apple/Wattline/Wattline peakdo/apple/Wattline/WattlineMac peakdo/apple/WattlineShared; echo "deprecated_routes=$?"
# no matches
# deprecated_routes=1

rg -n 'BLETransport|DeviceSession\(|DeviceOperationBroker' peakdo/apple/WattlineNetwork/Sources peakdo/apple/WattlineShared/RouterAdministration peakdo/apple/Wattline/WattlineMac; echo "admin_ble_owner=$?"
# peakdo/apple/Wattline/WattlineMac/MacAppModel.swift:50: MacAppModel(transportFactory: { BLETransport() })
# peakdo/apple/Wattline/WattlineMac/MacAppModel.swift:58: session = DeviceSession(transport: owner)
# admin_ble_owner=0

rg -n 'URLSession|data\(from:|data\(for:|upload\(|download\(' peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterRules.swift peakdo/apple/WattlineShared/RouterAdministration peakdo/apple/Wattline/WattlineMac; echo "app_webhook=$?"
# no matches
# app_webhook=1

rg -n 'api/v1/device/ota|/device/timers|/device/schedules' peakdo/apple/WattlineCore/Sources peakdo/apple/WattlineUI/Sources peakdo/apple/WattlineNetwork/Sources peakdo/apple/Wattline/Wattline peakdo/apple/Wattline/WattlineMac peakdo/apple/WattlineShared; echo "ota_timer_scope=$?"
# no matches
# ota_timer_scope=1
```

The ownership output is the expected positive audit: exactly one `BLETransport()` and one `DeviceSession(transport:)`, both in `MacAppModel`. There is no Mac/shared-administration `DeviceOperationBroker` construction and no administration-side BLE owner.

### Rule URL and webhook ownership inspection

The canonical route scan found `/api/v1/rules` only at:

```text
peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterRules.swift:555
peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterRules.swift:584
peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterRules.swift:608
peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterRules.swift:632
peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterRulesTests.swift:250-253
peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterRulesTests.swift:280-281
peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterRulesTests.swift:304
```

The production occurrences are the canonical CRUD/re-list client; the remaining occurrences are its tests. Webhook references occur only in `RouterRules.swift`, `RouterRulesTests.swift`, the shared `RouterRulesView.swift`, and Foundation-only `RouterRulesPresentation.swift`. The app/shared/Mac URL-loading audit above has no match. Therefore the app models and views do not originate webhook requests; the router owns outbound webhook delivery.

### Logging and secret inspection

```bash
rg -n 'print\(|debugPrint\(|dump\(|Logger\(|os_log|NSLog|token|pin|privateKey|private_key|Fingerprint\(' peakdo/apple/WattlineNetwork/Sources peakdo/apple/Wattline/Wattline peakdo/apple/Wattline/WattlineMac peakdo/apple/WattlineShared; echo "logging_scan=$?"
# 455 broad identifier matches
# logging_scan=0

rg -n '(^|[^[:alnum:]_])(print|debugPrint|dump|Logger|os_log|NSLog)\(' peakdo/apple/WattlineNetwork/Sources peakdo/apple/Wattline/Wattline peakdo/apple/Wattline/WattlineMac peakdo/apple/WattlineShared
# no matches; exit 1

rg -n 'privateKey|private_key' peakdo/apple/WattlineNetwork/Sources peakdo/apple/Wattline/Wattline peakdo/apple/Wattline/WattlineMac peakdo/apple/WattlineShared
# no matches; exit 1
```

Every broad match was inspected. Classification:

- `print(` matches are substrings of `Fingerprint(` or `fingerprint(` and are semantic TLS pinning/validation identifiers, not logging calls.
- `@escaping`, `mapping`, and `keepingCapacity` are substring matches from the intentionally broad expression.
- Token matches are credential request/response plumbing, `Authorization` header construction, Keychain-backed `RouterCredentialStore`, token metadata labels, or redaction helpers. `DeviceOperationBroker`'s `token: UUID` is a cancellation identity, not a credential.
- PIN matches are pairing validation, secure-field state, immediate clearing, pairing-status presentation, redacted payload descriptions, and test/demo placeholder flows. The submitted Mac PIN is cleared before the asynchronous enrollment call.
- TLS fingerprint/pin matches are certificate normalization, staged-pin promotion, validation, and user-facing copy.
- Error descriptions and reflections that can encounter bearer values use `[REDACTED]` replacement in `RouterConnection`, `NetworkError`, `RouterPairingPayload`, `RouterAdministrationDemo`, `RouterCredentialStore`, `RouterPairingAdministration`, `RouterDevicePairing`, `RouterAdvancedControls`, `RouterTransport`, `RouterSettings`, and `RouterEnrollment` paths.
- One narrow text search that combined logging words with secret words matched user-facing `ScanView` warning copy mentioning a bearer token and pinned fingerprint; it is not passed to a log sink.
- There are zero actual `print`, `debugPrint`, `dump`, `Logger`, `os_log`, or `NSLog` call sites in the audited production roots and zero `privateKey`/`private_key` identifiers.

The broad scan's per-file counts were reviewed as a coverage aid: Router administration model 65; Router connection 43; token view 32; host store and device pairing 21 each; Mac administration view 18; shared connection model and enrollment 17 each; settings view and administration client 16 each; advanced controls 15; credentials 13; pairing administration and HTTP client 12 each; device pairing view and settings 10 each; Demo, TLS rotation, and iOS administration view 9 each; remaining files 8 or fewer. The full 455-line path/line transcript is preserved in `/tmp/wattline-m5-logging-scan.log`.

No logging, persistence, or disclosure defect was found, so no production edit was made.

### Diff, status, and forbidden-file commands

```bash
git diff --check 845d8529..HEAD; echo "diff_check=$?"
# no output
# diff_check=0

git status --short; echo "status=$?"
# no output before documentation edits
# status=0

git diff --name-only 845d8529..HEAD -- peakdo/Wattline-SPEC.md peakdo/API.md peakdo/src scan.py verify.py; echo "forbidden_files=$?"
# no output
# forbidden_files=0

git diff 845d8529..HEAD -- peakdo/apple/WattlineCore/Sources/WattlineCore/DeviceCommand.swift peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterTransport.swift; echo "contracts_diff=$?"
# no output
# contracts_diff=0
```

`git diff` returning 0 means the command ran successfully, including when the selected files have no diff. The forbidden router contract/OEM/helper file list is empty.

### Demo no-write boundary

The Demo composition was inspected in addition to the logging audit:

- iOS `AppModel` enters the fixture through `.demo()`.
- Mac uses `RouterConnectionModel.demo` and `RouterAdministrationModel.demo` until the explicit real-device transition.
- `RouterAdministrationDemo` supplies in-memory credential and host backends.
- Its external-access factories throw `RouterAdministrationDemoError.externalAccess`.
- Demo construction, loads, and mutation paths therefore do not invoke Keychain, production host persistence/app-group defaults, Bonjour discovery, BLE, or HTTP transport.

## Frozen interfaces and ABI

### Source interface check

The Task 24 recipe names `peakdo/apple/WattlineCore/Sources/WattlineCore/DeviceCommand.swift`, but that path does not exist in the repository. The frozen `DeviceCommand` declaration is owned by:

```text
peakdo/apple/WattlineCore/Sources/WattlineCore/Device/DeviceController.swift
```

The actual file was compared with audit base `845d8529`:

```text
base blob: 20cdccf746c3e297f01067d423e269fce5ab4d2f
HEAD blob: 20cdccf746c3e297f01067d423e269fce5ab4d2f
git diff --quiet exit: 0
```

The inspected interface still includes request, result policy, expected read, reconciler, timeout, follow-up, and disconnect policy plus its existing set-DC, Type-C, limit, bypass, restart, enter-OTA, shutdown, and running-mode factories. Task 20–23 did not change it.

`RouterTransport.swift` was also compared with base `845d8529`:

```text
base blob: 93c832f32b91360dfdeaa1d1dc139500591d830f
HEAD blob: 93c832f32b91360dfdeaa1d1dc139500591d830f
git diff --quiet exit: 0
```

### Fresh binary and symbol

The binary used for the ABI audit was freshly produced by the final generic Mac build:

```text
/Users/keith/Library/Developer/Xcode/DerivedData/Wattline-bllgkpgqobwktoceschihenjdzrq/Build/Products/Debug/WattlineNetwork.o
size: 12034472 bytes
mtime: 2026-07-20T12:58:18-0700
file: Mach-O universal object, x86_64 and arm64
```

The literal plan regex was run first:

```bash
nm -gU "$WATTLINE_NETWORK_BINARY" | swift demangle | rg 'RouterTransport.*init.*RouterEndpoint.*RouterCredentialProvider.*RouterHTTPClient.*RouterSSEClient.*RouterConnectionClock.*RouterConnectionTiming'
```

It produced no match and exited 1 because the plan uses stale protocol names. Neither `RouterSSEClient` nor `RouterConnectionTiming` exists in the frozen base or current source. The source interface uses `RouterEventStream` and `RouterReconnectBackoff`.

The corrected source-faithful ABI command was:

```bash
nm -gU "$WATTLINE_NETWORK_BINARY" | swift demangle | rg 'RouterTransport.*init.*RouterEndpoint.*RouterCredentialProvider.*RouterHTTPClient.*RouterEventStream.*RouterConnectionClock.*RouterReconnectBackoff'
```

Output and exit:

```text
0000000000125bb0 T WattlineNetwork.RouterTransport.__allocating_init(endpoint: WattlineNetwork.RouterEndpoint, credentials: WattlineNetwork.RouterCredentialProvider, client: WattlineNetwork.RouterHTTPClient, events: WattlineNetwork.RouterEventStream, clock: WattlineNetwork.RouterConnectionClock, backoff: WattlineNetwork.RouterReconnectBackoff) -> WattlineNetwork.RouterTransport
SIX_ARG_ABI_EXIT_CODE=0
```

The exact six-argument allocating initializer is present. The corrected symbol transcript is `/tmp/wattline-m5-routertransport-six-arg-abi.log`; all demangled initializer symbols are in `/tmp/wattline-m5-routertransport-init-symbols.log`.

## Deviations from the Step 0 plan

### Tasks 20–23 implementation deviations

1. Task 20's review exposed two forward-compatibility details beyond the compressed plan: known condition-family enum variants had to be classified as lossless unknown documents before enum parsing, and JSON numbers could not all pass through `Double` without corrupting values above 2^53. Exact `Int64`/`Decimal` representations were added while preserving source-compatible `.number(Double)` behavior for exactly representable values.
2. Task 21's review expanded the initial typed editor into a complete all-condition/all-action form, replaced raw nanosecond inputs with checked human duration units, preserved valid empty-action rules, hardened unknown/reserved collision paths, and made update names immutable. These changes were review-driven corrections required to satisfy the route/model contracts rather than scope expansion into a later milestone.
3. Task 22 moved the seven functional router-administration views into `WattlineShared`, not only `RouterAdministrationModel`, because macOS had to consume the same working controls rather than parallel placeholders. It also hoisted the thin `RouterConnectionModel`, enrollment route/coordinator, and pure QR image-recognition types; platform-only camera capture and adapters remained in their app roots.
4. Task 22 added explicit shared `Wattline`, `WattlineWidgets`, and `WattlineMac` schemes. Adding a single shared scheme suppressed Xcode's generated app schemes, and the generated multi-platform widget scheme produced an incompatible test-host/destination intersection, so all three explicit schemes were required for deterministic gates.
5. Task 22 added review-driven Mac enrollment lifecycle, image-source generation, atomic selection, and deep-link route preservation waves. These were necessary after focused RED tests demonstrated stale task publication, retained route PINs, and accepted pairing routes being cleared during service replacement.
6. The optional running-mode cleanup described by the plan was deferred. The nearby capability input could not safely widen the device enum without changing frozen router/device contracts, and the cleanup was unrelated to the required Mac composition.
7. Task 23's first fixture run found malformed JSON in new test data. The fixture JSON was corrected and fixture `try!` calls were removed so construction propagates errors while the public `.demo` boundary remains nonthrowing and blocks external access.
8. Task 23 added review-driven hardening for submitted-secret clearing, unknown-rule mutation identity, lifecycle pairing-state reload, concrete accessibility semantics, Mac service-generation replacement, and deep-link route preservation. Each change followed a focused RED reproduction and remained inside deterministic Demo/composition scope.

### Task 24 recipe deviations

1. The planned `DeviceCommand.swift` audit path is stale. The real tracked owner is `Device/DeviceController.swift`; both its base/HEAD blob identity and clean diff were recorded instead of treating an absent path as proof.
2. The planned ABI regex uses stale `RouterSSEClient` and `RouterConnectionTiming` names. The frozen source and binary use `RouterEventStream` and `RouterReconnectBackoff`; the corrected exact six-argument symbol matched with exit 0.
3. The planned Task 19 destination under `peakdo/apple/docs/superpowers/sdd` did not exist. The already tracked Task 19 report is `.superpowers/sdd/task-19-report.md`; its Results and deviation text record the owner-authoritative clean combined `293/293` result for both schemes, confirmed by an independent review/owner rerun after the original report. Those post-review artifacts are not retained at the old Milestone 4 paths/current evidence set, and the retained earlier undercount/split artifacts are not presented as provenance. This Task 24 report remains at the plan's requested durable documentation path.
4. The first and rerun iOS app invocations, plus the widget invocation, each logged an environmental denial for one cloned UI runner. Xcode recovered internally and the final commands exited 0 with complete 324/324 passing bundles. The requested one rerun was performed; no unbounded retry loop was used.
5. The Task 22 report's `/tmp/WattlineWidgets-M5.xcresult` path was overwritten intentionally by Task 24's fresh required bundle. The new bundle is authoritative for final-source 324/324; historical Task 22 counts remain documented in its report/logs.

No deviation changed product behavior or weakened a verification invariant.

## Live checks still required

Unit tests, simulators, unsigned generic builds, and static audits cannot prove the following. These checks carry forward all unresolved M1–M4 items and add Milestone 5's live integration checks.

### Carried from Milestone 1

- Run restart and shutdown against physical hardware and verify the emitted firmware command bytes, disconnect timing, hardware effect, and subsequent reconnect/recovery behavior.
- Confirm authoritative post-command readback and real BLE timing on a supported device, including USB/firmware-specific behavior that fixtures only model.

### Carried from Milestone 2 and system surfaces

- Verify real app-group persistence and sharing under signed iOS/macOS apps and the installed widget extension.
- Verify background wake/reconnect and telemetry refresh on physical devices.
- Exercise a locked-device discharge cycle and Live Activity lifecycle.
- Confirm real widget timeline reload behavior and authoritative BLE telemetry on hardware.
- Verify manual and stored administrator credentials against a live `wattlined` exact-200 `/api/v1/settings`, including rejection of client credentials without promotion.
- Submit two near-simultaneous live token revocations and confirm FIFO authoritative relists converge on the daemon's final token list.
- Revoke a client token and confirm its live SSE stream closes and cannot reconnect with that revoked credential.
- Revoke this device's own token and confirm only its client credential is removed, saved host and administrator state persist, and the saved row returns to PIN/manual enrollment.
- Confirm aggregate, DC, and Type-C chart series and visible gaps using real bounded-history payloads.

### Carried from Milestone 3

- Save real router settings, restart `wattlined`/the router, and verify authoritative readback.
- Exercise listener migration while preserving a reachable same-device replacement.
- Exercise TLS rotation across restart: staged-only trial, explicit promotion, ordinary reconnect, and rejection of the old leaf/pin.
- Confirm token-store cutover and closure of managed SSE connections without claiming that token migration occurred.

### Carried from Milestone 4

- Physical BlueZ scan, pair, and unpair against a Link-Power.
- Empty-PIN retention of the router's configured PIN.
- Real bypass-threshold and barrier-free authoritative readback.
- Real clock drift, clock sync, and `available:false` behavior with zero BLE I/O.
- Running-mode and BLE-PIN effects on hardware.
- Live-daemon distinction between `advanced_disabled` and `capability_unsupported`.

### Milestone 5 live checks

- Observe rules firing from real router telemetry, including condition, hold, hysteresis, repeat, enabled-state, and ordered action behavior.
- Confirm that the router—not Wattline—performs webhook delivery, including HTTPS/TLS, retries/failures, and payloads at the actual destination.
- Verify the power-loss shutdown preset across real input loss and recovery, including confirmation and preservation/reset behavior.
- Validate macOS Bonjour/local-network permission prompts and discovery on a real LAN.
- Validate launch-at-login behavior in an installed, signed Mac app.
- Validate signing, entitlements, sandbox/keychain/app-group behavior, and installed shared widget behavior on supported macOS hardware.
- Repeat physical BlueZ enrollment and administration from the Mac app.

## Handoff

All final local gates are green, the frozen contracts and six-argument ABI are intact, and the repository changes for Task 24 are documentation-only. The milestone stops here for final review. OTA and Timers remain out of scope.
