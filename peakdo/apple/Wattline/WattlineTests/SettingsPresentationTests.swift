import Foundation
@testable import Wattline
import WattlineCore
import XCTest

final class SettingsPresentationTests: XCTestCase {
    func testIdentityRowsComeDirectlyFromHandshakeSnapshot() {
        let identity = DeviceIdentitySnapshot(
            peripheralID: UUID(),
            advertisedName: "Link-Power-2",
            mode: .application,
            modelNumber: "BP4SL3V2",
            hardwareRevision: "V5#0305",
            otaFirmwareRevision: "2.0.2",
            appFirmwareRevision: "1.4.9",
            cid: 0x0305,
            rawFeatures: 0,
            macAddress: "DC:04:5A:EB:72:2B",
            capabilities: DeviceCapabilities(features: [])
        )

        let value = SettingsIdentityPresentation(identity: identity, isConnected: true)

        XCTAssertEqual(value.rows, [
            .init(label: "Model", value: "BP4SL3V2"),
            .init(label: "Hardware / Variant", value: "V5#0305"),
            .init(label: "App Firmware", value: "1.4.9"),
            .init(label: "OTA Bootloader", value: "2.0.2"),
            .init(label: "MAC Address", value: "DC:04:5A:EB:72:2B"),
        ])
        XCTAssertFalse(value.isStale)
    }

    func testDisconnectedCachedIdentityIsMarkedStaleWithoutInventingMissingFields() {
        let identity = DeviceIdentitySnapshot(
            peripheralID: UUID(),
            advertisedName: "Link-Power-2",
            mode: .application,
            modelNumber: "BP4SL3V2",
            hardwareRevision: nil,
            otaFirmwareRevision: nil,
            appFirmwareRevision: "1.4.9",
            cid: nil,
            rawFeatures: nil,
            macAddress: nil,
            capabilities: DeviceCapabilities(features: [])
        )

        let value = SettingsIdentityPresentation(identity: identity, isConnected: false)

        XCTAssertEqual(value.rows, [
            .init(label: "Model", value: "BP4SL3V2"),
            .init(label: "App Firmware", value: "1.4.9"),
        ])
        XCTAssertTrue(value.isStale)
    }

    func testMissingAuthoritativeIdentityProducesNoDeviceInfoRows() {
        let value = SettingsIdentityPresentation(identity: nil, isConnected: true)

        XCTAssertTrue(value.rows.isEmpty)
        XCTAssertFalse(value.isStale)
    }
}
