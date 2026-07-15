import Foundation
import XCTest
@testable import WattlineCore

final class HandshakeTests: XCTestCase {
    func testOTAInfoParsesAppCIDFromLiveFifteenByteVector() throws {
        let info = try OTAInfo(frame: Data([
            0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x05, 0x03,
        ]))

        XCTAssertEqual(info.mode, .application)
        XCTAssertEqual(info.cid, 0x0305)
    }

    func testOTAInfoParsesBootloaderModeAndCID() throws {
        let info = try OTAInfo(frame: Data([
            0x02, 0x00, 0x10, 0x00, 0x00, 0x00, 0x10, 0x83, 0x00,
            0x00, 0x00, 0x04, 0x00, 0x05, 0x03, 0x01, 0, 0, 0, 0,
        ]))

        XCTAssertEqual(info.mode, .ota)
        XCTAssertEqual(info.cid, 0x0305)
    }

    func testOTAInfoTreatsTruncatedAndZeroCIDAsUnavailable() throws {
        XCTAssertNil(try OTAInfo(frame: Data([0x01])).cid)
        var zeroCID = Data(repeating: 0, count: 15)
        zeroCID[0] = 1
        XCTAssertNil(try OTAInfo(frame: zeroCID).cid)
    }

    func testCurrentTimeEncodesExactTenBytePayload() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 14, hour: 15, minute: 4, second: 5,
            nanosecond: 500_000_000
        )))

        XCTAssertEqual(
            CurrentTimeCodec.encode(date, calendar: calendar, adjustReason: 1),
            Data([0xEA, 0x07, 7, 14, 15, 4, 5, 2, 128, 1])
        )
    }

    func testScriptedDriverRunsExactApplicationHandshakeThroughSubscriptionAcknowledgements() throws {
        let scope = BLEConnectionScope(peripheralID: UUID(), generation: 1)
        let date = fixedDate
        let calendar = utcGregorian
        var driver = BLEHandshakeDriver(
            scope: scope, advertisedName: "Link-Power-1",
            now: { date }, calendar: calendar
        )
        let all = Set(GATTUUID.allCases)

        XCTAssertEqual(driver.start(), .settle)
        XCTAssertEqual(driver.settleCompleted(scope: scope), .discoverServices)
        XCTAssertEqual(driver.characteristicsDiscovered(scope: scope, available: all), .write(
            Data([0x84]), to: .ota, readAfterWrite: true
        ))
        XCTAssertEqual(driver.writeCompleted(scope: scope, uuid: .ota, succeeded: true), .read(.ota))
        XCTAssertEqual(driver.readCompleted(scope: scope, uuid: .ota, value: appInfo), .read(.modelNumber))

        XCTAssertEqual(driver.readCompleted(scope: scope, uuid: .modelNumber, value: Data("BP4SL3V2".utf8)), .read(.hardwareRevision))
        XCTAssertEqual(driver.readCompleted(scope: scope, uuid: .hardwareRevision, value: Data("V5#0305".utf8)), .read(.firmwareRevision))
        XCTAssertEqual(driver.readCompleted(scope: scope, uuid: .firmwareRevision, value: Data("2.0.2".utf8)), .read(.softwareRevision))
        XCTAssertEqual(driver.readCompleted(scope: scope, uuid: .softwareRevision, value: Data("1.4.9".utf8)), .write(
            Data([0xFE, 0x00]), to: .command, readAfterWrite: true
        ))
        XCTAssertEqual(driver.writeCompleted(scope: scope, uuid: .command, succeeded: true), .read(.command))
        XCTAssertEqual(driver.readCompleted(scope: scope, uuid: .command, value: Data([0xFE, 0x80, 0, 0x30, 1, 0, 0])), .write(
            Data([0x10, 0x00]), to: .command, readAfterWrite: true
        ))
        XCTAssertEqual(driver.writeCompleted(scope: scope, uuid: .command, succeeded: true), .read(.command))
        XCTAssertEqual(driver.readCompleted(scope: scope, uuid: .command, value: Data([0x10, 0x80, 0, 0x2B, 0x72, 0xEB, 0x5A, 0x04, 0xDC])), .write(
            Data([0xEA, 0x07, 7, 14, 15, 4, 5, 2, 128, 1]), to: .currentTime, readAfterWrite: false
        ))
        XCTAssertEqual(driver.writeCompleted(scope: scope, uuid: .currentTime, succeeded: true), .read(.extendedBatteryInfo))
        XCTAssertEqual(driver.readCompleted(scope: scope, uuid: .extendedBatteryInfo, value: Data()), .subscribe(.extendedBatteryInfo))
        XCTAssertEqual(driver.notificationStateUpdated(scope: scope, uuid: .extendedBatteryInfo, succeeded: true, isNotifying: true), .read(.dcPortStatus))
        XCTAssertEqual(driver.readCompleted(scope: scope, uuid: .dcPortStatus, value: Data()), .subscribe(.dcPortStatus))
        XCTAssertEqual(driver.notificationStateUpdated(scope: scope, uuid: .dcPortStatus, succeeded: true, isNotifying: true), .read(.typeCPortStatus))
        XCTAssertEqual(driver.readCompleted(scope: scope, uuid: .typeCPortStatus, value: Data()), .subscribe(.typeCPortStatus))
        guard case let .publish(snapshot) = driver.notificationStateUpdated(
            scope: scope, uuid: .typeCPortStatus, succeeded: true, isNotifying: true
        ) else { return XCTFail("Expected snapshot") }
        XCTAssertEqual(snapshot.rawFeatures, 0x000130)
        XCTAssertEqual(snapshot.macAddress, "DC:04:5A:EB:72:2B")
        XCTAssertEqual(driver.eventEmitted(scope: scope), .connected(scope.peripheralID))
    }

    func testSubscriptionFailureCannotPublishSnapshotOrConnected() {
        var harness = DriverHarness(features: [.dcPort])
        XCTAssertEqual(harness.advanceToFirstSubscription(), .subscribe(.dcPortStatus))
        XCTAssertEqual(
            harness.driver.notificationStateUpdated(
                scope: harness.scope, uuid: .dcPortStatus, succeeded: false, isNotifying: false
            ),
            .fail(.subscriptionFailed(.dcPortStatus))
        )
        XCTAssertNil(harness.driver.eventEmitted(scope: harness.scope))
    }

    func testStaleGenerationSubscriptionCallbackCannotAdvance() {
        var harness = DriverHarness(features: [.dcPort])
        XCTAssertEqual(harness.advanceToFirstSubscription(), .subscribe(.dcPortStatus))
        let stale = BLEConnectionScope(
            peripheralID: harness.scope.peripheralID,
            generation: harness.scope.generation - 1
        )
        XCTAssertNil(harness.driver.notificationStateUpdated(
            scope: stale, uuid: .dcPortStatus, succeeded: true, isNotifying: true
        ))
        guard case .publish = harness.driver.notificationStateUpdated(
            scope: harness.scope, uuid: .dcPortStatus, succeeded: true, isNotifying: true
        ) else { return XCTFail("Expected current subscription ACK to advance") }
    }

    func testNotificationCallbackExpectationChecksGenerationAndCharacteristic() {
        let peripheralID = UUID()
        var callbacks = BLEBridgeCallbackStateMachine()
        let stale = callbacks.beginConnection(peripheralID: peripheralID)
        let current = callbacks.beginConnection(peripheralID: peripheralID)
        callbacks.expectNotification(scope: current, characteristic: .dcPortStatus)

        XCTAssertEqual(callbacks.didUpdateNotification(scope: stale, characteristic: .dcPortStatus), .ignored)
        XCTAssertEqual(callbacks.didUpdateNotification(scope: current, characteristic: .typeCPortStatus), .ignored)
        XCTAssertEqual(callbacks.didUpdateNotification(scope: current, characteristic: .dcPortStatus), .accepted)
        XCTAssertEqual(callbacks.didUpdateNotification(scope: current, characteristic: .dcPortStatus), .ignored)
    }

    func testOTADriverPublishesWithoutAppCharacteristicAccess() {
        let scope = BLEConnectionScope(peripheralID: UUID(), generation: 1)
        let date = fixedDate
        let calendar = utcGregorian
        var driver = BLEHandshakeDriver(scope: scope, advertisedName: nil, now: { date }, calendar: calendar)
        XCTAssertEqual(driver.start(), .settle)
        XCTAssertEqual(driver.settleCompleted(scope: scope), .discoverServices)
        XCTAssertEqual(driver.characteristicsDiscovered(scope: scope, available: [.ota]), .write(Data([0x84]), to: .ota, readAfterWrite: true))
        XCTAssertEqual(driver.writeCompleted(scope: scope, uuid: .ota, succeeded: true), .read(.ota))
        guard case let .publish(snapshot) = driver.readCompleted(scope: scope, uuid: .ota, value: bootloaderInfo) else {
            return XCTFail("Expected OTA snapshot")
        }
        XCTAssertEqual(snapshot.mode, .ota)
        XCTAssertEqual(snapshot.capabilities.features.rawValue, 0)
        XCTAssertFalse(snapshot.capabilities.hasBattery)
        XCTAssertFalse(snapshot.capabilities.hasDCPort)
        XCTAssertFalse(snapshot.capabilities.hasUSBPort)
        XCTAssertFalse(snapshot.capabilities.hasPowerLimits)
        XCTAssertEqual(driver.eventEmitted(scope: scope), .connected(scope.peripheralID))
    }

    func testFeaturesZeroIsAuthoritativeAndFailuresFallBack() throws {
        let zero = try HandshakeCodec.features(from: Data([0xFE, 0x80, 0, 0, 0, 0, 0]))
        XCTAssertEqual(zero.rawValue, 0)
        XCTAssertEqual(
            CapabilityResolver.resolve(features: zero, cid: 0x0305, model: "BP4SL3V2").features.rawValue,
            0
        )
        XCTAssertTrue(CapabilityResolver.resolve(features: nil, cid: 0x0201, model: "BP4SL3V2").hasDCPort)
        XCTAssertFalse(CapabilityResolver.resolve(features: nil, cid: 0x0201, model: "BP4SL3V2").hasBattery)
        XCTAssertTrue(CapabilityResolver.resolve(features: nil, cid: nil, model: "BP4SL3V2").hasBattery)
    }

    func testDeviceSessionRetainsHandshakeSnapshot() async {
        let session = DeviceSession(transport: ReplayTransport())
        let snapshot = DeviceIdentitySnapshot(
            peripheralID: UUID(), advertisedName: "Link-Power-1", mode: .application,
            cid: 0x0305, rawFeatures: 0,
            capabilities: DeviceCapabilities(features: [])
        )

        await session.receive(.handshakeCompleted(snapshot))

        let state = await session.state
        XCTAssertEqual(state.identity, snapshot)
    }

    func testCancelledHandshakeGenerationCannotCompleteNewConnection() {
        let current = BLEConnectionScope(peripheralID: UUID(), generation: 2)
        let stale = BLEConnectionScope(peripheralID: current.peripheralID, generation: 1)
        let date = fixedDate
        let calendar = utcGregorian
        var driver = BLEHandshakeDriver(scope: current, advertisedName: nil, now: { date }, calendar: calendar)
        XCTAssertEqual(driver.start(), .settle)
        XCTAssertNil(driver.settleCompleted(scope: stale))
        XCTAssertEqual(driver.settleCompleted(scope: current), .discoverServices)
        XCTAssertEqual(driver.characteristicsDiscovered(scope: current, available: [.ota]), .write(Data([0x84]), to: .ota, readAfterWrite: true))
        XCTAssertNil(driver.writeCompleted(scope: stale, uuid: .ota, succeeded: true))
        XCTAssertEqual(driver.writeCompleted(scope: current, uuid: .ota, succeeded: true), .read(.ota))
        XCTAssertNil(driver.readCompleted(scope: stale, uuid: .ota, value: bootloaderInfo))
        guard case .publish = driver.readCompleted(scope: current, uuid: .ota, value: bootloaderInfo) else {
            return XCTFail("Expected current generation to advance")
        }
    }

    func testDefaultCurrentTimeCalendarIsGregorian() {
        XCTAssertEqual(CurrentTimeCodec.defaultCalendar().identifier, .gregorian)
        XCTAssertEqual(CurrentTimeCodec.defaultCalendar().timeZone, .current)
    }

    func testAdvertisedNameRequiresFreshAdvertisementLocalName() {
        XCTAssertEqual(HandshakeAdvertisementPolicy.advertisedName(freshLocalName: "Link-Power-1"), "Link-Power-1")
        XCTAssertNil(HandshakeAdvertisementPolicy.advertisedName(freshLocalName: nil))
    }

    func testCurrentTimeSamplesProviderOnlyWhenWriteActionIsEnacted() {
        let provider = LockedDateProvider(initial: Date(timeIntervalSince1970: 0))
        let scope = BLEConnectionScope(peripheralID: UUID(), generation: 1)
        var driver = BLEHandshakeDriver(
            scope: scope,
            advertisedName: nil,
            now: { provider.current() },
            calendar: utcGregorian
        )

        _ = driver.start()
        _ = driver.settleCompleted(scope: scope)
        _ = driver.characteristicsDiscovered(
            scope: scope,
            available: [.ota, .command, .currentTime]
        )
        _ = driver.writeCompleted(scope: scope, uuid: .ota, succeeded: true)
        _ = driver.readCompleted(scope: scope, uuid: .ota, value: appInfo)
        _ = driver.writeCompleted(scope: scope, uuid: .command, succeeded: true)

        XCTAssertEqual(provider.callCount, 0)
        provider.set(fixedDate)
        let action = driver.readCompleted(
            scope: scope,
            uuid: .command,
            value: Data([0xFE, 0x80, 0, 0, 0, 0, 0])
        )
        _ = driver.writeCompleted(scope: scope, uuid: .command, succeeded: true)
        XCTAssertEqual(action, .write(Data([0x10, 0x00]), to: .command, readAfterWrite: true))
        XCTAssertEqual(
            driver.readCompleted(scope: scope, uuid: .command, value: nil),
            .write(Data([0xEA, 0x07, 7, 14, 15, 4, 5, 2, 128, 1]), to: .currentTime, readAfterWrite: false)
        )
        XCTAssertEqual(provider.callCount, 1)
    }

    private var fixedDate: Date { utcGregorian.date(from: DateComponents(year: 2026, month: 7, day: 14, hour: 15, minute: 4, second: 5, nanosecond: 500_000_000))! }
    private var utcGregorian: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private var appInfo: Data { Data([0x01] + Array(repeating: 0, count: 12) + [0x05, 0x03]) }
    private var bootloaderInfo: Data { Data([0x02] + Array(repeating: 0, count: 12) + [0x05, 0x03]) }
}

