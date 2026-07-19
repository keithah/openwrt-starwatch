import SwiftUI
import UIKit
import WattlineCore
import WattlineNetwork

struct ScanView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var showsRouterSetup = false
    @State private var showsPairingEntry = false
    @State private var discoveredRouterSetup: DiscoveredRouter?
    @State private var administrationHost: RouterHostMetadata?

    private var scanRecords: [AppDeviceConnectionRecord] {
        model.routerConnections.scanRecords(
            bluetooth: model.sortedDevices,
            identities: model.knownDevices
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if let issue = model.bluetoothIssue, scanRecords.isEmpty {
                    BluetoothExplainer(issue: issue) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    } demo: {
                        model.enterDemo()
                    }
                } else if scanRecords.isEmpty {
                    ScrollView {
                        ContentUnavailableView {
                            Label("Looking for Wattline devices", systemImage: "antenna.radiowaves.left.and.right")
                        } description: {
                            Text("Keep your power station nearby and turned on.")
                        } actions: {
                            ProgressView()
                        }
                        .frame(maxWidth: .infinity, minHeight: 500)
                    }
                    .refreshable { await model.refreshScan() }
                } else {
                    List {
                        if model.bluetoothIssue != nil {
                            Section("Bluetooth") {
                                Label("Bluetooth unavailable", systemImage: "bluetooth.slash")
                                    .foregroundStyle(.secondary)
                                Button("Open Settings") {
                                    if let url = URL(string: UIApplication.openSettingsURLString) {
                                        openURL(url)
                                    }
                                }
                            }
                        }

                        Section("Nearby devices") {
                            ForEach(scanRecords) { record in
                                let presentation = ScanRecordPresentation(record: record)
                                HStack(spacing: 8) {
                                    Button {
                                        perform(presentation.primaryAction, record: record)
                                    } label: {
                                        UnifiedDeviceRow(record: record, presentation: presentation)
                                    }
                                    .buttonStyle(.plain)

                                    if presentation.offersRouterAction
                                        || presentation.offersRouterAdministration {
                                        Menu {
                                            if presentation.offersRouterAction {
                                                Button(record.routerHost == nil ? "Enroll with router" : "Connect via router") {
                                                    performRouterAction(record)
                                                }
                                            }
                                            if presentation.offersRouterAdministration,
                                               let host = record.routerHost {
                                                Button("Router administration") {
                                                    administrationHost = host
                                                }
                                            }
                                        } label: {
                                            Image(systemName: "ellipsis.circle")
                                                .font(.title3)
                                                .foregroundStyle(.secondary)
                                        }
                                        .accessibilityLabel("Router options for \(presentation.title)")
                                    }
                                }
                            }
                        }
                    }
                    .refreshable { await model.refreshScan() }
                }
            }
            .navigationTitle("Devices")
            .safeAreaInset(edge: .top) {
                if let message = model.scanMessage {
                    Text(message)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(10)
                        .background(.orange.opacity(0.15))
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if model.activeTransportKind == .router {
                        Button("BT") { model.requestBluetoothAfterPriming() }
                    }
                    Button("Router") { showsRouterSetup = true }
                    Button("Pair") { showsPairingEntry = true }
                    Button("Demo") { model.enterDemo() }
                }
            }
            .sheet(isPresented: $showsRouterSetup) {
                RouterSetupView()
            }
            .sheet(isPresented: $showsPairingEntry) {
                RouterPairingEntryView()
            }
            .sheet(item: $discoveredRouterSetup) { router in
                RouterEnrollmentView(router: router)
            }
            .sheet(item: $administrationHost) { host in
                RouterAdministrationView(host: host)
            }
            .sheet(isPresented: pairingPayloadPresented) {
                if let payload = model.routerEnrollmentRoute.payload {
                    RouterEnrollmentView(payload: payload)
                }
            }
            .sheet(item: Bindable(model).otaRecoveryDevice) { device in
                OTARecoveryView(device: device) {
                    model.otaRecoveryDevice = nil
                }
            }
            .onAppear { model.routerConnections.startDiscovery() }
            .onDisappear { model.routerConnections.stopDiscovery() }
        }
    }

    private var pairingPayloadPresented: Binding<Bool> {
        Binding(
            get: { model.routerEnrollmentRoute.payload != nil },
            set: { if !$0 { model.routerEnrollmentRoute.clear() } }
        )
    }

    private func perform(_ action: ScanPrimaryAction, record: AppDeviceConnectionRecord) {
        switch action {
        case .connectBluetooth:
            if let device = record.bluetoothDevice { model.choose(device) }
        case .connectRouter:
            if let host = record.routerHost { model.connectViaRouter(host) }
        case .enrollRouter:
            if let router = record.discoveredRouter { discoveredRouterSetup = router }
        }
    }

    private func performRouterAction(_ record: AppDeviceConnectionRecord) {
        if let host = record.routerHost {
            model.connectViaRouter(host)
        } else if let router = record.discoveredRouter {
            discoveredRouterSetup = router
        }
    }
}

