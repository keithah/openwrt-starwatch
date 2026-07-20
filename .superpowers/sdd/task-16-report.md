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
