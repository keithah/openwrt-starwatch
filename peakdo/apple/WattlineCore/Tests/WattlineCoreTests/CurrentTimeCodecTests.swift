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

    func testCurrentTimeDecodeRejectsOutOfRangeFieldsBeforeCalendarNormalization() {
        let malformedValues: [(field: String, index: Int, values: [UInt8])] = [
            ("month", 2, [0, 13]),
            ("day", 3, [0, 32]),
            ("hour", 4, [24]),
            ("minute", 5, [60]),
            ("second", 6, [60]),
            ("day of week", 7, [0, 8]),
        ]

        for malformed in malformedValues {
            for value in malformed.values {
                var bytes: [UInt8] = [0xEA, 0x07, 7, 15, 12, 34, 5, 2, 128, 0]
                bytes[malformed.index] = value

                XCTAssertThrowsError(
                    try CurrentTimeCodec.decode(Data(bytes)),
                    "Expected invalid \(malformed.field) value \(value) to be rejected"
                )
            }
        }
    }

    func testCurrentTimeDecodeAcceptsEveryFractions256Value() throws {
        for fractions in UInt8.min...UInt8.max {
            let bytes = Data([0xEA, 0x07, 7, 15, 12, 34, 5, 2, fractions, 0])
            XCTAssertNoThrow(
                try CurrentTimeCodec.decode(bytes),
                "Fractions256 is a uint8, so \(fractions) is in range"
            )
        }
    }
}
