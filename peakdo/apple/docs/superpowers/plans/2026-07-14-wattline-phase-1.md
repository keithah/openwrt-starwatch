# Wattline Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and simulator-verify the iOS 17+ Wattline MVP implementing F1–F8 against the exact BLE protocol contract.

**Architecture:** `WattlineCore` is a local Swift package containing pure protocol codecs, device state, capability resolution, a serialized CoreBluetooth transport, and deterministic demo/replay transports. `WattlineUI` is a local SwiftUI component package, while the `Wattline` Xcode app target owns lifecycle, navigation, persistence, and view composition.

**Tech Stack:** Swift 6, Swift Package Manager, Swift Concurrency, CoreBluetooth, SwiftUI, XCTest, Xcode 26.6, iOS 17 deployment target.

## Global Constraints

- Build only F1–F8; Timers, Shortcuts, and Settings remain placeholders except “Connect a real device.”
- Do not implement OTA, timer CRUD, widgets, Live Activities, App Intents, networking, or macOS targets.
- `WattlineCore` imports neither UIKit nor SwiftUI.
- Command `0x4302` transactions are write-with-response then read, with one in flight per device.
- All protocol values and UUIDs come from `API.md`; no guessed wire shapes.
- Every quirk in spec §5.7 has a dedicated regression test.
- Unsupported capability UI is absent from the SwiftUI view tree, not disabled.
- Demo Mode requires no Bluetooth permission and remains deterministic.
- Production source changes follow red-green-refactor; run the named failing test before adding implementation.

## File Map

```text
WattlineCore/
├── Package.swift
├── Sources/WattlineCore/
│   ├── BLE/BLETransport.swift
│   ├── BLE/BluetoothDelegateBridge.swift
│   ├── BLE/GATTUUID.swift
│   ├── Codec/Binary.swift
│   ├── Codec/CommandCodec.swift
│   ├── Codec/SFloat.swift
│   ├── Codec/TelemetryCodec.swift
│   ├── Device/Capabilities.swift
│   ├── Device/DeviceController.swift
│   ├── Device/DeviceModels.swift
│   ├── Device/DeviceSession.swift
│   ├── Device/DiscoveryPolicy.swift
│   ├── Device/MutationReconciler.swift
│   └── Transport/{DeviceTransport,DemoTransport,ReplayTransport,SerializedTransactions}.swift
└── Tests/WattlineCoreTests/*.swift
WattlineUI/
├── Package.swift
├── Sources/WattlineUI/{BatteryHero,DCPortHero,DemoBadge,LimitSlider,PortCard,StatTile,Theme}.swift
└── Tests/WattlineUITests/CapabilityCompositionTests.swift
Wattline/
├── Wattline.xcodeproj/project.pbxproj
└── Wattline/{Info.plist,Wattline.entitlements,WattlineApp,AppModel,RootView,OnboardingView,ScanView,DashboardView,LimitsView,PlaceholderView,ToastView}.swift
```

---

### Task 1: Core Package and Exact Binary Codecs

**Files:**
- Create: `WattlineCore/Package.swift`
- Create: `WattlineCore/Sources/WattlineCore/Codec/Binary.swift`
- Create: `WattlineCore/Sources/WattlineCore/Codec/SFloat.swift`
- Create: `WattlineCore/Sources/WattlineCore/Codec/CommandCodec.swift`
- Create: `WattlineCore/Sources/WattlineCore/Device/DeviceModels.swift`
- Test: `WattlineCore/Tests/WattlineCoreTests/SFloatTests.swift`
- Test: `WattlineCore/Tests/WattlineCoreTests/CommandCodecTests.swift`

**Interfaces:**
- Produces: `SFloat.decode(_:) -> FloatingPointValue`, `CommandRequest.bytes`, `CommandReply.decode(_:for:resultPolicy:)`, `DeviceID.macAddress`.
- Consumes: exact vectors in `API.md` §§3 and 6.

- [ ] **Step 1: Create the package manifest and failing codec tests**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WattlineCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "WattlineCore", targets: ["WattlineCore"])],
    targets: [
        .target(name: "WattlineCore"),
        .testTarget(name: "WattlineCoreTests", dependencies: ["WattlineCore"]),
    ]
)
```

```swift
@testable import WattlineCore
import XCTest

final class SFloatTests: XCTestCase {
    func testLiveThresholdVectorDecodesTwentyVolts() throws {
        let value = try XCTUnwrap(try SFloat.decode(Data([0xD0, 0xE7])).finiteValue)
        XCTAssertEqual(value, 20.0, accuracy: 0.0001)
    }

    func testSpecialValues() throws {
        XCTAssertEqual(try SFloat.decode(Data([0xFF, 0x07])), .nan)
        XCTAssertEqual(try SFloat.decode(Data([0xFE, 0x07])), .positiveInfinity)
        XCTAssertEqual(try SFloat.decode(Data([0x02, 0x08])), .negativeInfinity)
    }
}

final class CommandCodecTests: XCTestCase {
    func testFeaturesLiveReply() throws {
        let request = CommandRequest(command: .features, action: .get)
        let reply = try CommandReply.decode(Data([0xFE, 0x80, 0x00, 0xFF, 0x7F, 0x00, 0x00]), for: request)
        XCTAssertEqual(try reply.uint32Payload(), 0x0000_7FFF)
    }

