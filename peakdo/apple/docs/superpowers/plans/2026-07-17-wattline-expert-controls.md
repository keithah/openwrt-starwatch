# Wattline Expert BLE Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add safe, protocol-accurate BLE PIN setting and factory-mode controls to iOS/macOS Settings, structurally available only on connected application-mode Bluetooth routes.

**Architecture:** Add the missing BLE PIN DeviceCommand and typed insufficient-encryption mapping in WattlineCore, then expose Expert operations through the existing app-owned broker. Pure WattlineUI composition decides structural availability; platform Settings views provide the disclosure, warning, validation, confirmation, and OS-pairing recovery copy.

**Tech Stack:** Swift 6, CoreBluetooth, WattlineCore command codec, DeviceOperationBroker, SwiftUI, XCTest.

## Global Constraints

- Inherit every constraint from `2026-07-17-wattline-completion.md`.
- Milestones 1–4 must be green before this plan starts.
- Expert is absent for Router, Demo, OTA mode, disconnected state, and unsupported factory capability.
- BLE PIN accepts two matching decimal values from 0 through 999999, writes u32 little-endian, and is never read, deleted, logged, persisted, or redisplayed.
- Factory mode sends `[0xE0, 0x01, mode]` and validates `[0xE0, 0x81, 0x00]`; it is never fire-and-forget.
- Insufficient encryption presents OS pairing guidance; Wattline never captures the current pairing PIN.
- Do not add OTA, firmware, threshold/barrier-free, register access, or undocumented Expert commands.

---

### Task 1: Add BLE PIN command bytes and typed encryption failure

**Files:**
- Modify: `peakdo/apple/WattlineCore/Sources/WattlineCore/Device/DeviceController.swift`
- Modify: `peakdo/apple/WattlineCore/Sources/WattlineCore/BLE/BluetoothDelegateBridge.swift`
- Modify: `peakdo/apple/WattlineCore/Tests/WattlineCoreTests/CommandCodecTests.swift`
- Modify: `peakdo/apple/WattlineCore/Tests/WattlineCoreTests/BluetoothDelegateBridgeTests.swift`
- Modify: `peakdo/apple/WattlineCore/Tests/WattlineCoreTests/QuirkRegressionTests.swift`

**Interfaces:**
- Produces: `DeviceCommand.setBLEPIN(_:)` and `BLETransportError.insufficientEncryption`.
- Consumes: existing `Command.blePIN`, Action.set, CommandReply validation, and bridge IO continuation path.

- [ ] **Step 1: Write failing exact-vector tests**

```swift
func testBLEPINUsesU32LittleEndianAndValidatesReply() throws {
    let command = DeviceCommand.setBLEPIN(999_999)
    XCTAssertEqual(command.request.bytes, Data([0x04, 0x01, 0x3F, 0x42, 0x0F, 0x00]))
    XCTAssertNoThrow(try command.validate(Data([0x04, 0x81, 0x00])))
    XCTAssertThrowsError(try command.validate(Data([0x04, 0x81, 0xFC])))
}

func testInsufficientEncryptionIsMappedWithoutStringParsing() {
    let error = NSError(domain: CBATTErrorDomain, code: CBATTError.insufficientEncryption.rawValue)
    XCTAssertEqual(BluetoothDelegateBridge.normalizedIOError(error) as? BLETransportError, .insufficientEncryption)
}
```

Keep the existing running-mode reply test and add a mutation-to-RED assertion that `.runningMode(.factory).expectsRead == true`.

- [ ] **Step 2: Run Core focused tests and verify RED**

```bash
swift test --package-path peakdo/apple/WattlineCore --filter CommandCodecTests
swift test --package-path peakdo/apple/WattlineCore --filter BluetoothDelegateBridgeTests
swift test --package-path peakdo/apple/WattlineCore --filter QuirkRegressionTests
```

Expected: missing command factory/error case/normalizer.

- [ ] **Step 3: Implement exact command construction**

```swift
public extension DeviceCommand {
    static func setBLEPIN(_ pin: UInt32) -> DeviceCommand {
        let payload: [UInt8] = [
            UInt8(truncatingIfNeeded: pin),
            UInt8(truncatingIfNeeded: pin >> 8),
            UInt8(truncatingIfNeeded: pin >> 16),
            UInt8(truncatingIfNeeded: pin >> 24),
        ]
        return DeviceCommand(
            request: DeviceRequest(
                CommandRequest(command: .blePIN, action: .set, payload: payload)
            )
        )
    }
}
```

Range validation remains in the UI/service; the Core factory accepts UInt32 and encodes it exactly.

- [ ] **Step 4: Normalize the CoreBluetooth error at the IO boundary**

Add `.insufficientEncryption` to BLETransportError. `normalizedIOError(_:)` compares NSError domain/code to `CBATTErrorDomain` and `CBATTError.insufficientEncryption.rawValue`; `resume(_:throwing:)` passes the normalized error to command/write continuations. Other errors preserve identity/description.

