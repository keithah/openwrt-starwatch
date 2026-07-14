import Foundation
import XCTest
@testable import WattlineCore

final class BLETransactionStateMachineTests: XCTestCase {
    func testCommandStateMachineWritesWithResponseBeforeRead() throws {
        var machine = BLETransactionStateMachine(command: Data([0x01, 0x01, 0x01]))

        XCTAssertEqual(try machine.start(), .writeWithResponse(characteristic: .command))
        XCTAssertEqual(try machine.didWrite(), .read(characteristic: .command))
    }

    func testCommandCompletesOnlyOnUpdateAfterRead() throws {
        var machine = BLETransactionStateMachine(command: Data([0x01, 0x01, 0x01]))
        _ = try machine.start()
        _ = try machine.didWrite()

        XCTAssertEqual(
            try machine.didUpdate(value: Data([0x01, 0x81, 0x00])),
            .complete(Data([0x01, 0x81, 0x00]))
        )
    }

    func testUpdateBeforeWriteAcknowledgementIsRejected() throws {
        var machine = BLETransactionStateMachine(command: Data([0x01, 0x01, 0x01]))
        _ = try machine.start()

        XCTAssertThrowsError(try machine.didUpdate(value: Data()))
    }

    func testCallbacksCannotCompleteTransactionTwice() throws {
        var machine = BLETransactionStateMachine(command: Data([0x01, 0x01, 0x01]))
        _ = try machine.start()
        _ = try machine.didWrite()
        _ = try machine.didUpdate(value: Data([0x01, 0x81, 0x00]))

        XCTAssertThrowsError(try machine.didUpdate(value: Data()))
        XCTAssertThrowsError(try machine.didWrite())
    }

    func testOldGenerationWriteAndUpdateCallbacksAreIgnoredAfterReconnect() {
        let peripheral = UUID()
        var machine = BLEBridgeCallbackStateMachine()
        let old = machine.beginConnection(peripheralID: peripheral)
        machine.expectWrite(scope: old, characteristic: .command, followedByRead: true)
        let current = machine.beginConnection(peripheralID: peripheral)
        machine.expectWrite(scope: current, characteristic: .command, followedByRead: true)

        XCTAssertEqual(machine.didWrite(scope: old, characteristic: .command), .ignored)
        XCTAssertEqual(machine.didWrite(scope: current, characteristic: .command), .accepted)
        XCTAssertEqual(machine.didUpdate(scope: old, characteristic: .command), .ignored)
        XCTAssertEqual(machine.didUpdate(scope: current, characteristic: .command), .accepted)
    }

    func testForeignPeripheralAndCharacteristicCallbacksCannotCompleteCurrentIO() {
        var machine = BLEBridgeCallbackStateMachine()
        let current = machine.beginConnection(peripheralID: UUID())
        let foreign = BLEConnectionScope(peripheralID: UUID(), generation: current.generation)
        machine.expectWrite(scope: current, characteristic: .command, followedByRead: true)

        XCTAssertEqual(machine.didWrite(scope: foreign, characteristic: .command), .ignored)
        XCTAssertEqual(machine.didWrite(scope: current, characteristic: .ota), .ignored)
        XCTAssertEqual(machine.didWrite(scope: current, characteristic: .command), .accepted)
    }

    func testOldDiscoveryCallbacksDoNotChangeNewGenerationCounters() {
        var machine = BLEBridgeCallbackStateMachine()
        let old = machine.beginConnection(peripheralID: UUID())
        machine.expectServiceDiscovery(scope: old)
        let current = machine.beginConnection(peripheralID: UUID())
        machine.expectServiceDiscovery(scope: current)

        XCTAssertEqual(machine.didDiscoverServices(scope: old), .ignored)
        XCTAssertEqual(machine.didDiscoverServices(scope: current), .accepted)
        machine.expectCharacteristicDiscoveries(scope: current, count: 2)
        XCTAssertEqual(machine.didDiscoverCharacteristics(scope: old), .ignored)
        XCTAssertEqual(machine.outstandingCharacteristicDiscoveries, 2)
        XCTAssertEqual(machine.didDiscoverCharacteristics(scope: current), .accepted)
        XCTAssertEqual(machine.outstandingCharacteristicDiscoveries, 1)
    }

