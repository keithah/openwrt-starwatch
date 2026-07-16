# Task 17 report — System surface preferences

Implemented independent Live Activity charging/discharging toggles and low-battery preference/threshold persistence.
`SystemSurfacePreferences` is Codable/Equatable/Sendable with defaults charging/discharging enabled, low-battery disabled, threshold 20 (clamped 1…99). `AppPersistence` stores the encoded value and maintains legacy low-battery keys. Settings adds a battery-capability-gated System Surfaces section; absent battery capability means the section is structurally absent. AppModel restores an already-enabled low-battery preference on launch through the existing notification coordinator's silent restore path and updates its threshold without creating a BLE owner.

Verification:
- WattlineUI `swift test`: 18/18 passed.
- WattlineCore `swift test`: 154/154 passed.
- Generic iOS `xcodebuild ... build-for-testing CODE_SIGNING_ALLOWED=NO`: **TEST BUILD SUCCEEDED**.
- No contract/OEM files, macOS targets, networking, timers, or forbidden WattlineCore imports changed.

Simulator notification authorization and background launch behavior remain environment checks.
