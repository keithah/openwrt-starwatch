import Foundation
import WattlineCore
import XCTest
@testable import WattlineNetwork

final class DeviceIdentityDeduplicatorTests: XCTestCase {
    func testNormalizesMACCaseAndSeparatorsAndPrefersBluetooth() {
        let ble = identity(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", mac: "dc:04:5a:eb:72:2b", cid: 0x0302)
        let router = identity(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", mac: "DC-04-5A-EB-72-2B", cid: 0x0302)

        let merged = DeviceIdentityDeduplicator.merge(ble: ble, router: router)

        XCTAssertEqual(merged?.bluetoothIdentity, ble)
        XCTAssertEqual(merged?.routerIdentity, router)
        XCTAssertEqual(merged?.preferredTransport, .bluetooth)
        XCTAssertEqual(merged?.identity, ble)
        XCTAssertEqual(merged?.normalizedMAC, "DC045AEB722B")
    }

    func testFallsBackToCIDWhenMACCannotBeCompared() {
        let ble = identity(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", mac: nil, cid: 0x0302)
        let router = identity(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", mac: "DC:04:5A:EB:72:2B", cid: 0x0302)

        let merged = DeviceIdentityDeduplicator.merge(ble: ble, router: router)

        XCTAssertNotNil(merged)
        XCTAssertEqual(merged?.preferredTransport, .bluetooth)
    }

    func testDifferentValidMACsRemainDistinctEvenWhenCIDMatches() {
        let ble = identity(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", mac: "DC:04:5A:EB:72:2B", cid: 0x0302)
        let router = identity(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", mac: "DC:04:5A:EB:72:2C", cid: 0x0302)

        XCTAssertNil(DeviceIdentityDeduplicator.merge(ble: ble, router: router))
    }

    func testCIDMismatchAndMissingIdentifiersRemainDistinct() {
        let first = identity(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", mac: nil, cid: 0x0302)
        let second = identity(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", mac: nil, cid: 0x0102)
        let unidentified = identity(id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC", mac: "not-a-mac", cid: nil)

        XCTAssertNil(DeviceIdentityDeduplicator.merge(ble: first, router: second))
        XCTAssertNil(DeviceIdentityDeduplicator.merge(ble: unidentified, router: unidentified))
    }

    func testSingleTransportRecordRetainsItsAvailableTransport() {
        let router = identity(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", mac: "DC:04:5A:EB:72:2B", cid: 0x0302)

        let record = DeviceIdentityDeduplicator.merge(ble: nil, router: router)

        XCTAssertEqual(record?.preferredTransport, .router)
        XCTAssertEqual(record?.identity, router)
        XCTAssertNil(record?.bluetoothIdentity)
    }

    private func identity(id: String, mac: String?, cid: UInt16?) -> DeviceIdentitySnapshot {
        DeviceIdentitySnapshot(
            peripheralID: UUID(uuidString: id)!,
            advertisedName: "Wattline",
            mode: .application,
            cid: cid,
            rawFeatures: FeatureFlags.dcControl.rawValue,
            macAddress: mac,
            capabilities: DeviceCapabilities(features: [.dcControl])
        )
    }
}
