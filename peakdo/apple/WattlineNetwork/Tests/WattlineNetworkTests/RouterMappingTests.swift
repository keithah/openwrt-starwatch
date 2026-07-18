import Foundation
import WattlineCore
import XCTest
@testable import WattlineNetwork

final class RouterMappingTests: XCTestCase {
    private let peripheralID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let wallClockOrigin = Date(timeIntervalSince1970: 1_752_739_200)

    private var scope: DeviceConnectionScope {
        DeviceConnectionScope(peripheralID: peripheralID, sessionID: sessionID)
    }

    private var mapping: RouterMapping {
        RouterMapping(
            peripheralID: peripheralID,
            timestampOrigin: RouterTimestampOrigin(
                wallClock: wallClockOrigin,
                deviceTimestamp: .seconds(40)
            )
        )
    }

    func testDecodesCanonicalDeviceIdentityAndMapsOTAMode() throws {
        let data = Data(#"""
        {
            "id": "DC:04:5A:EB:72:2B",
            "model": "BP4SL3V2",
            "hardware_revision": "V2",
            "application_firmware": "1.4.9",
            "ota_firmware": "1.0.3",
            "cid": 773,
            "features_raw": 32767,
            "features": {"display": true},
            "available": {"current_time": true, "ota": true, "dc": true, "usbc": true},
            "mode": "ota",
            "connection": {"connected": true, "phase": "bootloader", "reconnect": "bootloader"},
            "commands": {"active": [], "recent": []},
            "magic_dns_name": "wattline.example.ts.net",
            "future_additive_field": true
        }
        """#.utf8)

        let device = try JSONDecoder().decode(RouterDeviceDTO.self, from: data)
        XCTAssertEqual(device.model, "BP4SL3V2")
        XCTAssertEqual(device.hardwareRevision, "V2")
        XCTAssertEqual(device.applicationFirmware, "1.4.9")
        XCTAssertEqual(device.otaFirmware, "1.0.3")
        XCTAssertEqual(device.id, "DC:04:5A:EB:72:2B")
        XCTAssertEqual(device.cid, 773)
        XCTAssertEqual(device.featuresRaw, 32767)
        XCTAssertTrue(device.available.currentTime)

        let identity = try mapping.identity(device)
        XCTAssertEqual(identity.peripheralID, peripheralID)
        XCTAssertNil(identity.advertisedName)
        XCTAssertEqual(identity.mode, .ota)
        XCTAssertEqual(identity.modelNumber, "BP4SL3V2")
        XCTAssertEqual(identity.hardwareRevision, "V2")
        XCTAssertEqual(identity.otaFirmwareRevision, "1.0.3")
        XCTAssertEqual(identity.appFirmwareRevision, "1.4.9")
        XCTAssertEqual(identity.macAddress, "DC:04:5A:EB:72:2B")
        XCTAssertEqual(identity.cid, 773)
        XCTAssertEqual(identity.rawFeatures, 32767)
        XCTAssertEqual(identity.capabilities.features.rawValue, 0, "OTA mode must not expose app controls")
    }

    func testDecodesAndMapsFullTelemetryWithoutChangingValues() throws {
        let snapshot = try decodeSnapshot(#"""
        {
            "battery": {
                "enabled": true, "status": 1, "full": false,
                "max_wh": 99.5, "wh": 73.25, "level": 74,
                "volts": 20.8, "amps": 2.5, "watts": 52.0,
                "remain_min": 87
            },
            "dc": {
                "enabled": true, "status": -1, "volts": 19.59,
                "amps": -1.25, "watts": -24.4875, "bypass": true
            },
            "typec": {
                "enabled": true, "status": 1, "volts": 20.0,
                "amps": 3.0, "watts": 60.0, "temp_c": 33.2,
                "mode": 3, "dc_input": true
            },
            "connected": true,
            "updated_at": "2025-07-17T08:00:02.250Z"
        }
        """#)

        let events = try mapping.events(snapshot: snapshot, observedAt: .seconds(999))
        XCTAssertEqual(events.count, 3)

        guard case let .battery(battery, batteryTimestamp) = events[0] else {
            return XCTFail("expected battery event")
        }
        XCTAssertTrue(battery.enabled)
        XCTAssertEqual(battery.status, .charging)
        XCTAssertFalse(battery.isFull)
        XCTAssertEqual(battery.maxCapacity, 99.5)
        XCTAssertEqual(battery.capacity, 73.25)
        XCTAssertEqual(battery.level, 74)
        XCTAssertEqual(battery.voltage, 20.8)
        XCTAssertEqual(battery.current, 2.5)
        XCTAssertEqual(battery.power, 52.0)
        XCTAssertEqual(battery.remainingMinutes, 87)
        XCTAssertEqual(batteryTimestamp, .milliseconds(42_250))

        guard case let .dc(dc, dcTimestamp) = events[1] else {
            return XCTFail("expected DC event")
        }
        XCTAssertTrue(dc.enabled)
        XCTAssertEqual(dc.status, .discharging)
        XCTAssertEqual(dc.voltage, 19.59)
        XCTAssertEqual(dc.current, -1.25)
        XCTAssertEqual(dc.power, -24.4875)
        XCTAssertEqual(dc.bypassOn, true)
        XCTAssertEqual(dcTimestamp, batteryTimestamp)

        guard case let .typeC(typeC, typeCTimestamp) = events[2] else {
            return XCTFail("expected Type-C event")
        }
        XCTAssertTrue(typeC.enabled)
        XCTAssertEqual(typeC.status, .charging)
        XCTAssertEqual(typeC.voltage, 20.0)
        XCTAssertEqual(typeC.current, 3.0)
        XCTAssertEqual(typeC.power, 60.0)
        XCTAssertEqual(typeC.temperature, 33.2)
        XCTAssertEqual(typeC.mode, .inputAndOutput)
        XCTAssertEqual(typeC.isDCInput, true)
        XCTAssertEqual(typeCTimestamp, batteryTimestamp)
    }

    func testMissingPortsStayAbsentInsteadOfSynthesizingZeroTelemetry() throws {
        let snapshot = try decodeSnapshot(#"""
        {
            "battery": {
                "enabled": true, "status": -1, "full": false,
                "max_wh": 100, "wh": 50, "level": 50,
                "volts": 20, "amps": -1, "watts": -20,
                "remain_min": 120
            },
            "connected": true
        }
        """#)

        XCTAssertNil(snapshot.dc)
        XCTAssertNil(snapshot.typeC)
        let events = try mapping.events(snapshot: snapshot, observedAt: .seconds(77))
        XCTAssertEqual(events.count, 1)
        guard case let .battery(battery, timestamp) = events[0] else {
            return XCTFail("expected only battery telemetry")
        }
        XCTAssertEqual(battery.status, .discharging)
        XCTAssertEqual(timestamp, .seconds(77))
    }

    func testConnectedFalseIsRejectedInsteadOfCreatingTerminalLifecycle() throws {
        let snapshot = try decodeSnapshot(#"""
        {
            "connected": false,
            "dc": {
                "enabled": true, "status": -1, "volts": 19.5,
                "amps": -1, "watts": -19.5, "bypass": false
            },
            "updated_at": "2025-07-17T08:00:01Z"
        }
        """#)

        XCTAssertThrowsError(
            try mapping.events(snapshot: snapshot, observedAt: .seconds(999))
        ) { error in
            XCTAssertEqual(error as? RouterMappingError, .disconnectedSnapshot)
        }
    }

    func testUpdatedAtUsesInjectedOriginAndMissingTimestampUsesObservedAt() throws {
        let dated = try decodeSnapshot(#"""
        {
            "connected": true,
            "dc": {
                "enabled": false, "status": 0, "volts": 0,
                "amps": 0, "watts": 0, "bypass": false
            },
            "updated_at": "2025-07-17T08:00:00.125Z"
        }
        """#)
        let undated = try decodeSnapshot(#"""
        {
            "connected": true,
            "dc": {
                "enabled": false, "status": 0, "volts": 0,
                "amps": 0, "watts": 0, "bypass": false
            }
        }
        """#)

        let datedEvents = try mapping.events(snapshot: dated, observedAt: .seconds(999))
        let undatedEvents = try mapping.events(snapshot: undated, observedAt: .milliseconds(7_125))
        guard case let .dc(_, datedTimestamp) = datedEvents[0],
              case let .dc(_, undatedTimestamp) = undatedEvents[0] else {
            return XCTFail("expected DC telemetry")
        }
        XCTAssertEqual(datedTimestamp, .milliseconds(40_125))
        XCTAssertEqual(undatedTimestamp, .milliseconds(7_125))
    }

    func testUpdatedAtIsClampedAgainstFutureAndRegressingRouterClock() throws {
        let future = try decodeSnapshot(#"""
        {
            "connected": true,
            "dc": {"enabled": true, "status": -1, "volts": 20, "amps": -1, "watts": -20, "bypass": false},
            "updated_at": "2025-07-17T08:00:20Z"
        }
        """#)
        let regressed = try decodeSnapshot(#"""
        {
            "connected": true,
            "dc": {"enabled": true, "status": -1, "volts": 20, "amps": -1, "watts": -20, "bypass": false},
            "updated_at": "2025-07-17T07:59:59Z"
        }
        """#)

        let first = try mapping.events(snapshot: future, observedAt: .seconds(50))
        guard case let .dc(_, firstTimestamp) = first[0] else {
            return XCTFail("expected first DC telemetry")
        }
        let second = try mapping.events(
            snapshot: regressed,
            observedAt: .seconds(51),
            notBefore: firstTimestamp
        )
        guard case let .dc(_, secondTimestamp) = second[0] else {
            return XCTFail("expected second DC telemetry")
        }

        XCTAssertEqual(firstTimestamp, .seconds(50), "future router time must not outrun receipt time")
        XCTAssertEqual(secondTimestamp, firstTimestamp, "router clock rollback must not regress telemetry")
    }

    private func decodeSnapshot(_ json: String) throws -> RouterSnapshotDTO {
        try JSONDecoder().decode(RouterSnapshotDTO.self, from: Data(json.utf8))
    }
}
