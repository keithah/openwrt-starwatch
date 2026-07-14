@testable import WattlineCore
import XCTest

final class CapabilityResolverTests: XCTestCase {
    func testFeaturesAreAuthoritativeOverLP2CID() {
        let value = CapabilityResolver.resolve(
            features: [.dcPort, .dcControl],
            cid: 0x0305,
            model: "BP4SL3V2"
        )

        XCTAssertFalse(value.hasBattery)
        XCTAssertFalse(value.hasUSBPort)
        XCTAssertTrue(value.hasDCControl)
    }

    func testEmptyFeaturesAuthoritativelyRemoveCIDAndModelCapabilities() {
        let value = CapabilityResolver.resolve(features: [], cid: 0x0305, model: "BP4SL3V2")

        assertNoPresentationCapabilities(value)
    }

    func testEachFeatureBitMapsOnlyToItsPresentationGate() {
        let cases: [(FeatureFlags, UInt32, KeyPath<DeviceCapabilities, Bool>, String)] = [
            (.factoryMode, 1 << 1, \.hasFactoryMode, "factory mode"),
            (.shutdown, 1 << 3, \.canShutdown, "shutdown"),
            (.batteryCapacity, 1 << 4, \.hasBattery, "battery"),
            (.dcPort, 1 << 5, \.hasDCPort, "DC port"),
            (.dcControl, 1 << 6, \.hasDCControl, "DC control"),
            (.dcScheduler, 1 << 7, \.hasScheduler, "scheduler"),
            (.usbPort, 1 << 8, \.hasUSBPort, "USB port"),
            (.usbPowerLimit, 1 << 9, \.hasPowerLimits, "power limits"),
            (.usbOutputControl, 1 << 10, \.hasUSBOutputControl, "USB output control"),
            (.dcBypass, 1 << 11, \.hasBypass, "bypass"),
            (.dcBypassControl, 1 << 12, \.hasBypassControl, "bypass control"),
            (.usbDCInput, 1 << 13, \.showsDCInput, "DC input"),
            (.usbDCInputPower, 1 << 14, \.showsDCInputPower, "DC input power"),
        ]

        for (index, item) in cases.enumerated() {
            let value = CapabilityResolver.resolve(features: item.0, cid: nil, model: nil)

            XCTAssertEqual(item.0.rawValue, item.1, "wrong protocol bit for \(item.3)")
            XCTAssertTrue(value[keyPath: item.2], "missing gate for \(item.3)")
            for (otherIndex, other) in cases.enumerated() where otherIndex != index {
                XCTAssertFalse(
                    value[keyPath: other.2],
                    "\(item.3) unexpectedly enables \(other.3)"
                )
            }
        }
    }

    func testDisplayAndSleepBitsRemainRepresentable() {
        let flags: FeatureFlags = [.display, .sleep]

        XCTAssertEqual(flags.rawValue, 0x0000_0005)
        XCTAssertTrue(flags.contains(.display))
        XCTAssertTrue(flags.contains(.sleep))
        assertNoPresentationCapabilities(
            CapabilityResolver.resolve(features: flags, cid: nil, model: nil)
        )
    }

    func testCIDFallbackSeparatesLPPFromLPFamilies() {
        let lp1 = CapabilityResolver.resolve(features: nil, cid: 0x01FF, model: nil)
        let lpp = CapabilityResolver.resolve(features: nil, cid: 0x02FF, model: nil)
        let lp2 = CapabilityResolver.resolve(features: nil, cid: 0x03FF, model: nil)

        assertLPFamilyFallback(lp1)
        assertDCOnlyFallback(lpp)
        assertLPFamilyFallback(lp2)
    }

    func testUnknownCIDModelByteDoesNotUseModelStringFallback() {
        let value = CapabilityResolver.resolve(features: nil, cid: 0x9901, model: "BP4SL3V2")

        assertNoPresentationCapabilities(value)
    }

    func testLegacyModelStringFallbacks() {
        assertLPFamilyFallback(
            CapabilityResolver.resolve(features: nil, cid: nil, model: "BP4SL3V1")
        )
        assertLPFamilyFallback(
            CapabilityResolver.resolve(features: nil, cid: nil, model: "PK-LINK-POWER-1")
        )
        assertDCOnlyFallback(
            CapabilityResolver.resolve(features: nil, cid: nil, model: "BP4SL3")
        )
        assertLPFamilyFallback(
            CapabilityResolver.resolve(features: nil, cid: nil, model: "BP4SL3V2")
        )
    }

    func testUnknownOrMissingIdentityHasNoCapabilities() {
        assertNoPresentationCapabilities(
            CapabilityResolver.resolve(features: nil, cid: nil, model: "UNKNOWN")
        )
        assertNoPresentationCapabilities(
            CapabilityResolver.resolve(features: nil, cid: nil, model: nil)
        )
    }

    private func assertLPFamilyFallback(
        _ value: DeviceCapabilities,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(value.hasBattery, file: file, line: line)
        XCTAssertTrue(value.hasDCPort, file: file, line: line)
        XCTAssertTrue(value.hasDCControl, file: file, line: line)
        XCTAssertTrue(value.hasUSBPort, file: file, line: line)
        XCTAssertTrue(value.hasPowerLimits, file: file, line: line)
        XCTAssertTrue(value.hasUSBOutputControl, file: file, line: line)
        XCTAssertFalse(value.hasScheduler, file: file, line: line)
        XCTAssertFalse(value.hasBypass, file: file, line: line)
        XCTAssertFalse(value.hasBypassControl, file: file, line: line)
        XCTAssertFalse(value.showsDCInput, file: file, line: line)
        XCTAssertFalse(value.showsDCInputPower, file: file, line: line)
        XCTAssertFalse(value.hasFactoryMode, file: file, line: line)
        XCTAssertFalse(value.canShutdown, file: file, line: line)
    }

    private func assertDCOnlyFallback(
        _ value: DeviceCapabilities,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(value.hasDCPort, file: file, line: line)
        XCTAssertTrue(value.hasDCControl, file: file, line: line)
        XCTAssertFalse(value.hasBattery, file: file, line: line)
        XCTAssertFalse(value.hasUSBPort, file: file, line: line)
        XCTAssertFalse(value.hasUSBOutputControl, file: file, line: line)
        XCTAssertFalse(value.hasPowerLimits, file: file, line: line)
    }

    private func assertNoPresentationCapabilities(
        _ value: DeviceCapabilities,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let gates: [(KeyPath<DeviceCapabilities, Bool>, String)] = [
            (\.hasFactoryMode, "factory mode"),
            (\.canShutdown, "shutdown"),
            (\.hasBattery, "battery"),
            (\.hasDCPort, "DC port"),
            (\.hasDCControl, "DC control"),
            (\.hasScheduler, "scheduler"),
            (\.hasUSBPort, "USB port"),
            (\.hasPowerLimits, "power limits"),
            (\.hasUSBOutputControl, "USB output control"),
            (\.hasBypass, "bypass"),
            (\.hasBypassControl, "bypass control"),
            (\.showsDCInput, "DC input"),
            (\.showsDCInputPower, "DC input power"),
        ]

        for (gate, name) in gates {
            XCTAssertFalse(value[keyPath: gate], "unexpected \(name)", file: file, line: line)
        }
    }
}
