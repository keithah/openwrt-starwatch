# Router Administration M4 Task 17 Report

## RED → GREEN

- Initial focused RED: `/tmp/wattline-m4-task17-red.log` failed because the
  advanced DTO/client APIs did not exist.
- PIN redaction RED: `/tmp/wattline-m4-task17-pin-red.log` failed four
  assertions because a daemon error could reflect `020555`.
- Focused GREEN: 13/13 in
  `/tmp/wattline-m4-task17-green-focused.log`.
- Existing transport clock regression: 1/1 in
  `/tmp/wattline-m4-task17-green-clock.log`.
- Full WattlineNetwork GREEN: 217/217 in
  `/tmp/wattline-m4-task17-green-full.log`.
- Queued stale-operation regression passed 20/20 stress iterations.

## Review correction

- RED `/tmp/wattline-m4-task17-mode-red.log`: mode `2` dispatched a third PUT
  and failed with the wrong error, proving the missing daemon boundary.
- GREEN `/tmp/wattline-m4-task17-mode-green2.log`: modes `0` and `1` use exact
  bodies; mode `2` returns locally without HTTP; 13/13 focused passed.
- Full GREEN `/tmp/wattline-m4-task17-mode-full.log`: 217/217 passed.

## Implementation

- Added canonical administrator APIs for identity, bypass threshold, device
  clock/sync, running mode, barrier-free, USB firmware, and BLE PIN.
- Every operation captures an attachment before the existing privileged FIFO,
  revalidates before dispatch and publication, and uses the administrator
  credential boundary.
- Bypass/barrier return decoded observed responses. Running mode accepts only
  the daemon's supported unsigned values `0` and `1`.
- BLE PIN is exactly six ASCII digits; request/error/result reflection is
  redacted and response must be exactly `{ "updated": true }`.
- `RouterConnection` now shares the clock wire DTO while preserving its
  established ISO-8601-to-`Date?` conversion and `available:false` behavior.

## Deviations and external checks

- The stale master-plan test filter named `RouterCommandTests`; the actual
  suite is `RouterCommandExecutionTests`.
- PIN error redaction and strict no-extra-key response validation were added as
  security hardening.
- Real threshold/barrier readback, clock drift/sync, running-mode behavior,
  USB firmware bytes, and BLE-PIN hardware effects require a live router and
  Link-Power.
