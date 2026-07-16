@preconcurrency import CoreBluetooth
import Foundation
import XCTest
@testable import WattlineCore

final class BluetoothDelegateBridgeTests: XCTestCase {
    func testConnectionScopeAliasIsRemovedOnlyByFinalTerminalCleanup() {
        let local = BLEConnectionScope(peripheralID: UUID(), generation: 1)
        let transport = DeviceConnectionScope(peripheralID: local.peripheralID, sessionID: UUID())
        var aliases = ConnectionScopeAliases()

        aliases.register(transport, for: local)
        XCTAssertEqual(aliases[local], transport)
        XCTAssertEqual(aliases.scopeForTerminalEmission(local), transport)
        XCTAssertEqual(aliases[local], transport, "terminal emission still needs the alias")

        XCTAssertEqual(aliases.finishTerminalCleanup(local, path: .disconnect), transport)
        XCTAssertNil(aliases[local])
    }

    func testConnectionScopeAliasCleanupCoversFailureDisconnectAndTeardown() {
        var aliases = ConnectionScopeAliases()
        let paths: [ConnectionScopeAliases.TerminalPath] = [
            .connectionFailure,
            .disconnect,
            .teardown,
        ]
        let scopes = paths.enumerated().map {
            BLEConnectionScope(peripheralID: UUID(), generation: UInt64($0.offset + 1))
        }
        for (scope, path) in zip(scopes, paths) {
            aliases.register(
                DeviceConnectionScope(peripheralID: scope.peripheralID, sessionID: UUID()),
                for: scope
            )
            _ = aliases.scopeForTerminalEmission(scope)
            _ = aliases.finishTerminalCleanup(scope, path: path)
        }

        XCTAssertTrue(scopes.allSatisfy { aliases[$0] == nil })
    }

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
