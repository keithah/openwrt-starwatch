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
}