    func testDeviceIDReversesMACBytes() throws {
        XCTAssertEqual(try DeviceID(reply: Data([0x10, 0x80, 0x00, 0x2B, 0x72, 0xEB, 0x5A, 0x04, 0xDC])).macAddress,
                       "DC:04:5A:EB:72:2B")
    }

    func testMismatchedEchoesFail() {
        let request = CommandRequest(command: .dcControl, action: .set, payload: [1])
        XCTAssertThrowsError(try CommandReply.decode(Data([0x02, 0x81, 0x00]), for: request))
        XCTAssertThrowsError(try CommandReply.decode(Data([0x01, 0x80, 0x00]), for: request))
    }
}
```

- [ ] **Step 2: Verify RED**

Run: `swift test --package-path WattlineCore --filter 'SFloatTests|CommandCodecTests'`
Expected: compilation fails because `SFloat`, `CommandRequest`, `CommandReply`, and `DeviceID` do not exist.

- [ ] **Step 3: Implement the minimal binary and command APIs**

```swift
public enum FloatingPointValue: Equatable, Sendable {
    case finite(Double), nan, positiveInfinity, negativeInfinity
    public var finiteValue: Double? { if case let .finite(value) = self { value } else { nil } }
}

public enum SFloat {
    public static func decode(_ data: Data) throws -> FloatingPointValue {
        guard data.count >= 2 else { throw CodecError.truncated }
        let raw = UInt16(data[0]) | UInt16(data[1]) << 8
        switch raw {
        case 0x07FF: return .nan
        case 0x07FE: return .positiveInfinity
        case 0x0802: return .negativeInfinity
        default:
            let mantissa = Int16(bitPattern: (raw & 0x0800) == 0 ? raw & 0x0FFF : raw | 0xF000)
            let exponentBits = Int8(raw >> 12)
            let exponent = exponentBits < 8 ? exponentBits : exponentBits - 16
            return .finite(Double(mantissa) * pow(10, Double(exponent)))
        }
    }
}

public struct CommandRequest: Equatable, Sendable {
    public let command: Command
    public let action: Action
    public let payload: [UInt8]
    public var bytes: Data { Data([command.rawValue, action.rawValue] + payload) }
}
```

Implement bounds-checked little-endian readers in `Binary.swift`, reply echo validation, result policies `.standard`, `.runtimeUnset`, and `.ignoreForBypass`, plus the reversed MAC formatter.

- [ ] **Step 4: Verify GREEN and refactor**

Run: `swift test --package-path WattlineCore --filter 'SFloatTests|CommandCodecTests'`
Expected: all selected tests pass with zero failures.

- [ ] **Step 5: Commit the codec slice**

```bash
git add WattlineCore
git commit -m "feat: add Wattline BLE frame codecs"
```

### Task 2: Length-Tolerant Telemetry Models

**Files:**
- Create: `WattlineCore/Sources/WattlineCore/Codec/TelemetryCodec.swift`
- Test: `WattlineCore/Tests/WattlineCoreTests/TelemetryCodecTests.swift`

**Interfaces:**
- Consumes: `SFloat.decode`, bounds-checked binary readers.
- Produces: `BatteryStatus`, `DCPortStatus`, and `TypeCPortStatus` initializers from `Data`.

- [ ] **Step 1: Add failing live-layout and trailing-byte tests**

```swift
func testElevenByteDCFrameParsesKnownPrefixAndIgnoresTrailer() throws {
    let frame = Data([1, 0, 0xC4, 0xF0, 0x13, 0xD0, 0x36, 0xC0, 1, 0, 0x7F])
    let value = try DCPortStatus(frame: frame)
    XCTAssertTrue(value.enabled)
    XCTAssertEqual(value.bypassOn, true)
    XCTAssertEqual(value.voltage, 19.6, accuracy: 0.001)
}

func testThirteenByteTypeCFrameUsesGapThenModeAndDCInput() throws {
    let frame = Data([1, 0, 0xB0, 0xE4, 0, 0, 0, 0, 0xFA, 0xF0, 0, 3, 0])
    let value = try TypeCPortStatus(frame: frame)
    XCTAssertEqual(value.temperature, 25.0, accuracy: 0.001)
    XCTAssertEqual(value.mode, .inputAndOutput)
    XCTAssertFalse(value.isDCInput)
}

func testOptionalFieldsAreNilOnLegacyPrefixes() throws {
    XCTAssertNil(try DCPortStatus(frame: Data(repeating: 0, count: 8)).bypassOn)
    XCTAssertNil(try TypeCPortStatus(frame: Data(repeating: 0, count: 10)).mode)
}
```

- [ ] **Step 2: Verify RED**

Run: `swift test --package-path WattlineCore --filter TelemetryCodecTests`
Expected: compilation fails because telemetry model initializers do not exist.

- [ ] **Step 3: Implement documented-offset parsers**

```swift
public init(frame: Data) throws {
    guard frame.count >= 8 else { throw CodecError.truncated }
    enabled = frame[0] != 0
    status = PowerFlow(rawValue: Int8(bitPattern: frame[1])) ?? .idle
    voltage = try frame.sfloat(at: 2)
    current = try frame.sfloat(at: 4)
    power = try frame.sfloat(at: 6)
    bypassOn = frame.count >= 9 ? frame[8] != 0 : nil
}
```

Implement battery's exact 16-byte layout and Type-C's 10-byte prefix with optional byte 11 mode and byte 12 DC-input fields. Never assert an exact maximum frame length.

- [ ] **Step 4: Verify GREEN**

Run: `swift test --package-path WattlineCore --filter TelemetryCodecTests`
Expected: all telemetry tests pass.

- [ ] **Step 5: Commit**

```bash
git add WattlineCore
git commit -m "feat: decode Wattline telemetry frames"
```

### Task 3: Command Builders and Quirk Policies

**Files:**
- Create: `WattlineCore/Sources/WattlineCore/Device/MutationReconciler.swift`
- Create: `WattlineCore/Sources/WattlineCore/Device/DeviceController.swift`
- Test: `WattlineCore/Tests/WattlineCoreTests/QuirkRegressionTests.swift`

**Interfaces:**
- Consumes: command codec and telemetry models.
- Produces: `DeviceCommand` factories, `ExpectedDisconnectPolicy`, `MutationReconciler` confirmation predicates.

- [ ] **Step 1: Add one failing test per §5.7 quirk**

```swift
func testPowerLimitClearNeverUsesTimerOpcode() {
    XCTAssertEqual(DeviceCommand.clearPowerLimit(.input).request.bytes, Data([0x02, 0x02, 0x02]))
    XCTAssertEqual(DeviceCommand.clearPowerLimit(.input).followUp, .getPowerLimit(.input))
}

