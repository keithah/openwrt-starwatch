import Foundation
import XCTest
@testable import WattlineCore

final class CurrentTimeCodecTests: XCTestCase {
    func testCurrentTimeRoundTripsTenByteStandardValue() throws {
        let calendar = Calendar(identifier: .gregorian)
        let date = Date(timeIntervalSince1970: 1_720_951_445.5)

        let bytes = CurrentTimeCodec.encode(date, calendar: calendar, adjustReason: 0)

        XCTAssertEqual(bytes.count, 10)
        XCTAssertEqual(
            try CurrentTimeCodec.decode(bytes, calendar: calendar).timeIntervalSince1970,
            date.timeIntervalSince1970,
            accuracy: 1.0 / 256.0
        )
    }

    func testCurrentTimeDecodeRejectsEveryTruncatedPrefix() {
        let valid = Data([0xEA, 0x07, 7, 15, 12, 34, 5, 2, 128, 0])

        for length in 0..<10 {
            XCTAssertThrowsError(try CurrentTimeCodec.decode(valid.prefix(length)))
        }
    }
}
