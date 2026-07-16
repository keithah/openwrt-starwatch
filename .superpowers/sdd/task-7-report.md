# Task 7 — Versioned snapshot model and store

Date: 2026-07-15  
Base: `70e139f2`

Implemented `SharedDeviceSnapshot`, schema-versioned `SharedSnapshotEnvelope` (version 1), Codable battery/port snapshots, and `SharedSnapshotStore` actor over an injected synchronous `SnapshotKeyValueStore`. Floating point values use explicit string tokens (`nan`, `infinity`, `-infinity`) so special values round-trip without fabricating zero. Reads reject absent, corrupt, and unknown-schema bytes; writes encode once then perform one backend replacement; clear removes the single key.

Verification:

- Focused `swift test --filter SharedSnapshotStoreTests --scratch-path /tmp/wattline-task7-green2`: build passed; initial assertion was corrected for IEEE NaN comparison.
- Full `swift test --scratch-path /tmp/wattline-task7-full`: **145/145 passed**.
- Snapshot sources contain no UIKit/SwiftUI/WidgetKit/ActivityKit/UserDefaults/network imports.

Commit: `feat: add shared device snapshots`