func testTypeCReconcilesUsingModeNotEnabled() {
    let stillEnabledButOutputOff = TypeCPortStatus(enabled: true, mode: .input)
    XCTAssertTrue(MutationReconciler.typeCOutput(false).matches(.typeC(stillEnabledButOutputOff)))
    XCTAssertFalse(MutationReconciler.typeCOutput(true).matches(.typeC(stillEnabledButOutputOff)))
}

func testBypassIgnoresResultAndWaitsForTelemetry() throws {
    let command = DeviceCommand.setBypass(true)
    XCTAssertNoThrow(try command.validate(Data([0x14, 0x81, 0xFD])))
    XCTAssertFalse(command.reconciler.matches(.dc(.init(enabled: true, bypassOn: false))))
    XCTAssertTrue(command.reconciler.matches(.dc(.init(enabled: true, bypassOn: true))))
}

func testDisconnectAsSuccessPolicies() {
    XCTAssertEqual(DeviceCommand.restart.disconnectPolicy, .successThenReconnect)
    XCTAssertEqual(DeviceCommand.enterOTA.disconnectPolicy, .successThenAwaitOTAMode)
    XCTAssertEqual(DeviceCommand.shutdown.disconnectPolicy, .successThenDisarmReconnect)
}

func testRunningModeRequiresReply() {
    XCTAssertTrue(DeviceCommand.runningMode(.user).expectsRead)
    XCTAssertNoThrow(try DeviceCommand.runningMode(.user).validate(Data([0xE0, 0x81, 0x00])))
}

func testOnlyRuntimeAcceptsUnsetResult() {
    XCTAssertNoThrow(try DeviceCommand.getPowerLimit(.runtime).validate(Data([0x02, 0x80, 0xFF])))
    XCTAssertThrowsError(try DeviceCommand.getPowerLimit(.global).validate(Data([0x02, 0x80, 0xFF])))
}
```

Add the stale-name and macOS OTA classification tests in Tasks 5 and 6, keeping each §5.7 item in its own named test.

- [ ] **Step 2: Verify RED**

Run: `swift test --package-path WattlineCore --filter QuirkRegressionTests`
Expected: compilation fails because command factories and reconciliation policies do not exist.

- [ ] **Step 3: Implement exact commands and policies**

```swift
public static func setTypeCOutput(_ on: Bool) -> DeviceCommand {
    .init(request: .init(command: .typeCControl, action: .set, payload: [0x02, on ? 1 : 0]),
          reconciler: .typeCOutput(on), timeout: .seconds(3))
}

public static func clearPowerLimit(_ type: PowerLimitType) -> DeviceCommand {
    .init(request: .init(command: .typeCPowerLimit, action: .delete, payload: [type.rawValue]),
          followUp: .getPowerLimit(type))
}
```

Encode `[01,01,op]`, `[13,01,02,op]`, `[02,00,type]`, `[02,01,type,level]`, `[02,02,type]`, `[14,01,op]`, `[11,01]`, PK, FM, and `[E0,01,mode]` exactly. Keep the spec §5.7/API §3.4 comment only beside bypass result handling, power-limit clear, Type-C mode reconciliation, and expected disconnect handling.

- [ ] **Step 4: Verify GREEN**

Run: `swift test --package-path WattlineCore --filter QuirkRegressionTests`
Expected: all quirk command tests pass.

- [ ] **Step 5: Commit**

```bash
git add WattlineCore
git commit -m "feat: encode controls and firmware quirk policies"
```

### Task 4: Capability Resolution

**Files:**
- Create: `WattlineCore/Sources/WattlineCore/Device/Capabilities.swift`
- Test: `WattlineCore/Tests/WattlineCoreTests/CapabilityResolverTests.swift`

**Interfaces:**
- Produces: `FeatureFlags: OptionSet`, `DeviceCapabilities`, `CapabilityResolver.resolve(features:cid:model:)`.

- [ ] **Step 1: Add failing precedence and bit-matrix tests**

```swift
func testFeaturesAreAuthoritativeOverLP2CID() {
    let value = CapabilityResolver.resolve(features: [.dcPort, .dcControl], cid: 0x0305, model: "BP4SL3V2")
    XCTAssertFalse(value.hasBattery)
    XCTAssertFalse(value.hasUSBPort)
    XCTAssertTrue(value.hasDCControl)
}

