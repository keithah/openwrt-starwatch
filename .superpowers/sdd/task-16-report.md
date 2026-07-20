# Task 16 Report — Router-to-Link-Power Pairing

## RED

- `swift test --package-path peakdo/apple/WattlineNetwork --filter RouterDevicePairingTests`
  exited 1: `cannot find 'RouterDevicePairingClient' in scope` and
  `cannot find type 'RouterDevicePairingError' in scope`.
- `swift test --package-path peakdo/apple/WattlineUI --filter RouterDevicePairingPresentationTests`
  exited 1: `cannot find 'RouterDevicePairingPresentation' in scope` and
  `cannot find 'RouterPairableDeviceValue' in scope`.
- Complete captured logs: `/tmp/wattline-m4-task16-network-red.log` and
  `/tmp/wattline-m4-task16-ui-red.log`.

## GREEN

- Focused Network: 12/12, zero failures.
- Full WattlineNetwork: 197/197, zero failures.
- Focused UI: 3/3, zero failures.
- Full WattlineUI: 48/48, zero failures.
- Full Wattline iOS scheme on `Wattline-Tests-2`: 279 passing test cases,
  zero failures; `** TEST SUCCEEDED **`.
- Complete logs: `/tmp/wattline-m4-task16-network-green5.log`,
  `/tmp/wattline-m4-task16-network-full.log`,
  `/tmp/wattline-m4-task16-ui-full.log`, and
  `/tmp/wattline-m4-task16-app-full.log`.

## Implementation

- Added the client-token-only pairing DTO/client with exact status, scan,
  pair, and unpair routes/status codes; deterministic redacted pair payload;
  normalized/encoded MACs; ASCII six-digit-or-empty PIN validation; and
  authoritative status polling.
- Polling is bounded by the injected `RouterConnectionClock`. One operation
  owns an opaque operation ID, cancellation cancels a suspended polling task,
  and generation checks quarantine late HTTP/status completions. Existing and
  409-reported daemon operations are adopted without a second mutation.
- Added Foundation-only WattlineUI row/status presentation.
- Added iOS model ownership and lifecycle cancellation, endpoint-replacement
  quarantine, structurally present saved-router entry, secure optional PIN
  field, and PIN clearing before dispatch/on disappear/on background.

## Deviations

- The detailed plan listed eleven Network test names. They were consolidated
  into twelve non-vacuous tests where closely related exact-body cases share a
  test loop; coverage includes all listed behaviors plus cancellation of an
  actually suspended injected-clock sleep and rejection of Unicode digits.
- Pairing is shown in the existing saved-router administration screen rather
  than creating another scan-screen navigation path. The screen itself is the
  existing saved-host-only scan-row destination, so raw discovery rows still
  cannot gain client credentials or pairing controls.

## External checks

- Physical BlueZ discovery, real Link-Power pair/unpair, RF RSSI changes, and
  router asynchronous error timing require a live router and power station.

## Review correction wave

### RED

- `swift test --package-path peakdo/apple/WattlineNetwork --filter RouterDevicePairingTests`
  exited 1 because the production stage enum had no `paired` case and
  `scan(progress:)` did not exist. The new unpair-409, caller-cancellation,
  progressive-status, and 0–6 digit PIN cases therefore could not compile.
- `swift test --package-path peakdo/apple/WattlineUI --filter RouterDevicePairingPresentationTests`
  exited 1 because the pure PIN predicate and structurally absent action
  composition did not exist.
- Captured logs: `/tmp/wattline-m4-task16-fix-network-red.log` and
  `/tmp/wattline-m4-task16-fix-ui-red.log`.

### GREEN

- Focused WattlineNetwork pairing: 18/18, zero failures.
- Full WattlineNetwork: 203/203, zero failures.
- Focused WattlineUI pairing presentation: 5/5, zero failures.
- Full WattlineUI: 50/50, zero failures.
- Focused iOS `RouterAdministrationModelTests`: succeeded, including
  `testDevicePairingPublishesProgressAndQuarantinesLateProgressAfterReplacement`.
- Full Wattline iOS scheme on `Wattline-Tests-2`: 280 passing test cases,
  zero failures; `** TEST SUCCEEDED **`.
- Captured logs: `/tmp/wattline-m4-task16-fix-network-green3.log`,
  `/tmp/wattline-m4-task16-fix-network-full2.log`,
  `/tmp/wattline-m4-task16-fix-ui-green1.log`,
  `/tmp/wattline-m4-task16-fix-ui-full.log`, and
  `/tmp/wattline-m4-task16-fix-app-focused2.log`, and
  `/tmp/wattline-m4-task16-fix-app-full2.log`.

### Corrections

- Aligned status decoding and fixtures to the live daemon's exact
  `idle/scanning/pairing/paired/error` stages.
- Propagated caller cancellation across credential reads, initial GET, POST,
  and polling sleep; the client lifecycle `cancel()` remains independently
  covered.
- Added an authoritative progress callback for scan/pair/unpair polling and
  generation-checked app-model publication, so stale progress cannot cross an
  endpoint replacement.
- Mirrored the router compatibility rule of empty or 1–6 ASCII digits in the
  Network validation and pure UI predicate. Unicode digits and seven digits
  are rejected.
- A DELETE 409 performs exactly one authoritative status reread and never
  retries the DELETE. While any operation is active, scan/pair/remove/select actions
  are structurally absent from the SwiftUI tree rather than disabled.

## Final re-review correction wave

### RED

- Focused Network exited 1: the gated terminal-progress cancellation became
  false success, and a busy unpair stopped at `pairing` instead of polling the
  adopted daemon operation to `paired`.
- Focused UI exited 1 because the pure action policy had no authoritative
  `stage` input and therefore could not structurally represent daemon-owned
  busy state.
- Captured logs:
  `/tmp/wattline-m4-task16-finalfix-network-red.log` and
  `/tmp/wattline-m4-task16-finalfix-ui-red.log`.

### GREEN

- Focused Network pairing: 19/19.
- Full WattlineNetwork: 204/204.
- Focused UI pairing presentation: 6/6.
- Full WattlineUI: 51/51.
- Focused `RouterAdministrationModelTests`: succeeded.
- Full Wattline iOS scheme: 281/281 passed, zero failed/skipped/expected,
  on `Wattline-Tests-2` (iPhone 17e, iOS 26.5, arm64, UDID
  `74C1DA4D-7190-4497-AAD5-9EB140B3A96A`).
- Captured logs and result summary:
  `/tmp/wattline-m4-task16-finalfix-network-full.log`,
  `/tmp/wattline-m4-task16-finalfix-ui-full.log`,
  `/tmp/wattline-m4-task16-finalfix-app-full.log`, and
  `/tmp/wattline-m4-task16-finalfix-app-summary.json`.

### Corrections

- Progress publication now checks caller cancellation and the client
  generation immediately before and after every async callback, preventing a
  suspended callback from turning cancellation into late progress or success.
- The app publisher also refuses publication from a cancelled task.
- UI composition derives structural busy state from both the local operation
  and authoritative `scanning`/`pairing` status; Select uses the same pure
  composition as Scan/Pair/Remove.
- A 409 unpair adopts and polls the daemon-owned operation to a terminal status
  without retrying DELETE.
