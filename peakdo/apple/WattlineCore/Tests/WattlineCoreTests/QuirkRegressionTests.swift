@testable import WattlineCore
import XCTest

final class QuirkRegressionTests: XCTestCase {
    func testControlFactoriesEncodeExactProtocolBytes() {
        XCTAssertEqual(DeviceCommand.setDC(true).request.bytes, Data([0x01, 0x01, 0x01]))
        XCTAssertEqual(DeviceCommand.setTypeCOutput(false).request.bytes, Data([0x13, 0x01, 0x02, 0x00]))
        XCTAssertEqual(DeviceCommand.getPowerLimit(.output).request.bytes, Data([0x02, 0x00, 0x03]))
        XCTAssertEqual(DeviceCommand.setPowerLimit(.global, level: .watts140).request.bytes,
                       Data([0x02, 0x01, 0x01, 0x05]))
        XCTAssertEqual(DeviceCommand.setBypass(true).request.bytes, Data([0x14, 0x01, 0x01]))
        XCTAssertEqual(DeviceCommand.restart.request.bytes, Data([0x11, 0x01]))
        XCTAssertEqual(DeviceCommand.enterOTA.request.bytes, Data([0x50, 0x4B]))
        XCTAssertEqual(DeviceCommand.shutdown.request.bytes, Data([0x46, 0x4D]))
        XCTAssertEqual(DeviceCommand.runningMode(.factory).request.bytes, Data([0xE0, 0x01, 0x01]))
    }

    func testMagicWritesExposeTheirDestination() {
        XCTAssertEqual(DeviceCommand.enterOTA.request.target, .ota)
        XCTAssertEqual(DeviceCommand.shutdown.request.target, .factoryMode)
        XCTAssertEqual(DeviceCommand.restart.request.target, .command)
    }

    func testMutationsExposeConfirmationAndFollowUpPolicies() {
        XCTAssertEqual(DeviceCommand.setDC(true).reconciler, .dcEnabled(true))
        XCTAssertEqual(DeviceCommand.setTypeCOutput(false).timeout, .seconds(3))
        XCTAssertEqual(DeviceCommand.setPowerLimit(.input, level: .watts30).followUp, .getPowerLimit(.input))
    }

    func testPowerLimitClearNeverUsesTimerOpcode() {
        XCTAssertEqual(DeviceCommand.clearPowerLimit(.input).request.bytes, Data([0x02, 0x02, 0x02]))
        XCTAssertEqual(DeviceCommand.clearPowerLimit(.input).followUp, .getPowerLimit(.input))
    }

    func testTypeCReconcilesUsingModeNotEnabled() throws {
        let stillEnabledButOutputOff = try TypeCPortStatus(frame: typeCFrame(enabled: true, mode: .input))

        XCTAssertTrue(MutationReconciler.typeCOutput(false).matches(.typeC(stillEnabledButOutputOff)))
        XCTAssertFalse(MutationReconciler.typeCOutput(true).matches(.typeC(stillEnabledButOutputOff)))
    }

    func testBypassIgnoresResultAndWaitsForTelemetry() throws {
        let command = DeviceCommand.setBypass(true)
        let off = try DCPortStatus(frame: dcFrame(enabled: true, bypassOn: false))
        let on = try DCPortStatus(frame: dcFrame(enabled: true, bypassOn: true))

        XCTAssertEqual(command.timeout, .seconds(10))
        XCTAssertNoThrow(try command.validate(Data([0x14, 0x81, 0xFD])))
        XCTAssertFalse(command.reconciler.matches(.dc(off)))
        XCTAssertTrue(command.reconciler.matches(.dc(on)))
    }

    func testDisconnectAsSuccessPolicies() {
        XCTAssertEqual(DeviceCommand.restart.disconnectPolicy, .successThenReconnect)
        XCTAssertEqual(DeviceCommand.enterOTA.disconnectPolicy, .successThenAwaitOTAMode)
        XCTAssertEqual(DeviceCommand.shutdown.disconnectPolicy, .successThenDisarmReconnect)
    }

    func testDisconnectCommandsDoNotExpectReplies() {
        XCTAssertFalse(DeviceCommand.restart.expectsRead)
        XCTAssertFalse(DeviceCommand.enterOTA.expectsRead)
        XCTAssertFalse(DeviceCommand.shutdown.expectsRead)
    }

    func testRunningModeRequiresReply() {
        XCTAssertTrue(DeviceCommand.runningMode(.user).expectsRead)
        XCTAssertNoThrow(try DeviceCommand.runningMode(.user).validate(Data([0xE0, 0x81, 0x00])))
    }

    func testOnlyRuntimeAcceptsUnsetResult() {
        XCTAssertNoThrow(try DeviceCommand.getPowerLimit(.runtime).validate(Data([0x02, 0x80, 0xFF])))
        XCTAssertThrowsError(try DeviceCommand.getPowerLimit(.global).validate(Data([0x02, 0x80, 0xFF])))
    }

    private func dcFrame(enabled: Bool, bypassOn: Bool) -> Data {
        Data([enabled ? 1 : 0, 0, 0, 0, 0, 0, 0, 0, bypassOn ? 1 : 0])
    }

    private func typeCFrame(enabled: Bool, mode: TypeCPortMode) -> Data {
        Data([enabled ? 1 : 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, mode.rawValue])
    }
}
