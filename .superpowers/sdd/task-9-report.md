# Task 9 report — Low-battery policy

Commit: `47d75c12`

Implemented a pure `LowBatteryPolicy` state machine in WattlineCore. It defaults to a 20% threshold and 3-point hysteresis, gates on preference and battery capability, emits one alert for a downward discharge edge, and suppresses repeated low samples until recovery to 23%. The first eligible discharging sample already at or below 20% emits once because a crossing may have happened while disconnected or disabled. Charging and idle samples never emit; recovery samples may re-arm the policy.

Tests:

- `swift test --package-path peakdo/apple/WattlineCore --filter LowBatteryPolicyTests`: 3/3 passed.
- Mutation check (`level <= threshold` changed to `<`) failed 4 assertions, then the production comparison was restored.
- Full Core run reached 151 tests; the only failure was a concurrent Task 8 `SnapshotPolicyTests` expectation, unrelated to this task. All LowBatteryPolicy tests and the remaining Core tests passed.

No platform notification framework, clock, networking, or forbidden UI imports were added.
