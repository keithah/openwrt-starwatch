import Foundation
import Observation
import WattlineCore
import WattlineNetwork

@MainActor
@Observable
final class MacAppModel {
    typealias TransportFactory = @MainActor () -> any DeviceTransport

    private let transportFactory: TransportFactory
    private var transport: (any DeviceTransport)?
    private var session: DeviceSession?

    let routerConnections: RouterConnectionModel
    let routerAdministration: RouterAdministrationModel
    let routerEnrollmentRoute: RouterEnrollmentRoute

    private(set) var started = false
    var isDemo = true

    init(
        transportFactory: @escaping TransportFactory,
        routerConnections: RouterConnectionModel? = nil,
        routerAdministration: RouterAdministrationModel? = nil,
        routerEnrollmentRoute: RouterEnrollmentRoute = RouterEnrollmentRoute()
    ) {
        let connections = routerConnections ?? .production()
        self.transportFactory = transportFactory
        self.routerConnections = connections
        self.routerAdministration = routerAdministration ?? .production(
            connections: connections
        )
        self.routerEnrollmentRoute = routerEnrollmentRoute
    }

    static func production() -> MacAppModel {
        MacAppModel(transportFactory: { BLETransport() })
    }

    func start() {
        guard !started else { return }
        started = true
        let owner = transportFactory()
        transport = owner
        session = DeviceSession(transport: owner)
        let session = session
        Task { await session?.start() }
    }

    func connectRealDevice() {
        start()
        isDemo = false
        routerConnections.startDiscovery()
        let transport = transport
        Task { try? await transport?.startScan() }
    }

    func acceptPairingURL(_ url: URL) {
        guard routerEnrollmentRoute.consume(url) else { return }
        isDemo = false
    }
}