func testCIDFallbackSeparatesLPPFromLPFamilies() {
    XCTAssertTrue(CapabilityResolver.resolve(features: nil, cid: 0x0306, model: nil).hasBattery)
    XCTAssertFalse(CapabilityResolver.resolve(features: nil, cid: 0x0201, model: nil).hasBattery)
}

func testEachFeatureBitMapsToItsPresentationGate() {
    let cases: [(FeatureFlags, KeyPath<DeviceCapabilities, Bool>)] = [
        (.factoryMode, \.hasFactoryMode), (.shutdown, \.canShutdown),
        (.batteryCapacity, \.hasBattery), (.dcPort, \.hasDCPort),
        (.dcControl, \.hasDCControl), (.dcScheduler, \.hasScheduler),
        (.usbPort, \.hasUSBPort), (.usbPowerLimit, \.hasPowerLimits),
        (.usbOutputControl, \.hasUSBOutputControl), (.dcBypass, \.hasBypass),
        (.dcBypassControl, \.hasBypassControl), (.usbDCInput, \.showsDCInput),
        (.usbDCInputPower, \.showsDCInputPower),
    ]
    for (flag, keyPath) in cases {
        let value = CapabilityResolver.resolve(features: flag, cid: nil, model: nil)
        XCTAssertTrue(value[keyPath: keyPath], "missing gate for \(flag)")
    }
}
```

- [ ] **Step 2: Verify RED**

Run: `swift test --package-path WattlineCore --filter CapabilityResolverTests`
Expected: compilation fails because capability types do not exist.

- [ ] **Step 3: Implement FEATURES → CID → model resolution**

```swift
public static func resolve(features: FeatureFlags?, cid: UInt16?, model: String?) -> DeviceCapabilities {
    if let features { return DeviceCapabilities(features: features) }
    if let cid { return fallback(forModelByte: UInt8(cid >> 8)) }
    return fallback(forModelString: model)
}
```

Map every §5.6 bit to a distinct capability property. LP1/LP2 fallback includes battery, DC, USB port/control/limits; LPP fallback includes DC only. Legacy model strings use API §7 mappings.

- [ ] **Step 4: Verify GREEN**

Run: `swift test --package-path WattlineCore --filter CapabilityResolverTests`
Expected: all capability tests pass.

- [ ] **Step 5: Commit**

```bash
git add WattlineCore
git commit -m "feat: resolve device capabilities"
```

### Task 5: Replay, Serialization, and Session State

**Files:**
- Create: `WattlineCore/Sources/WattlineCore/Transport/DeviceTransport.swift`
- Create: `WattlineCore/Sources/WattlineCore/Transport/ReplayTransport.swift`
- Create: `WattlineCore/Sources/WattlineCore/Transport/SerializedTransactions.swift`
- Create: `WattlineCore/Sources/WattlineCore/Device/DeviceSession.swift`
- Test: `WattlineCore/Tests/WattlineCoreTests/ReplayTransportTests.swift`
- Test: `WattlineCore/Tests/WattlineCoreTests/DeviceSessionTests.swift`

**Interfaces:**
- Produces: `DeviceTransport`, `DeviceEvent`, `DiscoveredDevice`, `ReplayStep`, `DeviceSession`, `DeviceState`.
- Consumes: command, telemetry, capability, and reconciliation types.

- [ ] **Step 1: Add failing serialization and state tests**

```swift
func testTransactionsNeverOverlap() async throws {
    let replay = ReplayTransport(steps: [.reply(after: .milliseconds(50), bytes: [1, 0x81, 0]),
                                         .reply(bytes: [2, 0x80, 0, 3])])
    async let first = replay.perform(.setDC(true))
    async let second = replay.perform(.getPowerLimit(.global))
    _ = try await (first, second)
    XCTAssertEqual(await replay.maximumInFlightCount, 1)
}

func testTelemetryBecomesStaleAfterTenSeconds() async {
    let clock = TestClock()
    let session = DeviceSession(transport: ReplayTransport(), clock: clock)
    await session.receive(.battery(.fixture, timestamp: clock.now))
    await clock.advance(by: .seconds(11))
    XCTAssertEqual(await session.state.freshness, .stale)
}

func testExpectedDisconnectCompletesRestart() async throws {
    let replay = ReplayTransport(steps: [.disconnect(error: TestError.linkLost)])
    try await replay.perform(.restart)
    XCTAssertEqual(await replay.reconnectPolicy, .armed)
}
```

- [ ] **Step 2: Verify RED**

Run: `swift test --package-path WattlineCore --filter 'ReplayTransportTests|DeviceSessionTests'`
Expected: compilation fails because transport/session APIs do not exist.

- [ ] **Step 3: Implement async event and serialization boundaries**

```swift
public protocol DeviceTransport: Sendable {
    var events: AsyncStream<DeviceEvent> { get }
    func startScan() async throws
    func stopScan() async
    func connect(to id: UUID) async throws
    func disconnect() async
    func perform(_ command: DeviceCommand) async throws -> CommandOutcome
    func refreshTelemetry() async throws
}

public actor SerializedTransactions {
    private var tail: Task<Void, Never>?
    public func enqueue<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let predecessor = tail
        let task = Task { try await predecessor?.value; return try await operation() }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}
