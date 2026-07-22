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

    func testSharesInjectedGoodCloudSettingsWithoutAddingTransportOwner() {
        var constructions = 0
        let connections = RouterConnectionModel.demo()
        let remote = GoodCloudSettingsModel(
            account: nil,
            associations: nil,
            connections: connections
        )
        let model = MacAppModel(
            transportFactory: {
                constructions += 1
                return TestTransport()
            },
            routerConnections: connections,
            goodCloudSettings: remote
        )

        model.start()
        model.start()

        XCTAssertEqual(constructions, 1)
        XCTAssertTrue(model.goodCloudSettings === remote)
    }

    func testRealDeviceActivationReplacesRouterServicesOnceAndAdvancesGeneration() {
        let initialConnections = RouterConnectionModel.demo()
        let initialAdministration = RouterAdministrationModel.demo(
            connections: initialConnections
        )
        let realConnections = RouterConnectionModel.demo()
        let realAdministration = RouterAdministrationModel.demo(
            connections: realConnections
        )
        let realGoodCloudSettings = GoodCloudSettingsModel(
            account: nil,
            associations: nil,
            connections: realConnections
        )
        var serviceConstructions = 0
        let model = MacAppModel(
            transportFactory: { TestTransport() },
            routerConnections: initialConnections,
            routerAdministration: initialAdministration,
            routerServicesFactory: {
                serviceConstructions += 1
                return (realConnections, realAdministration, realGoodCloudSettings)
            }
        )

        model.connectRealDevice()
        model.connectRealDevice()

        XCTAssertEqual(serviceConstructions, 1)
        XCTAssertEqual(model.routerServicesGeneration, 1)
        XCTAssertTrue(model.routerConnections === realConnections)
        XCTAssertTrue(model.routerAdministration === realAdministration)
        XCTAssertTrue(model.goodCloudSettings === realGoodCloudSettings)
        XCTAssertFalse(model.isDemo)
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
