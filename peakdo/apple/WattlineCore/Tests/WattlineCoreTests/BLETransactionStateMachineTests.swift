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