```

Replay steps explicitly model reply, telemetry, delay, write failure, and disconnect. `DeviceSession` consumes events, timestamps snapshots, confirms pending mutations, emits timeouts, and preserves last-known values.

- [ ] **Step 4: Verify GREEN and the complete core suite**

Run: `swift test --package-path WattlineCore`
Expected: all core tests pass with no failures.

- [ ] **Step 5: Commit**

```bash
git add WattlineCore
git commit -m "feat: add replay transport and device session"
```

### Task 6: CoreBluetooth Engine and Discovery Policy

**Files:**
- Create: `WattlineCore/Sources/WattlineCore/BLE/GATTUUID.swift`
- Create: `WattlineCore/Sources/WattlineCore/BLE/BluetoothDelegateBridge.swift`
- Create: `WattlineCore/Sources/WattlineCore/BLE/BLETransport.swift`
- Create: `WattlineCore/Sources/WattlineCore/Device/DiscoveryPolicy.swift`
- Test: `WattlineCore/Tests/WattlineCoreTests/DiscoveryPolicyTests.swift`
- Test: `WattlineCore/Tests/WattlineCoreTests/BLETransactionStateMachineTests.swift`

**Interfaces:**
- Consumes: `DeviceTransport`, `SerializedTransactions`, command policies.
- Produces: production `BLETransport` and pure delegate-state-machine functions testable without hardware.

- [ ] **Step 1: Add failing fresh-name, OTA, and transaction-order tests**

```swift
func testFreshAdvertisementNameWinsOverStalePeripheralName() {
    let result = DiscoveryPolicy.classify(localName: "PeakDo-OTA", cachedPeripheralName: "Link-Power-2")
    XCTAssertEqual(result, .ota)
}

func testCachedNameCannotAdmitUnrelatedAdvertisement() {
    XCTAssertNil(DiscoveryPolicy.classify(localName: "Other Device", cachedPeripheralName: "Link-Power-2"))
}

func testCommandStateMachineWritesWithResponseBeforeRead() throws {
    var machine = BLETransactionStateMachine(command: Data([0x01, 0x01, 0x01]))
    XCTAssertEqual(try machine.start(), .writeWithResponse(characteristic: .command))
    XCTAssertEqual(try machine.didWrite(), .read(characteristic: .command))
}

func testOTAModeUsesRecoveryClassificationForBondFailure() {
    XCTAssertEqual(OTAConnectionPolicy(mode: .bootloader, errorCode: 14).resolution, .showBondRecoveryGuidance)
}
```

- [ ] **Step 2: Verify RED**

Run: `swift test --package-path WattlineCore --filter 'DiscoveryPolicyTests|BLETransactionStateMachineTests'`
Expected: compilation fails because BLE policy/state-machine types do not exist.

- [ ] **Step 3: Implement CoreBluetooth delegate bridge**

Use `CBCentralManager(delegate:queue:options:)` with `CBCentralManagerOptionRestoreIdentifierKey`, scan service `5301`, and read `CBAdvertisementDataLocalNameKey`. Discover services `5301/180A/1805`; map characteristics `4301–4305`, `4310`, `2A24`, `2A26–2A28`, and `2A2B`. Route delegate callbacks to checked continuations exactly once.

For `4302`, enqueue the operation, call `writeValue(..., type: .withResponse)`, wait for `didWriteValueFor`, call `readValue`, and complete only from the subsequent `didUpdateValueFor`. Subscribe to supported `4303/4304/4305` characteristics after initial reads.

- [ ] **Step 4: Verify GREEN and compile the package for iOS**

Run: `swift test --package-path WattlineCore`
Expected: all tests pass.

Run: `cd WattlineCore && xcodebuild -scheme WattlineCore -destination 'generic/platform=iOS Simulator' build`
Expected: build succeeds for iOS Simulator.

- [ ] **Step 5: Commit**

```bash
git add WattlineCore
git commit -m "feat: add serialized CoreBluetooth transport"
```

### Task 7: Deterministic Demo Transport

**Files:**
- Create: `WattlineCore/Sources/WattlineCore/Transport/DemoTransport.swift`
- Test: `WattlineCore/Tests/WattlineCoreTests/DemoTransportTests.swift`

**Interfaces:**
- Implements: `DeviceTransport`.
- Produces: fixed LP2_V5 identity, FEATURES `0x7FFF`, one-hertz plausible telemetry, P0 control simulation, charger toggle.

- [ ] **Step 1: Add failing deterministic simulation tests**

```swift
func testDemoIdentityMatchesContract() async throws {
    let demo = DemoTransport(seed: 0x57415454)
    let identity = try await demo.connectDemo()
    XCTAssertEqual(identity.name, "Link-Power 2 (Demo)")
    XCTAssertEqual(identity.cid, 0x0305)
    XCTAssertEqual(identity.features.rawValue, 0x7FFF)
    XCTAssertEqual(identity.firmware, "1.4.9")
}

func testTypeCOutputChangesModeWhileEnabledStaysTrue() async throws {
    let demo = DemoTransport(seed: 1)
    try await demo.perform(.setTypeCOutput(false))
    let status = await demo.snapshot.typeC
    XCTAssertTrue(status.enabled)
    XCTAssertEqual(status.mode, .input)
}

