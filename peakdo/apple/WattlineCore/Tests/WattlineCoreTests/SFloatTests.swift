@testable import WattlineCore
import XCTest

final class SFloatTests: XCTestCase {
    func testLiveThresholdVectorDecodesTwentyVolts() throws {
        let value = try XCTUnwrap(try SFloat.decode(Data([0xD0, 0xE7])).finiteValue)
        XCTAssertEqual(value, 20.0, accuracy: 0.0001)
    }

    func testSpecialValues() throws {
        XCTAssertEqual(try SFloat.decode(Data([0xFF, 0x07])), .nan)
        XCTAssertEqual(try SFloat.decode(Data([0xFE, 0x07])), .positiveInfinity)
        XCTAssertEqual(try SFloat.decode(Data([0x02, 0x08])), .negativeInfinity)
    }
}
