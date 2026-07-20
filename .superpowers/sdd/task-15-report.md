# Router Administration Milestone 3 — Task 15 final verification and handoff

## Result

Status: **APPROVED AND VERIFIED** at final reviewed source head
`148afdb4ae1f1ca0e4d8e8d69e5ecb2ddc112877` on `codex/wattline-phase-2`.
The final-gate request supplied this exact head as approved. The gate made no production or test
change; its only tracked change is this evidence report.

All six required suite/build commands exited 0. Core remains exactly 156 tests; UI is 45; Network
is 185. The Wattline and WattlineWidgets result bundles each contain 276 passed tests with zero
failed, skipped, or expected failures. No Milestone 4/5 route or UI was begun.

Fresh unabridged output is retained under `/tmp/wattline-m3-final-gate-*`; exact paths are listed
below. Because `/tmp` is machine-local and ephemeral, this tracked report also records the
essential outputs and exit codes.

## Reviewed milestone history

Plan and Tasks 12–14:

```text
e325cb76ff82ff857ecf0b509871d3c748b409bb  docs: plan router administration milestone 3
9d345814be6dc18e33fd831ea4d8f88b5e71328f  feat: add typed router settings
d8d8a0094f998fb02f9d0f4cf947b0a20cfab71d  fix: redact router settings PIN
1f18195c2dc57926d458ef22960573887cc6370c  feat: edit router configuration safely
8801d1c094de78a3ca0114792abde25cda62a4e8  fix: harden router settings migration
f34dd037ee519fabe0e4511d388c8dd00be6edb7  feat: rotate router TLS pins safely
6469c1d371272d9a8b78f900dbf7b699c0cb5b14  fix: keep staged TLS promotion reachable
3bb4aef650cbb4b651dcaa5603217fc4b668f874  fix: serialize TLS promotion controls
cfe205ca51a86c5ab538c1d8557c6241b9e1732f  fix: harden TLS rotation invariants
```

Prior Task 15 evidence and the three approved final review waves:

```text
eef467cf  docs: record router administration milestone 3 verification
8a36a920  fix: close router administration final review gaps
a06d1003  fix: close router administration recovery races
148afdb4  fix: close final router administration review gaps
```

The final review waves added regression coverage and corrections for settings/migration recovery,
credential and host-store races, app administration state, endpoint migration error mapping, and
HTTP/SSE cancellation behavior. The final gate did not alter any of those approved changes.

## Fresh required verification

Commands were run sequentially in the required order. Each command wrote its complete stdout and
stderr directly to the named `/tmp` log, so the recorded shell exit is the command's own exit.

```text
swift test --package-path peakdo/apple/WattlineCore
  Executed 156 tests, with 0 failures (0 unexpected)
  core_exit=0

swift test --package-path peakdo/apple/WattlineUI
  Executed 45 tests, with 0 failures (0 unexpected)
  ui_exit=0

swift test --package-path peakdo/apple/WattlineNetwork
  Executed 185 tests, with 0 failures (0 unexpected)
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

No package log contains `skipped` or `expected fail` (`package_skip_marker_exit=1`). The package
summary extraction found all three final `All tests` summaries (`package_summary_exit=0`).

### Authoritative xcresult summaries

Fresh result bundles:

```text
/Users/keith/Library/Developer/Xcode/DerivedData/Wattline-bllgkpgqobwktoceschihenjdzrq/Logs/Test/Test-Wattline-2026.07.19_19-26-03--0700.xcresult
/Users/keith/Library/Developer/Xcode/DerivedData/Wattline-bllgkpgqobwktoceschihenjdzrq/Logs/Test/Test-WattlineWidgets-2026.07.19_19-27-57--0700.xcresult
```

`xcrun xcresulttool get test-results summary --format json` returned the following for both
bundles; each extraction exited 0 (`ios_xcresult_exit=0`, `widgets_xcresult_exit=0`):

```text
result=Passed
totalTestCount=276
passedTests=276
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

Environment identity:

```text
Wattline-Tests-2 (74C1DA4D-7190-4497-AAD5-9EB140B3A96A) (Shutdown)
simulator_list_exit=0
Xcode 26.6
Build version 17F113
xcode_version_exit=0
swift-driver version: 1.148.6 Apple Swift version 6.3.3
  (swiftlang-6.3.3.1.3 clang-2100.1.1.101)
Target: arm64-apple-macosx26.0
swift_version_exit=0
```

## Required boundary, secret, scope, and repository audits

Complete transcript: `/tmp/wattline-m3-final-gate-audits.log`.

### Boundary and dependency output

```text
$ rg -n 'URLSession|NWBrowser|NWConnection|import Network|import Security' \
  peakdo/apple/WattlineCore/Sources peakdo/apple/WattlineUI/Sources
boundary_exit=1
$ rg -n 'import WattlineNetwork' peakdo/apple/WattlineUI/Sources
ui_network_import_exit=1
$ rg -n 'WattlineNetwork' peakdo/apple/WattlineUI/Package.swift
ui_package_network_exit=1
```