func testLimitClearReportsDeviceDefaultAndRuntimeCanBeUnset() async throws {
    let demo = DemoTransport(seed: 1)
    try await demo.perform(.setPowerLimit(.input, level: .watts30))
    try await demo.perform(.clearPowerLimit(.input))
    XCTAssertEqual(await demo.snapshot.limits[.input], .watts65)
    XCTAssertNil(await demo.snapshot.limits[.runtime])
}
```

- [ ] **Step 2: Verify RED**

Run: `swift test --package-path WattlineCore --filter DemoTransportTests`
Expected: compilation fails because `DemoTransport` does not exist.

- [ ] **Step 3: Implement deterministic telemetry and controls**

Start at 62%, discharging −45 W, DC 19.6 V/1.2 A, USB-C 12 V/1.4 A. Derive runtime from remaining watt-hours divided by absolute power. Use a seeded linear-congruential generator to apply bounded ±2% jitter. `setChargerConnected(true)` changes flow to charging at +100 W and green-state telemetry. Emit `.isDemo(true)` and telemetry events on the same stream as BLE.

- [ ] **Step 4: Verify GREEN**

Run: `swift test --package-path WattlineCore`
Expected: all core tests pass.

- [ ] **Step 5: Commit**

```bash
git add WattlineCore
git commit -m "feat: add deterministic Wattline demo transport"
```

### Task 8: Reusable SwiftUI Package

**Files:**
- Create: `WattlineUI/Package.swift`
- Create: `WattlineUI/Sources/WattlineUI/Theme.swift`
- Create: `WattlineUI/Sources/WattlineUI/BatteryHero.swift`
- Create: `WattlineUI/Sources/WattlineUI/DCPortHero.swift`
- Create: `WattlineUI/Sources/WattlineUI/PortCard.swift`
- Create: `WattlineUI/Sources/WattlineUI/StatTile.swift`
- Create: `WattlineUI/Sources/WattlineUI/LimitSlider.swift`
- Create: `WattlineUI/Sources/WattlineUI/DemoBadge.swift`
- Test: `WattlineUI/Tests/WattlineUITests/CapabilityCompositionTests.swift`

**Interfaces:**
- Consumes: public WattlineCore display models.
- Produces: stateless SwiftUI components and `DashboardSections` capability composition.

- [ ] **Step 1: Add failing capability composition tests**

```swift
func testUSBRemovalRemovesCardLimitsAndToggle() {
    let sections = DashboardSections(capabilities: .init(hasBattery: true, hasDCPort: true, hasUSBPort: false))
    XCTAssertFalse(sections.contains(.usbCard))
    XCTAssertFalse(sections.contains(.limitsLink))
}

func testBatteryRemovalUsesDCHeroAndNoBatteryStats() {
    let sections = DashboardSections(capabilities: .dcOnly)
    XCTAssertTrue(sections.contains(.dcHero))
    XCTAssertFalse(sections.contains(.batteryHero))
    XCTAssertFalse(sections.contains(.batteryStats))
}
```

- [ ] **Step 2: Verify RED**

Run: `swift test --package-path WattlineUI`
Expected: compilation fails because `DashboardSections` and UI components do not exist.

- [ ] **Step 3: Implement components and dark instrument theme**

```swift
public enum WattlineTheme {
    public static let accent = Color.indigo
    public static let charging = Color.green
    public static let discharging = Color.orange
    public static let surface = Color(red: 0.08, green: 0.09, blue: 0.12)
}

public struct DemoBadge: View {
    public var body: some View {
        Text("DEMO").font(.caption2.weight(.bold)).monospaced()
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.indigo, in: Capsule()).foregroundStyle(.white)
    }
}
```

BatteryHero segmented mode renders twenty rounded segments and gauge mode uses an angular `Gauge`. All numerals use `.monospacedDigit()`. `LimitSlider` snaps indices 0–5 and labels 30/45/60/65/100/140 W. PortCard exposes callbacks but does not own device state.

- [ ] **Step 4: Verify GREEN and iOS compilation**

Run: `swift test --package-path WattlineUI`
Expected: all UI package tests pass.

Run: `cd WattlineUI && xcodebuild -scheme WattlineUI -destination 'generic/platform=iOS Simulator' build`
Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add WattlineUI
git commit -m "feat: add Wattline SwiftUI component library"
```

### Task 9: Xcode App Shell, Onboarding, and Scan

**Files:**
- Create: `Wattline/Wattline.xcodeproj/project.pbxproj`
- Create: `Wattline/Wattline/Info.plist`
- Create: `Wattline/Wattline/Wattline.entitlements`
- Create: `Wattline/Wattline/WattlineApp.swift`
- Create: `Wattline/Wattline/AppModel.swift`
- Create: `Wattline/Wattline/RootView.swift`
- Create: `Wattline/Wattline/OnboardingView.swift`
- Create: `Wattline/Wattline/ScanView.swift`
- Create: `Wattline/WattlineUITests/WattlineEntryUITests.swift`

**Interfaces:**
- Consumes: both local packages.
- Produces: iOS application target `Wattline`, permission-primed transport creation, Demo entry, scan and reconnect flows.

- [ ] **Step 1: Create the Xcode project and app target configuration**

Configure product type `com.apple.product-type.application`, bundle identifier `com.keithah.wattline`, Swift 6, `IPHONEOS_DEPLOYMENT_TARGET = 17.0`, generated asset-symbol support off, and local package references `../WattlineCore` and `../WattlineUI`. Add `NSBluetoothAlwaysUsageDescription` and background mode `bluetooth-central`; add no network, local-network, or location keys.

- [ ] **Step 2: Add and run failing onboarding and Demo-entry UI tests**