enum ScanPrimaryAction: Equatable, Sendable {
    case connectBluetooth
    case connectRouter
    case enrollRouter
}

struct ScanRecordPresentation: Equatable, Sendable {
    let title: String
    let subtitle: String
    let transportLabels: [String]
    let primaryAction: ScanPrimaryAction
    let offersRouterAction: Bool
    let offersRouterAdministration: Bool

    init(record: AppDeviceConnectionRecord) {
        title = record.bluetoothDevice?.localName
            ?? record.routerHost?.displayName
            ?? record.discoveredRouter?.serviceName
            ?? "Wattline"
        if let host = record.routerHost {
            subtitle = "\(host.host):\(host.port)"
        } else if let router = record.discoveredRouter {
            subtitle = "\(router.endpoint.host):\(router.endpoint.port)"
        } else {
            subtitle = record.identity?.modelNumber ?? "Link-Power"
        }
        transportLabels = AppTransportKind.allCases.compactMap {
            record.transportOptions.contains($0) ? $0.label : nil
        }
        if record.bluetoothDevice != nil {
            primaryAction = .connectBluetooth
        } else if record.routerHost != nil {
            primaryAction = .connectRouter
        } else {
            primaryAction = .enrollRouter
        }
        offersRouterAction = record.bluetoothDevice != nil
            && (record.routerHost != nil || record.discoveredRouter != nil)
        offersRouterAdministration = record.routerHost != nil
    }
}

private struct UnifiedDeviceRow: View {
    let record: AppDeviceConnectionRecord
    let presentation: ScanRecordPresentation

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.bluetoothDevice == nil ? "network" : "battery.75percent")
                .foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.title).font(.headline)
                Text(presentation.subtitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 5) {
                ForEach(presentation.transportLabels, id: \.self) { label in
                    Text(label)
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.secondary.opacity(0.15), in: Capsule())
                }
            }
            if let device = record.bluetoothDevice {
                RSSIBars(strength: DeviceRowPresentation(
                    device: device,
                    identity: nil
                ).signalStrength)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 5)
    }
}

private struct DeviceRow: View {
    let device: DiscoveredDevice
    let identity: AppModel.CachedIdentity?

    var body: some View {
        let presentation = DeviceRowPresentation(device: device, identity: identity)
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(device.localName).font(.headline)
                if presentation.isOTARecovery {
                    Label("In firmware-update mode", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text(presentation.secondaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(AppTransportKind.bluetooth.label)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            RSSIBars(strength: presentation.signalStrength)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 5)
    }
}

private struct RouterHostRow: View {
    let host: RouterHostMetadata

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "network")
                .foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 3) {
                Text(host.displayName).font(.headline)
                Text("\(host.host):\(host.port)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(AppTransportKind.router.label)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 5)
    }
}

private struct RouterSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = "My router"
    @State private var address = ""
    @State private var deviceID = ""
    @State private var token = ""
    @State private var fingerprint = ""
    @State private var reachability = RouterHostReachability.lan
    @State private var allowsInsecureWAN = false
    @State private var errorMessage: String?
    @State private var isSaving = false
    let discoveredRouter: DiscoveredRouter?