All three commands produced no match output. Core/UI retain their network/security boundary, and
WattlineUI neither imports nor declares a dependency on WattlineNetwork.

### Logging output

```text
$ rg -n 'print\(|debugPrint\(|dump\(|Logger|os_log|NSLog' \
  peakdo/apple/WattlineNetwork/Sources peakdo/apple/Wattline/Wattline
peakdo/apple/Wattline/Wattline/RouterConnectionModel.swift:302:    func stageTLSCertificateFingerprint(
peakdo/apple/Wattline/Wattline/RouterConnectionModel.swift:306:        let staged = try await hostStore.stageCertificateFingerprint(
peakdo/apple/Wattline/Wattline/RouterAdministration/RouterAdministrationModel.swift:472:            let staged = try await connections.stageTLSCertificateFingerprint(
peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterPairingPayload.swift:85:                  let normalized = RouterHostValidator.normalizeFingerprint(rawTLS)
peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterDiscovery.swift:126:              let fingerprint = RouterHostValidator.normalizeFingerprint(tls) else { return nil }
peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterHostStore.swift:45:    func stagingCertificateFingerprint(_ value: String) -> RouterHostMetadata {
peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterHostStore.swift:61:    func promotingStagedCertificateFingerprint(_ value: String) -> RouterHostMetadata {
peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterHostStore.swift:124:            guard let value = normalizeFingerprint(certificateFingerprint) else {
peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterHostStore.swift:150:    public static func validateCertificateFingerprint(
peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterHostStore.swift:154:        guard let expected = normalizeFingerprint(expected),
peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterHostStore.swift:155:              let presented = normalizeFingerprint(presented)
peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterHostStore.swift:163:    public static func normalizeFingerprint(_ value: String) -> String? {
peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterHostStore.swift:235:    public func stageCertificateFingerprint(
peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterHostStore.swift:242:        return try stageCertificateFingerprint(fingerprint, for: id, expectedHost: nil)
peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterHostStore.swift:245:    public func stageCertificateFingerprint(
peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterHostStore.swift:253:        return try stageCertificateFingerprint(
peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterHostStore.swift:260:    private func stageCertificateFingerprint(
peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterHostStore.swift:265:        guard let normalized = RouterHostValidator.normalizeFingerprint(fingerprint),
peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterHostStore.swift:273:        host = host.stagingCertificateFingerprint(normalized)
peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterHostStore.swift:278:    func promoteCertificateFingerprint(
peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterHostStore.swift:295:        let promoted = host.promotingStagedCertificateFingerprint(expectedStaged)
peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterTLSRotation.swift:151:        return try await hostStore.promoteCertificateFingerprint(
peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterTLSPinning.swift:11:    public static func fingerprint(of certificateData: Data) -> String {
peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterTLSPinning.swift:18:        guard let normalized = RouterHostValidator.normalizeFingerprint(expected) else {
peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterTLSPinning.swift:21:        return normalized == fingerprint(of: certificateData)
peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterEnrollment.swift:118:            : RouterHostValidator.normalizeFingerprint(decoded.tlsSHA256)
peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterEnrollment.swift:123:            guard let expected = RouterHostValidator.normalizeFingerprint(expectedFingerprint),
peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterEndpointMigration.swift:227:        return RouterHostValidator.normalizeFingerprint(fingerprint) != nil
logging_exit=0
```

The positive exit is the expected textual false positive: `print(` occurs as a substring of
`Fingerprint(`. Every match above is a fingerprint identifier or call. There is no `print`,
`debugPrint`, `dump`, `Logger`, `os_log`, or `NSLog` logging invocation.

### Secret and route output

```text
$ rg -n -i 'UserDefaults.{0,120}(token|pin)|(token|pin).{0,120}UserDefaults' \
  peakdo/apple/WattlineNetwork/Sources peakdo/apple/Wattline/Wattline
userdefaults_secret_exit=1
$ rg -n '/device/action|/device/usbc-limit|/device/bypass-threshold|/device/schedules' \
  peakdo/apple/WattlineCore/Sources peakdo/apple/WattlineUI/Sources \
  peakdo/apple/WattlineNetwork/Sources peakdo/apple/Wattline/Wattline
deprecated_routes_exit=1
$ rg -n 'api/v1/(pairing/|rules|device/advanced|device/ota)' \
  peakdo/apple/WattlineNetwork/Sources peakdo/apple/Wattline/Wattline
m4_m5_scope_exit=1
```

All three commands produced no output. No PIN/token is persisted near UserDefaults, no deprecated
route is present in the four production trees, and no M4/M5 route was introduced.

### Contract/OEM and repository output

