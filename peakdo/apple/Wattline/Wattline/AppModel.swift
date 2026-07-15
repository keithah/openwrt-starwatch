import CoreBluetooth
import Foundation
import Observation
import WattlineCore

@MainActor
@Observable
final class AppModel {
    enum Route {
        case onboarding
        case scan
        case connected
    }

    enum ConnectionStatus: Equatable {
        case connected
        case reconnecting
        case disconnected(String?)
    }

    enum BluetoothIssue: Equatable {
        case deniedOrRestricted
        case unavailable(String)
    }

    struct CachedIdentity: Codable, Equatable, Sendable {
        let name: String
        let macAddress: String?
    }

    struct KnownDevice: Codable, Equatable, Sendable {
        let identifier: UUID
        let identity: CachedIdentity
    }

    static let onboardingCompleteKey = "onboardingComplete"
    static let knownDevicesKey = "knownDevices"

    var route: Route
    var isDemo = false
    var discoveredDevices: [DiscoveredDevice] = []
    var bluetoothIssue: BluetoothIssue?
    var otaRecoveryDevice: DiscoveredDevice?
    var connectionStatus: ConnectionStatus = .disconnected(nil)
    var connectedName: String?

    private(set) var knownDevices: [UUID: CachedIdentity]
    private var transport: (any DeviceTransport)?
    private var eventTask: Task<Void, Never>?
    private var selectedDevice: DiscoveredDevice?

    init(defaults: UserDefaults = .standard) {
        let onboardingComplete = defaults.bool(forKey: Self.onboardingCompleteKey)
        route = onboardingComplete ? .scan : .onboarding
        if let data = defaults.data(forKey: Self.knownDevicesKey),
           let records = try? JSONDecoder().decode([KnownDevice].self, from: data) {
            knownDevices = Dictionary(uniqueKeysWithValues: records.map { ($0.identifier, $0.identity) })
        } else {
            knownDevices = [:]
        }

        if onboardingComplete {
            let ble = BLETransport()
            attach(transport: ble)
            startScanning()
        }
    }

    var sortedDevices: [DiscoveredDevice] {
        discoveredDevices.sorted { lhs, rhs in
            let lhsKnown = knownDevices[lhs.id] != nil
            let rhsKnown = knownDevices[rhs.id] != nil
            if lhsKnown != rhsKnown { return lhsKnown }
            if lhs.rssi != rhs.rssi { return lhs.rssi > rhs.rssi }
            return lhs.localName.localizedCaseInsensitiveCompare(rhs.localName) == .orderedAscending
        }
    }

    func enterDemo() {
        let demo = DemoTransport(seed: 0x57415454)
        isDemo = true
        connectedName = DemoTransport.identity.name
        connectionStatus = .connected
        attach(transport: demo)
        route = .connected

        Task {
            do {
                let identity = try await demo.connectDemo()
                connectedName = identity.name
            } catch {
                connectionStatus = .disconnected(String(describing: error))
            }
        }
    }

    func requestBluetoothAfterPriming() {
        UserDefaults.standard.set(true, forKey: Self.onboardingCompleteKey)
        isDemo = false
        bluetoothIssue = nil

        // Constructing this transport creates the CBCentralManager and is intentionally
        // reachable only after the explicit permission-priming action.
        let ble = BLETransport()
        attach(transport: ble)
        route = .scan
        startScanning()
    }

    func startScanning() {
        guard let transport else { return }
        bluetoothIssue = nil
        Task {
            do {
                try await transport.startScan()
            } catch {
                presentBluetoothFailure(error)
            }
        }
    }

    func refreshScan() async {
        guard let transport else { return }
        await transport.stopScan()
        discoveredDevices.removeAll()
        do {
            try await transport.startScan()
        } catch {
            presentBluetoothFailure(error)
        }
    }

    func choose(_ device: DiscoveredDevice) {
        if device.mode == .ota {
            otaRecoveryDevice = device
            return
        }
        selectedDevice = device
        connectedName = knownDevices[device.id]?.name ?? device.localName
        guard let transport else { return }
        Task {
            do {
                await transport.stopScan()
                try await transport.connect(to: device.id)
            } catch {
                connectionStatus = .disconnected(String(describing: error))
                route = .connected
            }
        }
    }

    func retryConnection() {
        guard let transport, let selectedDevice else { return }
        connectionStatus = .reconnecting
        Task {
            do {
                try await transport.connect(to: selectedDevice.id)
            } catch {
                connectionStatus = .disconnected(String(describing: error))
            }
        }
    }

    func returnToScan() {
        route = .scan
        connectionStatus = .disconnected(nil)
        startScanning()
    }

    /// Future DIS/MAC handshake code must call this only after it validates a device identity.
    /// A CoreBluetooth connection event alone deliberately does not persist identity data.
    func recordSuccessfulHandshake(deviceID: UUID, identity: CachedIdentity) {
        knownDevices[deviceID] = identity
        persistKnownDevices()
    }

    private func attach(transport: any DeviceTransport) {
        eventTask?.cancel()
        self.transport = transport
        let events = transport.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.receive(event)
            }
        }
    }

    private func receive(_ event: DeviceEvent) {
        switch event {
        case let .discovered(device):
            if let index = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
                discoveredDevices[index] = device
            } else {
                discoveredDevices.append(device)
            }
        case .connected:
            connectionStatus = .connected
            route = .connected
        case .reconnecting:
            connectionStatus = .reconnecting
            route = .connected
        case let .disconnected(failure):
            connectionStatus = .disconnected(failure?.message)
            if selectedDevice != nil || isDemo { route = .connected }
        case .battery, .dc, .typeC, .transactionDepth:
            break
        }
    }

    private func presentBluetoothFailure(_ error: any Error) {
        switch CBManager.authorization {
        case .denied, .restricted:
            bluetoothIssue = .deniedOrRestricted
        case .allowedAlways, .notDetermined:
            bluetoothIssue = .unavailable(String(describing: error))
        @unknown default:
            bluetoothIssue = .unavailable(String(describing: error))
        }
    }

    private func persistKnownDevices() {
        let records = knownDevices.map { KnownDevice(identifier: $0.key, identity: $0.value) }
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: Self.knownDevicesKey)
        }
    }
}
