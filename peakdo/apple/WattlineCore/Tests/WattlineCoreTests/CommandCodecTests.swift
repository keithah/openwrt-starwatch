@testable import WattlineCore
import XCTest

final class CommandCodecTests: XCTestCase {
    func testFeaturesLiveReply() throws {
        let request = CommandRequest(command: .features, action: .get)
        let reply = try CommandReply.decode(Data([0xFE, 0x80, 0x00, 0xFF, 0x7F, 0x00, 0x00]), for: request)
        XCTAssertEqual(try reply.uint32Payload(), 0x0000_7FFF)
    }

    func testDeviceIDReversesMACBytes() throws {
        XCTAssertEqual(try DeviceID(reply: Data([0x10, 0x80, 0x00, 0x2B, 0x72, 0xEB, 0x5A, 0x04, 0xDC])).macAddress,
                       "DC:04:5A:EB:72:2B")
    }

    func testStandardPolicyRejectsNonzeroResult() {
        let request = CommandRequest(command: .features, action: .get)

        XCTAssertThrowsError(try CommandReply.decode(Data([0xFE, 0x80, 0xFD]), for: request)) { error in
            XCTAssertEqual(error as? CodecError, .rejectedResult(0xFD))
        }
    }

    func testRuntimeUnsetPolicyAcceptsSuccessAndUnsetWhilePreservingReply() throws {
        let request = CommandRequest(command: .typeCPowerLimit, action: .get, payload: [4])
        let success = try CommandReply.decode(
            Data([0x02, 0x80, 0x00, 0x04]),
            for: request,
            resultPolicy: .runtimeUnset
        )
        let unset = try CommandReply.decode(
            Data([0x02, 0x80, 0xFF, 0xA5]),
            for: request,
            resultPolicy: .runtimeUnset
        )

        XCTAssertEqual(success.result, 0x00)
        XCTAssertEqual(success.payload, Data([0x04]))
        XCTAssertEqual(unset.result, 0xFF)
        XCTAssertEqual(unset.payload, Data([0xA5]))
    }

    func testRuntimeUnsetPolicyRejectsOtherNonzeroResult() {
        let request = CommandRequest(command: .typeCPowerLimit, action: .get, payload: [4])

        XCTAssertThrowsError(
            try CommandReply.decode(
                Data([0x02, 0x80, 0xFD]),
                for: request,
                resultPolicy: .runtimeUnset
            )
        ) { error in
            XCTAssertEqual(error as? CodecError, .rejectedResult(0xFD))
        }
    }

    func testIgnoreForBypassMustBeExplicitToAcceptArbitraryResult() throws {
        let request = CommandRequest(command: .dcBypassControl, action: .set, payload: [1])
        let data = Data([0x14, 0x81, 0xFD, 0xA5])

        XCTAssertThrowsError(try CommandReply.decode(data, for: request)) { error in
            XCTAssertEqual(error as? CodecError, .rejectedResult(0xFD))
        }

        let reply = try CommandReply.decode(data, for: request, resultPolicy: .ignoreForBypass)
        XCTAssertEqual(reply.result, 0xFD)
        XCTAssertEqual(reply.payload, Data([0xA5]))
    }

    func testCommandEchoMismatchReportsExactError() {
        let request = CommandRequest(command: .dcControl, action: .set, payload: [1])

        XCTAssertThrowsError(try CommandReply.decode(Data([0x02, 0x81, 0x00]), for: request)) { error in
            XCTAssertEqual(error as? CodecError, .commandEchoMismatch(expected: 0x01, actual: 0x02))
        }
    }

    func testActionEchoMismatchReportsExactError() {
        let request = CommandRequest(command: .dcControl, action: .set, payload: [1])

        XCTAssertThrowsError(try CommandReply.decode(Data([0x01, 0x80, 0x00]), for: request)) { error in
            XCTAssertEqual(error as? CodecError, .actionEchoMismatch(expected: 0x81, actual: 0x80))
        }
    }

    func testTruncatedReplyAtEachPrefixBoundaryReportsExactError() {
        let request = CommandRequest(command: .features, action: .get)

        for data in [Data(), Data([0xFE]), Data([0xFE, 0x80])] {
            XCTAssertThrowsError(try CommandReply.decode(data, for: request)) { error in
                XCTAssertEqual(error as? CodecError, .truncated)
            }
        }
    }
}
