# Task 7 review corrections

Expanded the snapshot-store regression tests so they exercise every persisted field, optional DC/Type-C fields, exact dates, and NaN/+Inf/-Inf power values. The unknown-schema test now starts from a valid encoded snapshot and mutates only `schemaVersion` to 99. The clear test writes and reads a snapshot before clearing, then verifies the key is absent.

Verification:

- `swift test --filter SharedSnapshotStoreTests --scratch-path /tmp/wattline-task7-fix`: 3/3 passed.
- `swift test --scratch-path /tmp/wattline-task7-fix-full`: 145/145 passed.
