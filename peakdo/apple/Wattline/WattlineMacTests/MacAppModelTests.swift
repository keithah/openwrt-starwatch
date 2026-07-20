import Foundation
import WattlineCore
import XCTest
@testable import WattlineMac

@MainActor
final class MacAppModelTests: XCTestCase {
    func testMacAppModelConstructsExactlyOneTransportOwner() {
        var constructions = 0
        let model = MacAppModel(transportFactory: {
            constructions += 1
            return TestTransport()
        })

        model.start()
        model.start()

        XCTAssertEqual(constructions, 1)
        XCTAssertTrue(model.started)
    }
}

private actor TestTransport: DeviceTransport {
    nonisolated let events = AsyncStream<DeviceEvent> { continuation in
        continuation.finish()
    }

    func startScan() async throws {}
    func stopScan() async {}
    func connect(to id: UUID, scope: DeviceConnectionScope) async throws {}
    func disconnect() async {}
    func perform(_ command: DeviceCommand) async throws -> CommandOutcome { .sent }
    func refreshTelemetry() async throws {}
    func synchronizeDeviceTime() async throws {}
    func readDeviceTimeIfSupported() async throws -> Date? { nil }
}