private struct DriverHarness {
    let scope = BLEConnectionScope(peripheralID: UUID(), generation: 1)
    var driver: BLEHandshakeDriver

    init(features: FeatureFlags) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        driver = BLEHandshakeDriver(scope: scope, advertisedName: nil, now: { Date(timeIntervalSince1970: 0) }, calendar: calendar)
        _ = driver.start()
        _ = driver.settleCompleted(scope: scope)
        _ = driver.characteristicsDiscovered(scope: scope, available: [.ota, .command, .currentTime, .dcPortStatus])
        _ = driver.writeCompleted(scope: scope, uuid: .ota, succeeded: true)
        _ = driver.readCompleted(scope: scope, uuid: .ota, value: Data([1]))
        _ = driver.writeCompleted(scope: scope, uuid: .command, succeeded: true)
        let raw = features.rawValue
        _ = driver.readCompleted(scope: scope, uuid: .command, value: Data([0xFE, 0x80, 0, UInt8(raw), UInt8(raw >> 8), UInt8(raw >> 16), UInt8(raw >> 24)]))
        _ = driver.writeCompleted(scope: scope, uuid: .command, succeeded: true)
        _ = driver.readCompleted(scope: scope, uuid: .command, value: nil)
        _ = driver.writeCompleted(scope: scope, uuid: .currentTime, succeeded: true)
    }

    mutating func advanceToFirstSubscription() -> BLEHandshakeAction? {
        driver.readCompleted(scope: scope, uuid: .dcPortStatus, value: Data())
    }
}

private final class LockedDateProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    private var calls = 0

    init(initial: Date) { date = initial }

    var callCount: Int { lock.withLock { calls } }
    func set(_ date: Date) { lock.withLock { self.date = date } }
    func current() -> Date {
        lock.withLock {
            calls += 1
            return date
        }
    }
}
