# Task 13 report — Live Activity lifecycle policy

Implemented `WattlineCore/SystemSurfaces/LiveActivityPolicy.swift` with pure wall-clock `Date` lifecycle decisions and focused tests.

## TDD evidence

Red first:

```text
swift test --package-path peakdo/apple/WattlineCore --filter LiveActivityPolicyTests
error: cannot find 'LiveActivityPolicy' in scope
```

Green focused:

```text
swift test --package-path peakdo/apple/WattlineCore --filter LiveActivityPolicyTests
Executed 3 tests, with 0 failures
```

Green full Core suite:

```text
swift test --package-path peakdo/apple/WattlineCore
Executed 154 tests, with 0 failures
```

## Behavior covered

- Charging/discharging preference gates (both default enabled).
- Start only for connected charging/discharging battery snapshots.
- Material fresh updates.
- Idle end at exactly 5:00, not at 4:59.
- Disconnect end at exactly 15:00, not at 14:59.
- Renewal at the near-eight-hour boundary only on a significant fresh update.
- Short disconnect/idle periods hold the active state without ending.

Core remains free of UI/system-surface imports, networking, and monotonic clock dependencies.

## Concerns

ActivityKit integration, authorization behavior, and end-to-end simulator/device lifecycle remain for later tasks and require Xcode/runtime or hardware validation.
