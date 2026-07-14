@testable import WattlineCore
import XCTest

final class TelemetryCodecTests: XCTestCase {
    func testSixteenByteBatteryFrameParsesDocumentedLayout() throws {
        let frame = Data([
            1, 0xFF, 1,
            0xF4, 0xF1,
            0xFA, 0xF0,
            50,
            0xD0, 0xE7,
            0x83, 0xEF,
            0x06, 0xFF,
            90, 0,
        ])

        let value = try BatteryStatus(frame: frame)

        XCTAssertTrue(value.enabled)
        XCTAssertEqual(value.status, .discharging)
        XCTAssertTrue(value.isFull)
        XCTAssertEqual(value.maxCapacity, 50.0, accuracy: 0.001)
        XCTAssertEqual(value.capacity, 25.0, accuracy: 0.001)
        XCTAssertEqual(value.level, 50)
        XCTAssertEqual(value.voltage, 20.0, accuracy: 0.001)
        XCTAssertEqual(value.current, -1.25, accuracy: 0.001)
        XCTAssertEqual(value.power, -25.0, accuracy: 0.001)
        XCTAssertEqual(value.remainingMinutes, 90)
    }

    func testBatteryFrameIgnoresTrailingBytes() throws {
        let frame = Data(repeating: 0, count: 16) + Data([0xAA, 0xBB])

        XCTAssertEqual(try BatteryStatus(frame: frame).remainingMinutes, 0)
    }

    func testElevenByteDCFrameParsesKnownPrefixAndIgnoresTrailer() throws {
        let frame = Data([1, 0, 0xC4, 0xF0, 0x13, 0xD0, 0x36, 0xC0, 1, 0, 0x7F])

        let value = try DCPortStatus(frame: frame)

        XCTAssertTrue(value.enabled)
        XCTAssertEqual(value.status, .idle)
        XCTAssertEqual(value.bypassOn, true)
        XCTAssertEqual(value.voltage, 19.6, accuracy: 0.001)
    }

    func testThirteenByteTypeCFrameUsesGapThenModeAndDCInput() throws {
        let frame = Data([1, 0, 0xB0, 0xE4, 0, 0, 0, 0, 0xFA, 0xF0, 0, 3, 0])

        let value = try TypeCPortStatus(frame: frame)

        XCTAssertEqual(value.temperature, 25.0, accuracy: 0.001)
        XCTAssertEqual(value.mode, .inputAndOutput)
        XCTAssertEqual(value.isDCInput, false)
    }

    func testTypeCFrameIgnoresTrailingBytes() throws {
        let frame = Data(repeating: 0, count: 13) + Data([0xAA, 0xBB])

        let value = try TypeCPortStatus(frame: frame)

        XCTAssertEqual(value.mode, .disabled)
        XCTAssertEqual(value.isDCInput, false)
    }

    func testOptionalFieldsAreAbsentWhenTheirBytesAreMissing() throws {
        let dc = try DCPortStatus(frame: Data(repeating: 0, count: 8))
        let tenByteTypeC = try TypeCPortStatus(frame: Data(repeating: 0, count: 10))
        let elevenByteTypeC = try TypeCPortStatus(frame: Data(repeating: 0, count: 11))
        let twelveByteTypeC = try TypeCPortStatus(frame: Data(repeating: 0, count: 12))

        XCTAssertNil(dc.bypassOn)
        XCTAssertNil(tenByteTypeC.mode)
        XCTAssertNil(tenByteTypeC.isDCInput)
        XCTAssertNil(elevenByteTypeC.mode)
        XCTAssertNil(elevenByteTypeC.isDCInput)
        XCTAssertEqual(twelveByteTypeC.mode, .disabled)
        XCTAssertNil(twelveByteTypeC.isDCInput)
    }

    func testTypeCGapByteDoesNotBecomeMode() throws {
        let value = try TypeCPortStatus(frame: Data(repeating: 0x03, count: 11))

        XCTAssertNil(value.mode)
        XCTAssertNil(value.isDCInput)
    }

    func testThirteenByteTypeCFrameDecodesNonzeroDCInputAsTrue() throws {
        var frame = Data(repeating: 0, count: 13)
        frame[12] = 0x7F

        XCTAssertEqual(try TypeCPortStatus(frame: frame).isDCInput, true)
    }

    func testPowerFlowValuesAndUnknownValueFallback() throws {
        let charging = try DCPortStatus(frame: Data([0, 1, 0, 0, 0, 0, 0, 0]))
        let discharging = try DCPortStatus(frame: Data([0, 0xFF, 0, 0, 0, 0, 0, 0]))
        let unknown = try DCPortStatus(frame: Data([0, 0x7F, 0, 0, 0, 0, 0, 0]))

        XCTAssertEqual(charging.status, .charging)
        XCTAssertEqual(discharging.status, .discharging)
        XCTAssertEqual(unknown.status, .idle)
    }

    func testFramesShorterThanDocumentedPrefixesAreTruncated() {
        assertTruncated { try BatteryStatus(frame: Data(repeating: 0, count: 15)) }
        assertTruncated { try DCPortStatus(frame: Data(repeating: 0, count: 7)) }
        assertTruncated { try TypeCPortStatus(frame: Data(repeating: 0, count: 9)) }
    }

    private func assertTruncated<T>(
        _ expression: () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual(error as? CodecError, .truncated, file: file, line: line)
        }
    }
}
