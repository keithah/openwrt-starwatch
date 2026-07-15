@preconcurrency import CoreBluetooth
import Foundation
import XCTest
@testable import WattlineCore

final class BluetoothDelegateBridgeTests: XCTestCase {
    func testOptionalReadGateDoesNoIOWhenCharacteristicIsAbsent() {
        let spy = OptionalReadSpy()

        let started = OptionalCharacteristicReadGate.beginRead(
            properties: nil,
            registerPendingRead: spy.registerPendingRead,
            readValue: spy.readValue
        )

        XCTAssertFalse(started)
        XCTAssertEqual(spy.pendingReadRegistrations, 0)
        XCTAssertEqual(spy.readValueCalls, 0)
    }

    func testOptionalReadGateDoesNoIOWhenCharacteristicIsWriteOnly() {
        let spy = OptionalReadSpy()

        let started = OptionalCharacteristicReadGate.beginRead(
            properties: [.write],
            registerPendingRead: spy.registerPendingRead,
            readValue: spy.readValue
        )

        XCTAssertFalse(started)
        XCTAssertEqual(spy.pendingReadRegistrations, 0)
        XCTAssertEqual(spy.readValueCalls, 0)
    }

    func testOptionalReadGateRegistersAndIssuesExactlyOneReadableIO() {
        let spy = OptionalReadSpy()

        let started = OptionalCharacteristicReadGate.beginRead(
            properties: [.read],
            registerPendingRead: spy.registerPendingRead,
            readValue: spy.readValue
        )

        XCTAssertTrue(started)
        XCTAssertEqual(spy.pendingReadRegistrations, 1)
        XCTAssertEqual(spy.readValueCalls, 1)
    }
}

private final class OptionalReadSpy {
    private(set) var pendingReadRegistrations = 0
    private(set) var readValueCalls = 0

    func registerPendingRead() {
        pendingReadRegistrations += 1
    }

    func readValue() {
        readValueCalls += 1
    }
}