- [ ] **Step 5: Run full WattlineCore GREEN**

```bash
swift test --package-path peakdo/apple/WattlineCore
```

Expected: all exact command/quirk/bridge tests pass.

- [ ] **Step 6: Commit**

```bash
git add peakdo/apple/WattlineCore
git commit -m "feat: add Expert BLE commands"
```

### Task 2: Add broker-routed Expert operation service

**Files:**
- Create: `peakdo/apple/WattlineAppShared/Expert/ExpertOperationService.swift`
- Modify: `peakdo/apple/Wattline/Wattline/AppModel.swift`
- Modify: `peakdo/apple/WattlineMac/MacAppModel.swift`
- Create: `peakdo/apple/Wattline/WattlineTests/ExpertOperationTests.swift`
- Create: `peakdo/apple/WattlineMacTests/MacExpertOperationTests.swift`

**Interfaces:**
- Produces: `ExpertOperationService.setPIN`, `setRunningMode`, `ExpertOperationError`, and thin model actions.
- Consumes: exact DeviceCommand factories, app-owned DeviceOperationBroker, active route/mode/capabilities.

- [ ] **Step 1: Write failing validation, routing, and reply tests**

```swift
XCTAssertEqual(service.validatePIN(first: "000123", confirmation: "000123"), .success(123))
XCTAssertEqual(service.validatePIN(first: "1000000", confirmation: "1000000"), .failure(.outOfRange))
XCTAssertEqual(service.validatePIN(first: "123", confirmation: "124"), .failure(.mismatch))
```

Assert invalid input writes zero commands; Router/Demo/disconnected/OTA routes return `.unavailableForRoute`; insufficient encryption maps to `.pairingRequired`; PIN success requires valid command reply; factory success requires a valid reply; rejected/malformed reply is failure. Assert no UserDefaults, catalog JSON, Keychain host metadata, or log recorder contains entered PIN text.

- [ ] **Step 2: Run iOS/macOS focused tests and verify RED**

```bash
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme Wattline \
  -destination "platform=iOS Simulator,id=$WATTLINE_SIMULATOR_ID" CODE_SIGNING_ALLOWED=NO \
  -only-testing:WattlineTests/ExpertOperationTests
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineMac \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:WattlineMacTests/MacExpertOperationTests
```

Expected: missing service/model actions.

- [ ] **Step 3: Implement pure validation and broker operations**

```swift
enum ExpertOperationError: Error, Equatable, Sendable {
    case mismatch
    case nonDecimal
    case outOfRange
    case unavailableForRoute
    case unsupported
    case pairingRequired
    case rejected
}

struct ExpertOperationService: Sendable {
    init(broker: DeviceOperationBroker)
    func validatePIN(first: String, confirmation: String) -> Result<UInt32, ExpertOperationError>
    func setPIN(_ pin: UInt32, generation: UInt) async throws
    func setRunningMode(_ mode: RunningMode, generation: UInt) async throws
}
```

Validation uses `Character.isNumber` only for ASCII `0...9`, preserves leading-zero acceptance, and bounds the parsed value. Both operations call the existing broker `perform`; they require `.reply` and successful command validation. Map only typed `BLETransportError.insufficientEncryption` to `.pairingRequired`; never search localized strings.

- [ ] **Step 4: Add thin AppModel and MacAppModel methods**

Both models derive availability from active route, connection, DeviceMode, and capabilities, then call the service with the current generation. They expose a non-secret success/error presentation state and clear it when the Expert sheet closes or generation changes. No model property stores the PIN.

- [ ] **Step 5: Run Expert, broker, settings, and Core tests GREEN**

Run Step 2 plus DeviceOperationBrokerTests, SettingsOperationTests, and full Core.

- [ ] **Step 6: Commit**

```bash
git add peakdo/apple/WattlineAppShared/Expert peakdo/apple/Wattline/Wattline/AppModel.swift \
  peakdo/apple/WattlineMac/MacAppModel.swift peakdo/apple/Wattline/WattlineTests/ExpertOperationTests.swift \
  peakdo/apple/WattlineMacTests/MacExpertOperationTests.swift
git commit -m "feat: route Expert operations through device owner"
```

### Task 3: Add structurally gated Expert Settings UI

**Files:**
- Modify: `peakdo/apple/WattlineUI/Sources/WattlineUI/SettingsSections.swift`
- Create: `peakdo/apple/WattlineUI/Sources/WattlineUI/ExpertPresentation.swift`
- Create: `peakdo/apple/WattlineUI/Tests/WattlineUITests/ExpertPresentationTests.swift`
- Create: `peakdo/apple/Wattline/Wattline/Settings/ExpertSettingsView.swift`
- Modify: `peakdo/apple/Wattline/Wattline/Settings/SettingsView.swift`
- Create: `peakdo/apple/WattlineMac/MacExpertSettingsView.swift`
- Modify: `peakdo/apple/WattlineMac/MacSettingsView.swift`
- Create: `peakdo/apple/Wattline/WattlineUITests/WattlineExpertUITests.swift`
- Create: `peakdo/apple/WattlineMacTests/MacExpertCompositionTests.swift`