```swift
func testColdLaunchPrimesPermissionAndOffersDemo() {
    let app = XCUIApplication()
    app.launchArguments = ["-resetOnboarding"]
    app.launch()
    XCTAssertTrue(app.staticTexts["Your power, at a glance"].exists)
    XCTAssertTrue(app.buttons["Connect a device"].exists)
    XCTAssertTrue(app.buttons["Try Demo Mode"].exists)
}

func testDemoEntryDoesNotShowBluetoothPermissionUI() {
    let app = XCUIApplication()
    app.launchArguments = ["-resetOnboarding"]
    app.launch()
    app.buttons["Try Demo Mode"].tap()
    XCTAssertTrue(app.staticTexts["DEMO"].waitForExistence(timeout: 3))
}
```

Run: `xcodebuild test -project Wattline/Wattline.xcodeproj -scheme Wattline -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WattlineUITests/WattlineEntryUITests`
Expected: tests fail because the app flow does not exist.

- [ ] **Step 3: Add the app state and onboarding flow**

```swift
@main
struct WattlineApp: App {
    @State private var model = AppModel()
    var body: some Scene { WindowGroup { RootView().environment(model) } }
}

@MainActor @Observable
final class AppModel {
    enum Route { case onboarding, scan, connected }
    var route: Route = UserDefaults.standard.bool(forKey: "onboardingComplete") ? .scan : .onboarding
    var isDemo = false

    func enterDemo() {
        isDemo = true
        attach(transport: DemoTransport(seed: 0x57415454))
        route = .connected
    }

    func requestBluetoothAfterPriming() {
        attach(transport: BLETransport())
        route = .scan
    }
}
```

`OnboardingView` presents Glanceable, Private, and Automatable panes, then buttons “Connect a device” and “Try Demo Mode.” Do not construct `BLETransport` before the first button is tapped. Bluetooth denied/restricted state shows Settings and Demo buttons. Implement `-resetOnboarding` handling before `AppModel` reads UserDefaults.

- [ ] **Step 4: Add scanning and known-device presentation**

Render live `DiscoveredDevice` values with local name, known identity/MAC or “New device,” and four RSSI bars. Sort known devices first. Label `.ota` as “In firmware-update mode” and route it to a Phase 1 recovery explanation. Pull-to-refresh stops and restarts scanning. Persist identifier and cached identity only after successful handshake.

- [ ] **Step 5: Verify GREEN and build the app shell**

Run: `xcodebuild test -project Wattline/Wattline.xcodeproj -scheme Wattline -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WattlineUITests/WattlineEntryUITests`
Expected: both entry UI tests pass.

Run: `xcodebuild -project Wattline/Wattline.xcodeproj -scheme Wattline -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Wattline
git commit -m "feat: add Wattline onboarding and device scan"
```

### Task 10: Dashboard, Limits, Placeholders, and Demo Controls

**Files:**
- Create: `Wattline/Wattline/DashboardView.swift`
- Create: `Wattline/Wattline/LimitsView.swift`
- Create: `Wattline/Wattline/PlaceholderView.swift`
- Create: `Wattline/Wattline/ToastView.swift`
- Modify: `Wattline/Wattline/RootView.swift`
- Modify: `Wattline/Wattline/AppModel.swift`
- Create: `Wattline/WattlineUITests/WattlineDashboardUITests.swift`

**Interfaces:**
- Consumes: `DeviceState`, P0 commands, `DashboardSections`, and all reusable views.
- Produces: complete Phase 1 navigable app.

- [ ] **Step 1: Add and run failing dashboard and limits UI tests**

```swift
func testDemoDashboardControlsAndLimitsAreReachable() {
    let app = launchInDemoMode()
    XCTAssertTrue(app.switches["DC Port"].exists)
    XCTAssertTrue(app.switches["USB-C Output"].exists)
    app.buttons["USB-C Power Limits"].tap()
    XCTAssertTrue(app.sliders["Global limit"].exists)
    XCTAssertTrue(app.staticTexts["Runtime limit"].exists)
}

func testEveryPlaceholderTabRetainsDemoBadge() {
    let app = launchInDemoMode()
    for tab in ["Timers", "Shortcuts", "Settings"] {
        app.tabBars.buttons[tab].tap()
        XCTAssertTrue(app.staticTexts["DEMO"].exists)
    }
}
```

Run: `xcodebuild test -project Wattline/Wattline.xcodeproj -scheme Wattline -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WattlineUITests/WattlineDashboardUITests`
Expected: tests fail because the dashboard, limits, and tabs do not exist.

- [ ] **Step 2: Compose capability-gated dashboard sections**

```swift
ForEach(DashboardSections(capabilities: model.state.capabilities)) { section in
    switch section {
    case .batteryHero: BatteryHero(snapshot: model.state.battery, style: heroStyle)
    case .dcHero: DCPortHero(snapshot: model.state.dc)
    case .batteryStats: batteryStats
    case .dcCard: dcCard
    case .usbCard: usbCard
    case .limitsLink: limitsLink
    }
}
```

Use a `NavigationStack` within Home and a four-item `TabView`. Timers, Shortcuts, and Settings use `PlaceholderView`; Settings additionally exposes “Connect a real device.” Overlay `DemoBadge` at the root of every tab when `model.isDemo`.

- [ ] **Step 3: Wire authoritative port mutations**

DC and Type-C switches call `DeviceController`. Preserve the last telemetry value while pending and render `ProgressView` in the card. On three-second timeout, clear pending state, retain telemetry truth, and show a toast. Type-C derives output-on from mode 2/3 only.

