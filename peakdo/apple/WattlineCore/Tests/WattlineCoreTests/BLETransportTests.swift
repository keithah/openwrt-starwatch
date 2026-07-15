import Foundation
import XCTest
@testable import WattlineCore

final class BLETransportTests: XCTestCase {
    func testManualTimeSynchronizationEmitsManualAdjustmentReason() async throws {
        let capture = DeviceTimeWriteCapture()
        let date = Date(timeIntervalSince1970: 1_720_951_445.5)

        try await BLETransport.performManualTimeSynchronization(at: date) { bytes, uuid, policy in
            await capture.record(bytes: bytes, uuid: uuid, policy: policy)
        }

        let capturedWrite = await capture.write
        let write = try XCTUnwrap(capturedWrite)
        XCTAssertEqual(write.bytes.count, 10)
        XCTAssertEqual(write.bytes[9], 0)
        XCTAssertEqual(write.uuid, .currentTime)
        XCTAssertEqual(write.policy, .none)
    }
}

private actor DeviceTimeWriteCapture {
    private(set) var write: (bytes: Data, uuid: GATTUUID, policy: ExpectedDisconnectPolicy)?

    func record(bytes: Data, uuid: GATTUUID, policy: ExpectedDisconnectPolicy) {
        write = (bytes, uuid, policy)
    }
}