    init(discoveredRouter: DiscoveredRouter? = nil) {
        self.discoveredRouter = discoveredRouter
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Connect via router") {
                    TextField("Name", text: $name)
                    TextField("Host or host:port", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Reachability", selection: $reachability) {
                        Text("LAN").tag(RouterHostReachability.lan)
                        Text("VPN / Tailscale").tag(RouterHostReachability.vpn)
                        Text("WAN").tag(RouterHostReachability.wan)
                    }
                    SecureField("Pairing bearer token", text: $token)
                    TextField("Device MAC (optional)", text: $deviceID)
                        .textInputAutocapitalization(.characters)
                    TextField("HTTPS certificate fingerprint", text: $fingerprint)
                        .textInputAutocapitalization(.characters)
                }

                if reachability == .wan {
                    Section("WAN security") {
                        Toggle("Allow insecure plain HTTP", isOn: $allowsInsecureWAN)
                        if allowsInsecureWAN {
                            Label(
                                "Traffic and the bearer token can be intercepted. Prefer HTTPS with a pinned fingerprint or a VPN.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(.orange)
                        }
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Advanced connection")
            .onAppear {
                guard let discoveredRouter else { return }
                name = discoveredRouter.serviceName
                address = "\(discoveredRouter.endpoint.scheme)://\(discoveredRouter.endpoint.host):\(discoveredRouter.endpoint.port)"
                deviceID = discoveredRouter.deviceID
                fingerprint = discoveredRouter.certificateFingerprint ?? ""
                reachability = .lan
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(address.isEmpty || token.isEmpty || isSaving)
                }
            }
        }
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        Task {
            do {
                _ = try await model.routerConnections.saveManualHost(
                    address: address,
                    displayName: name,
                    reachability: reachability,
                    allowsInsecureWAN: allowsInsecureWAN,
                    deviceID: deviceID.isEmpty ? nil : deviceID,
                    certificateFingerprint: fingerprint.isEmpty ? nil : fingerprint,
                    token: token
                )
                dismiss()
            } catch {
                errorMessage = String(describing: error)
                isSaving = false
            }
        }
    }
}

private struct RSSIBars: View {
    let strength: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { bar in
                Capsule()
                    .fill(bar <= strength ? Color.orange : Color.secondary.opacity(0.2))
                    .frame(width: 4, height: CGFloat(4 + bar * 4))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Signal strength \(strength) of 4")
    }
}

struct DeviceRowPresentation: Equatable {
    let secondaryText: String
    let signalStrength: Int
    let isOTARecovery: Bool

    init(device: DiscoveredDevice, identity: AppModel.CachedIdentity?) {
        isOTARecovery = device.mode == .ota
        secondaryText = identity.map { cached in
            cached.macAddress.map { "\(cached.name) · \($0)" } ?? cached.name
        } ?? "New device"
        signalStrength = Self.signalStrength(for: device.rssi)
    }

    private static func signalStrength(for rssi: Int) -> Int {
        if rssi >= -54 { return 4 }
        if rssi >= -67 { return 3 }
        if rssi >= -78 { return 2 }
        return 1
    }
}

private struct BluetoothExplainer: View {
    let issue: AppModel.BluetoothIssue
    let settings: () -> Void
    let demo: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "bluetooth.slash")
        } description: {
            Text(detail)
        } actions: {
            VStack(spacing: 10) {
                Button("Open Settings", action: settings).buttonStyle(.borderedProminent)
                Button("Try Demo Mode", action: demo).buttonStyle(.bordered)
            }
        }
    }

    private var title: String {
        switch issue {
        case .deniedOrRestricted: "Bluetooth access is off"
        case .unavailable: "Bluetooth is unavailable"
        }
    }

    private var detail: String {
        switch issue {
        case .deniedOrRestricted:
            "Allow Bluetooth for Wattline in Settings, or explore without a device in Demo Mode."
        case let .unavailable(message):
            "Wattline could not start scanning. \(message) You can try again later or use Demo Mode."
        }
    }
}

private struct OTARecoveryView: View {
    let device: DiscoveredDevice
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.orange)
                Text("Firmware recovery")
                    .font(.title.bold())
                Text("\(device.localName) is in firmware-update mode.")
                    .font(.headline)
                Text("Phase 1 can identify this recovery state but does not install firmware. Keep the device powered, then use the manufacturer’s update flow to finish recovery before reconnecting in Wattline.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Back to devices", action: dismiss)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
            .padding(28)
        }
    }
}