    func testDisconnectInvalidatesOnlyMatchingGeneration() {
        var machine = BLEBridgeCallbackStateMachine()
        let old = machine.beginConnection(peripheralID: UUID())
        let current = machine.beginConnection(peripheralID: UUID())

        XCTAssertEqual(machine.didDisconnect(scope: old), .ignored)
        XCTAssertEqual(machine.activeScope, current)
        XCTAssertEqual(machine.didDisconnect(scope: current), .accepted)
        XCTAssertNil(machine.activeScope)
        XCTAssertEqual(machine.didDisconnect(scope: current), .ignored)
    }

    func testExpectedDisconnectAfterWriteCompletesWithCommandReconnectPolicy() {
        for command in [DeviceCommand.restart, .enterOTA, .shutdown] {
            let scope = BLEConnectionScope(peripheralID: UUID(), generation: 1)
            var machine = BLEExpectedDisconnectStateMachine(
                policy: command.disconnectPolicy,
                scope: scope
            )

            XCTAssertEqual(machine.didWrite(scope: scope), .waitingForDisconnect)
            XCTAssertEqual(
                machine.didDisconnect(scope: scope),
                .succeeded(command.disconnectPolicy.reconnectPolicy)
            )
        }
    }

    func testExpectedDisconnectBeforeWriteAcknowledgementAlsoCompletes() {
        for command in [DeviceCommand.restart, .enterOTA, .shutdown] {
            let scope = BLEConnectionScope(peripheralID: UUID(), generation: 1)
            var machine = BLEExpectedDisconnectStateMachine(
                policy: command.disconnectPolicy,
                scope: scope
            )

            XCTAssertEqual(
                machine.didDisconnect(scope: scope),
                .succeeded(command.disconnectPolicy.reconnectPolicy)
            )
            XCTAssertEqual(machine.didWrite(scope: scope), .ignored)
        }
    }

    func testOrdinaryCommandDisconnectFails() {
        let scope = BLEConnectionScope(peripheralID: UUID(), generation: 1)
        var machine = BLEExpectedDisconnectStateMachine(policy: .none, scope: scope)

        XCTAssertEqual(machine.didDisconnect(scope: scope), .failed)
    }

    func testForeignDisconnectCannotSucceedExpectedCommand() {
        let scope = BLEConnectionScope(peripheralID: UUID(), generation: 2)
        var machine = BLEExpectedDisconnectStateMachine(
            policy: .successThenReconnect,
            scope: scope
        )

        XCTAssertEqual(
            machine.didDisconnect(scope: BLEConnectionScope(
                peripheralID: scope.peripheralID,
                generation: 1
            )),
            .ignored
        )
        XCTAssertEqual(machine.didDisconnect(scope: scope), .succeeded(.armed))
    }

    func testCancellationAndTerminalCentralStateClearDisconnectExpectation() {
        let scope = BLEConnectionScope(peripheralID: UUID(), generation: 1)
        var cancelled = BLEExpectedDisconnectStateMachine(
            policy: .successThenReconnect,
            scope: scope
        )
        XCTAssertEqual(cancelled.cancel(scope: scope), .cancelled)
        XCTAssertEqual(cancelled.didDisconnect(scope: scope), .ignored)

        var poweredOff = BLEExpectedDisconnectStateMachine(
            policy: .successThenReconnect,
            scope: scope
        )
        XCTAssertEqual(poweredOff.centralUnavailable(scope: scope), .failed)
        XCTAssertEqual(poweredOff.didDisconnect(scope: scope), .ignored)
    }

    func testCentralStatePolicyFailsWorkForEveryTerminalOrResettingState() {
        for state in [
            BLECentralState.resetting,
            .poweredOff,
            .unauthorized,
            .unsupported,
        ] {
            XCTAssertEqual(
                BLECentralStatePolicy.resolution(for: state, hasActiveWork: true),
                .failActiveWork
            )
        }
        XCTAssertEqual(
            BLECentralStatePolicy.resolution(for: .unknown, hasActiveWork: true),
            .wait
        )
        XCTAssertEqual(
            BLECentralStatePolicy.resolution(for: .poweredOn, hasActiveWork: true),
            .ready
        )
    }

    func testRestorationStateDecisionsAreExplicit() {
        XCTAssertEqual(RestorationPolicy.action(for: .connected), .discoverServices)
        XCTAssertEqual(RestorationPolicy.action(for: .connecting), .awaitConnection)
        XCTAssertEqual(RestorationPolicy.action(for: .disconnected), .connect)
        XCTAssertEqual(RestorationPolicy.action(for: .disconnecting), .terminate)
    }