`git diff --name-only 75016b27..HEAD` exited 0 and listed only M3 reports/plans, app/Network/UI
implementation, and tests. The exact changed-name list is retained in the audit log. The scoped
forbidden check was:

```text
$ git diff --name-only 75016b27..HEAD -- peakdo/Wattline-SPEC.md peakdo/API.md \
  peakdo/src peakdo/scan.py peakdo/verify.py
forbidden_contract_oem_names_exit=0
$ git diff 75016b27..HEAD -- peakdo/Wattline-SPEC.md peakdo/API.md \
  peakdo/src peakdo/scan.py peakdo/verify.py
forbidden_contract_oem_diff_exit=0
$ git -C /Users/keith/src/openwrt-wattline status --short
 M docs/API.md
external_status_exit=0
```

Both forbidden-path commands produced no diff output. The external router repository's
`docs/API.md` modification is pre-existing and was not touched by this Apple-worktree gate.

Pre-report cleanliness:

```text
$ git diff --check
diff_check_exit=0
$ git status --short
status_exit=0
```

Both commands produced no output.

## Prior mutation evidence retained

The earlier Task 15 gate at `cfe205ca` temporarily reversed the unchanged sparse-patch comparison
and temporarily accepted uppercase TLS hex. The focused tests failed for the intended assertion,
then passed after exact restoration. Those mutations were never committed. They were not repeated
at the approved final head because this final gate explicitly prohibited production/test changes;
the complete current suites above revalidate the approved implementation.

## Task evidence and deviations

- Task 12 introduced the typed settings contract and PIN redaction. Its focused RED established
  missing settings APIs; GREEN reached 8 focused Network tests. It used the existing
  `ScriptedRouterHTTPClient.ok(...)` fixture, a shared credential test fixture, a local
  async-throws assertion helper, and Swift-required argument-label ordering instead of the plan's
  hypothetical spellings.
- Task 13 introduced UI-local settings values, sparse patches, validation, migration, confirmation,
  and readback-only app publication. It used the existing `makeFixture`/`AdminScriptedHTTP`
  harnesses, and the migration harness is `async throws` because credential storage is async.
  Review fixes added exact listener survival, redirect rejection before credential forwarding,
  and UI-local PIN redaction.
- Task 14 introduced staged TLS rotation and explicit promotion. Review expanded endpoint/device
  compare-and-swap, locked staged verification, and operation exclusion across Lock, Unlock,
  Rotate, and Verify. Ordinary connections remain active-pin-only with no automatic promotion,
  TOFU, downgrade, dual-pin trust, or new authorization path.
- The approved post-verification review waves (`8a36a920`, `a06d1003`, `148afdb4`) increased UI
  from 42 to 45, Network from 174 to 185, and each Xcode bundle from 263 to 276 while closing
  recovery/cancellation races. These are reviewed M3 regressions, not M4/M5 scope.
- Final-gate execution deviation: the first Core wrapper attempted to assign zsh's reserved
  read-only `status` variable after the command. Core was immediately rerun from scratch using
  `rc`, and only the clean rerun is the reported `/tmp/wattline-m3-final-gate-core.log` evidence.
- Simulator deviation: during the Widgets run one parallel clone logged a transient
  `FBSOpenApplicationServiceErrorDomain` launch denial. Xcode recovered within the same invocation;
  the command exited 0 and the authoritative bundle reports 276 passed, zero failed/skipped/
  expected failures. The named simulator itself did not fail, so the approved UDID boot/retry
  fallback was not needed. No simulator was erased.

## External validation still required

Unit and simulator tests cannot prove live-router behavior. Before release, perform:

1. A real settings save followed by `wattlined`/router restart and complete authoritative readback.
2. Listener migration while preserving a reachable, same-device replacement endpoint.
3. TLS rotation across restart: staged-only trial, explicit promotion, ordinary reconnect, and
   rejection of the old leaf DER/pin.
4. Token-store cutover, verifying the confirmation and that managed SSE streams close without
   claiming token migration.

## Evidence paths

```text
/tmp/wattline-m3-final-gate-core.log
/tmp/wattline-m3-final-gate-ui.log
/tmp/wattline-m3-final-gate-network.log
/tmp/wattline-m3-final-gate-ios.log
/tmp/wattline-m3-final-gate-widgets.log
/tmp/wattline-m3-final-gate-build.log
/tmp/wattline-m3-final-gate-ios-xcresult-summary.json
/tmp/wattline-m3-final-gate-widgets-xcresult-summary.json
/tmp/wattline-m3-final-gate-environment.log
/tmp/wattline-m3-final-gate-package-summary.log
/tmp/wattline-m3-final-gate-audits.log
/tmp/wattline-m3-final-gate-post-commit.log
```

## Stop condition

Milestone 3 stops at this evidence commit. No Milestone 4 or Milestone 5 implementation was
started, and this gate was not pushed.