- [ ] **Step 4: Build limits set/reset/readback flow**

On entry GET all four types. For types 1–3, snap the three sliders to six levels; send SET at edit completion and display only follow-up GET results. Reset calls DEL and then GET. Runtime is a read-only StatTile displaying “—” for the accepted type-4 `0xFF` result. Display the exact persistence/safety note from spec §4.4.

- [ ] **Step 5: Add persisted hero style, refresh, staleness, and demo charger**

Store segmented/gauge choice with `@AppStorage("batteryHeroStyle")`. Long press switches style. `.refreshable` reads supported telemetry. Dim values older than ten seconds and show last-updated/reconnecting context. In Demo Mode show “Plug in charger”/“Unplug charger,” calling the simulation hook.

- [ ] **Step 6: Verify GREEN and run all automated tests**

Run: `xcodebuild test -project Wattline/Wattline.xcodeproj -scheme Wattline -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WattlineUITests/WattlineDashboardUITests`
Expected: both dashboard UI tests pass.

Run: `swift test --package-path WattlineCore && swift test --package-path WattlineUI`
Expected: both suites pass with zero failures.

Run: `xcodebuild -project Wattline/Wattline.xcodeproj -scheme Wattline -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add Wattline
git commit -m "feat: complete Wattline phase 1 UI"
```

### Task 11: Simulator Acceptance and Network Audit

**Files:**
- Create: `Wattline/WattlineUITests/WattlineDemoUITests.swift`
- Modify: `Wattline/Wattline.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: launch argument `-resetOnboarding` and accessibility identifiers on all acceptance surfaces.
- Produces: repeatable Demo Mode simulator evidence.

- [ ] **Step 1: Add a failing UI test for the P0 tour**

```swift
func testDemoModeDrivesEveryP0Surface() {
    let app = XCUIApplication()
    app.launchArguments = ["-resetOnboarding"]
    app.launch()
    app.buttons["Try Demo Mode"].tap()
    XCTAssertTrue(app.staticTexts["DEMO"].exists)
    XCTAssertTrue(app.staticTexts["62%"].waitForExistence(timeout: 3))
    app.switches["DC Port"].tap()
    app.buttons["USB-C Power Limits"].tap()
    XCTAssertTrue(app.sliders["Global limit"].exists)
    app.buttons["Reset Input limit"].tap()
    app.tabBars.buttons["Timers"].tap()
    XCTAssertTrue(app.staticTexts["Coming in Phase 2"].exists)
    XCTAssertTrue(app.staticTexts["DEMO"].exists)
}
```

- [ ] **Step 2: Verify RED**

Run: `xcodebuild test -project Wattline/Wattline.xcodeproj -scheme Wattline -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WattlineUITests/WattlineDemoUITests/testDemoModeDrivesEveryP0Surface`
Expected: test fails on the first missing accessibility identifier or behavior.

- [ ] **Step 3: Add accessibility identifiers and launch reset support**

Assign stable identifiers to DC/USB toggles, limits navigation, every slider/reset, hero style controls, tab buttons, Demo badge, and charger control. In debug/test launches only, `-resetOnboarding` clears onboarding state before `AppModel` initialization.

- [ ] **Step 4: Verify GREEN with the full simulator suite**

Run: `rm -rf /tmp/WattlineDerivedData && xcodebuild test -project Wattline/Wattline.xcodeproj -scheme Wattline -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/WattlineDerivedData`
Expected: all unit and UI tests pass.

- [ ] **Step 5: Launch the installed app and capture acceptance evidence**

Run: `xcrun simctl bootstatus 'iPhone 17 Pro' -b && xcrun simctl install booted /tmp/WattlineDerivedData/Build/Products/Debug-iphonesimulator/Wattline.app && xcrun simctl launch booted com.keithah.wattline -resetOnboarding`
Expected: launch returns the process identifier; inspect onboarding, Demo dashboard, toggles, both hero styles, limits, every tab badge, and Connect-a-real-device exit in the simulator.

- [ ] **Step 6: Audit for forbidden networking**

Run: `rg -n 'URLSession|Network\.framework|import Network|NWConnection|WKWebView|SFSafari|api\.peakdo|http://|https://' WattlineCore WattlineUI Wattline || true`
Expected: no matches in product source or entitlements.

Run: `plutil -p Wattline/Wattline/Info.plist && codesign -d --entitlements :- /tmp/WattlineDerivedData/Build/Products/Debug-iphonesimulator/Wattline.app`
Expected: Bluetooth usage/background entries are present; local-network and networking entitlements are absent.

- [ ] **Step 7: Run final clean verification and commit acceptance coverage**

Run: `rm -rf /tmp/WattlineDerivedData && xcodebuild test -project Wattline/Wattline.xcodeproj -scheme Wattline -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/WattlineDerivedData`
Expected: clean build and all tests pass.

```bash
git add Wattline
git commit -m "test: verify Wattline demo mode acceptance"
```

## Hardware-Only Exit Checks

The following cannot be honestly completed without the LP2_V5 and remain explicit handoff checks:

- Run a 48-hour notification/control soak with zero stuck pending states.
- Measure stored-peripheral automatic reconnect and confirm ≤10 seconds at p95.
- Confirm live DC notification arrives within approximately one second after control.
- Confirm live Type-C modes 3→1→3 and power-limit persistence across restart.
