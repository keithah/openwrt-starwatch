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
            CurrentTimeCodec.encode(date, calendar: calendar),
            Data([0xEA, 0x07, 7, 14, 15, 4, 5, 2, 128, 1])
        )
    }

    func testApplicationHandshakeOrderUsesCapabilitiesForTelemetry() {
        let capabilities = DeviceCapabilities(features: [.batteryCapacity, .dcPort, .usbPort])

        XCTAssertEqual(HandshakePlan.operations(mode: .application, capabilities: capabilities), [
            .settle, .discoverServices, .otaInfo,
            .readDIS(.modelNumber), .readDIS(.hardwareRevision),
            .readDIS(.firmwareRevision), .readDIS(.softwareRevision),
            .features, .deviceID, .writeCurrentTime,
            .readTelemetry(.extendedBatteryInfo), .subscribe(.extendedBatteryInfo),
            .readTelemetry(.dcPortStatus), .subscribe(.dcPortStatus),
            .readTelemetry(.typeCPortStatus), .subscribe(.typeCPortStatus),
            .publishSnapshot, .connected,
        ])
    }

    func testLPPHandshakeSubscribesOnlyDC() {
        let capabilities = CapabilityResolver.resolve(features: nil, cid: 0x0201, model: nil)
        let operations = HandshakePlan.operations(mode: .application, capabilities: capabilities)

        XCTAssertEqual(operations.filter(\.isTelemetry), [
            .readTelemetry(.dcPortStatus), .subscribe(.dcPortStatus),
        ])
    }

    func testLP2HandshakeUsesAllTelemetryChannels() {
        let capabilities = CapabilityResolver.resolve(features: nil, cid: 0x0305, model: nil)
        let operations = HandshakePlan.operations(mode: .application, capabilities: capabilities)

        XCTAssertEqual(operations.filter(\.isTelemetry).count, 6)
    }

    func testBootloaderHandshakeDoesNotUseAppCommandsOrTelemetry() {
        XCTAssertEqual(HandshakePlan.operations(
            mode: .ota,
            capabilities: DeviceCapabilities(features: [])
        ), [.settle, .discoverServices, .otaInfo, .publishSnapshot, .connected])
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
        let peripheralID = UUID()
        var lifecycle = BLESessionLifecycleStateMachine()
        var callbacks = BLEBridgeCallbackStateMachine()

        let cancelled = callbacks.beginConnection(peripheralID: peripheralID)
        XCTAssertTrue(lifecycle.beginConnection(scope: cancelled))
        XCTAssertTrue(lifecycle.didConnect(scope: cancelled))
        callbacks.expectWrite(scope: cancelled, characteristic: .ota, followedByRead: true)
        XCTAssertTrue(lifecycle.beginTeardown(scope: cancelled))
        XCTAssertEqual(callbacks.didDisconnect(scope: cancelled), .accepted)
        XCTAssertEqual(lifecycle.didDisconnect(scope: cancelled), .accepted)

        let current = callbacks.beginConnection(peripheralID: peripheralID)
        XCTAssertTrue(lifecycle.beginConnection(scope: current))
        XCTAssertTrue(lifecycle.didConnect(scope: current))
        callbacks.expectWrite(scope: current, characteristic: .ota, followedByRead: true)

        XCTAssertEqual(callbacks.didWrite(scope: cancelled, characteristic: .ota), .ignored)
        XCTAssertEqual(callbacks.didUpdate(scope: cancelled, characteristic: .ota), .ignored)
        XCTAssertEqual(callbacks.didWrite(scope: current, characteristic: .ota), .accepted)
        XCTAssertEqual(callbacks.didUpdate(scope: current, characteristic: .ota), .accepted)
        XCTAssertTrue(lifecycle.didFinishSetup(scope: current))
    }
}

private extension HandshakeOperation {
    var isTelemetry: Bool {
        switch self {
        case .readTelemetry, .subscribe: true
        default: false
        }
    }
}
