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

    private(set) var routerConnections: RouterConnectionModel
    private(set) var routerAdministration: RouterAdministrationModel
    let routerEnrollmentRoute: RouterEnrollmentRoute

    private(set) var started = false
    var isDemo = true

    init(
        transportFactory: @escaping TransportFactory,
        routerConnections: RouterConnectionModel? = nil,
        routerAdministration: RouterAdministrationModel? = nil,
        routerEnrollmentRoute: RouterEnrollmentRoute = RouterEnrollmentRoute()
    ) {
        let connections = routerConnections ?? .demo()
        self.transportFactory = transportFactory
        self.routerConnections = connections
        self.routerAdministration = routerAdministration ?? .demo(
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
        activateRealDeviceServices()
        start()
        isDemo = false
        routerConnections.startDiscovery()
        let transport = transport
        Task { try? await transport?.startScan() }
    }

    func acceptPairingURL(_ url: URL) {
        guard routerEnrollmentRoute.consume(url) else { return }
        activateRealDeviceServices()
        start()
        isDemo = false
        routerConnections.startDiscovery()
    }

    private func activateRealDeviceServices() {
        guard isDemo else { return }
        let connections = RouterConnectionModel.production()
        routerConnections = connections
        routerAdministration = .production(connections: connections)
    }
}