**Interfaces:**
- Produces: `ExpertAvailability`, `ExpertRow`, `ExpertPresentation`, and iOS/macOS Expert disclosures.
- Consumes: Task 2 model actions and authoritative route/mode/capabilities.

- [ ] **Step 1: Write failing structural and safety-copy tests**

```swift
XCTAssertEqual(
    ExpertPresentation(availability: .bluetoothApplication(canFactoryMode: true)).rows,
    [.blePIN, .factoryMode]
)
XCTAssertEqual(ExpertPresentation(availability: .router).rows, [])
XCTAssertEqual(ExpertPresentation(availability: .demo).rows, [])
XCTAssertEqual(
    ExpertPresentation(availability: .bluetoothApplication(canFactoryMode: false)).rows,
    [.blePIN]
)
```

Assert copy includes “cannot be read back or deleted,” “not stored,” “physical reset,” and OS pairing guidance. UI tests assert Expert is absent from Router/Demo view trees, not merely disabled.

- [ ] **Step 2: Run UI/macOS focused tests and verify RED**

```bash
swift test --package-path peakdo/apple/WattlineUI --filter ExpertPresentationTests
xcodebuild test -project peakdo/apple/Wattline/Wattline.xcodeproj -scheme WattlineMac \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:WattlineMacTests/MacExpertCompositionTests
```

Expected: missing Expert presentation and settings views.

- [ ] **Step 3: Implement pure structural composition**

```swift
public enum ExpertAvailability: Equatable, Sendable {
    case unavailable
    case router
    case demo
    case bluetoothApplication(canFactoryMode: Bool)
}

public enum ExpertRow: Equatable, Sendable { case blePIN, factoryMode }

public struct ExpertPresentation: Equatable, Sendable {
    public let rows: [ExpertRow]
    public init(availability: ExpertAvailability)
}
```

Append `.expert` to SettingsComposition only when `rows` is nonempty. Do not use `.disabled`, opacity, or hidden modifiers to gate the disclosure.

- [ ] **Step 4: Implement the interstitial and forms**

The first entry shows an “I understand” interstitial. PIN uses two SecureFields with decimal keyboard on iOS, never binds the value into AppModel, clears both strings on submit/dismiss/background, and shows destructive confirmation. Factory mode shows a separate confirmation and sends `.factory` only after confirmation. Success text reports confirmed command outcome; pairingRequired opens the explanatory retry path.

- [ ] **Step 5: Run all UI, iOS, and macOS tests GREEN**

Run Step 2, full WattlineUI, full iOS app scheme, full macOS scheme, and UI tests on the installed simulator.

- [ ] **Step 6: Commit**

```bash
git add peakdo/apple/WattlineUI peakdo/apple/Wattline/Wattline/Settings \
  peakdo/apple/WattlineMac peakdo/apple/Wattline/WattlineUITests/WattlineExpertUITests.swift
git commit -m "feat: add Wattline Expert settings"
```

### Task 4: Expert verification and handoff

**Files:**
- Modify: `peakdo/apple/docs/superpowers/plans/2026-07-17-wattline-expert-controls.md` only to record evidence.

**Interfaces:**
- Produces: reviewed F18 implementation for final release verification.

- [ ] **Step 1: Run all deterministic suites/builds**

Run every package, iOS app/UI/widget, and macOS app/widget test plus generic platform builds. Record exact counts.

- [ ] **Step 2: Audit protocol bytes, route gating, and secrets**

```bash
rg -n 'blePIN|setBLEPIN|runningMode' peakdo/apple/WattlineCore peakdo/apple/WattlineAppShared peakdo/apple/Wattline peakdo/apple/WattlineMac
rg -n 'pin|PIN' peakdo/apple/Wattline/Wattline/AppPersistence.swift peakdo/apple/WattlineAppShared/Devices \
  peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterHostStore.swift
rg -n 'ExpertSettingsView|MacExpertSettingsView' peakdo/apple/Wattline/Wattline/RouterConnectionModel.swift \
  peakdo/apple/WattlineCore/Sources/WattlineCore/Transport/DemoTransport.swift
git diff --check
```

Manually inspect matches to confirm no entered PIN persistence/logging, exact `[04 01 pin32LE]` and `[E0 01 mode]` tests, and structural absence on Router/Demo.

- [ ] **Step 3: Exercise safe Demo/route UI only**

Use Demo and a fake Router route to prove Expert never appears. Do not send Expert commands to real hardware without the owner's recoverable-device approval.

- [ ] **Step 4: Commit evidence and stop**

```bash
git add peakdo/apple/docs/superpowers/plans/2026-07-17-wattline-expert-controls.md
git commit -m "test: verify Wattline Expert controls"
```

Report exact counts and classify encrypted-bond behavior, OS pairing recovery, PIN setting, physical reset recovery, and factory mode on sacrificial/recoverable hardware as external. Stop for Milestone 6 approval.