    func testExternalIOIsRejectedDuringSetupWithoutOverwritingSetupRead() {
        let scope = BLEConnectionScope(peripheralID: UUID(), generation: 1)
        var lifecycle = BLESessionLifecycleStateMachine()
        var callbacks = BLEBridgeCallbackStateMachine()
        let callbackScope = callbacks.beginConnection(peripheralID: scope.peripheralID)
        XCTAssertTrue(lifecycle.beginConnection(scope: callbackScope))
        XCTAssertTrue(lifecycle.didConnect(scope: callbackScope))
        callbacks.expectUpdate(scope: callbackScope, characteristic: .extendedBatteryInfo)

        XCTAssertEqual(
            lifecycle.externalIOAdmission(for: .command, scope: callbackScope),
            .notReady
        )
        XCTAssertEqual(
            lifecycle.externalIOAdmission(for: .refreshTelemetry, scope: callbackScope),
            .notReady
        )
        XCTAssertEqual(
            callbacks.didUpdate(scope: callbackScope, characteristic: .extendedBatteryInfo),
            .accepted
        )
    }

    func testExternalIOIsAllowedOnlyAfterSetupFinishes() {
        let scope = BLEConnectionScope(peripheralID: UUID(), generation: 1)
        var lifecycle = BLESessionLifecycleStateMachine()
        XCTAssertTrue(lifecycle.beginConnection(scope: scope))
        XCTAssertEqual(lifecycle.externalIOAdmission(scope: scope), .notReady)
        XCTAssertTrue(lifecycle.didConnect(scope: scope))
        XCTAssertEqual(lifecycle.externalIOAdmission(scope: scope), .notReady)
        XCTAssertTrue(lifecycle.didFinishSetup(scope: scope))
        XCTAssertEqual(lifecycle.externalIOAdmission(scope: scope), .allowed)
    }

    func testSetupFailureQuarantinesRetryUntilScopedDisconnect() {
        let old = BLEConnectionScope(peripheralID: UUID(), generation: 1)
        let retry = BLEConnectionScope(peripheralID: old.peripheralID, generation: 2)
        var lifecycle = BLESessionLifecycleStateMachine()
        XCTAssertTrue(lifecycle.beginConnection(scope: old))
        XCTAssertTrue(lifecycle.didConnect(scope: old))

        XCTAssertTrue(lifecycle.beginTeardown(scope: old))
        XCTAssertFalse(lifecycle.beginConnection(scope: retry))
        XCTAssertEqual(lifecycle.didDisconnect(scope: retry), .ignored)
        XCTAssertEqual(lifecycle.didDisconnect(scope: old), .accepted)
        XCTAssertTrue(lifecycle.beginConnection(scope: retry))
    }

    func testCancelledGenerationCallbacksCannotAffectReconnectedGeneration() {
        let peripheralID = UUID()
        var lifecycle = BLESessionLifecycleStateMachine()
        var callbacks = BLEBridgeCallbackStateMachine()

        let old = callbacks.beginConnection(peripheralID: peripheralID)
        XCTAssertTrue(lifecycle.beginConnection(scope: old))
        XCTAssertTrue(lifecycle.didConnect(scope: old))
        XCTAssertTrue(lifecycle.didFinishSetup(scope: old))
        callbacks.expectWrite(scope: old, characteristic: .command, followedByRead: true)

        XCTAssertTrue(lifecycle.beginTeardown(scope: old))
        XCTAssertEqual(callbacks.didDisconnect(scope: old), .accepted)
        XCTAssertEqual(lifecycle.didDisconnect(scope: old), .accepted)

        let current = callbacks.beginConnection(peripheralID: peripheralID)
        XCTAssertTrue(lifecycle.beginConnection(scope: current))
        XCTAssertTrue(lifecycle.didConnect(scope: current))
        XCTAssertTrue(lifecycle.didFinishSetup(scope: current))
        callbacks.expectWrite(scope: current, characteristic: .command, followedByRead: true)

        XCTAssertEqual(callbacks.didWrite(scope: old, characteristic: .command), .ignored)
        XCTAssertEqual(callbacks.didUpdate(scope: old, characteristic: .command), .ignored)
        XCTAssertEqual(callbacks.didDisconnect(scope: old), .ignored)
        XCTAssertEqual(callbacks.didWrite(scope: current, characteristic: .command), .accepted)
        XCTAssertEqual(callbacks.didUpdate(scope: current, characteristic: .command), .accepted)
    }
}

private extension ExpectedDisconnectPolicy {
    var reconnectPolicy: ReconnectPolicy {
        switch self {
        case .none, .successThenReconnect: .armed
        case .successThenAwaitOTAMode: .awaitingOTAMode
        case .successThenDisarmReconnect: .disarmed
        }
    }
}
