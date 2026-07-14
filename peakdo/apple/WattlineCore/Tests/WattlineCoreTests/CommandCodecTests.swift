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

    func testMismatchedEchoesFail() {
        let request = CommandRequest(command: .dcControl, action: .set, payload: [1])
        XCTAssertThrowsError(try CommandReply.decode(Data([0x02, 0x81, 0x00]), for: request))
        XCTAssertThrowsError(try CommandReply.decode(Data([0x01, 0x80, 0x00]), for: request))
    }
}
