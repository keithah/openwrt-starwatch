import SwiftUI
import UIKit
import WattlineCore
import WattlineNetwork

struct ScanView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var showsRouterSetup = false

    var body: some View {
        NavigationStack {
            Group {
                if let issue = model.bluetoothIssue, model.routerConnections.savedHosts.isEmpty {
                    BluetoothExplainer(issue: issue) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    } demo: {
                        model.enterDemo()
                    }
                } else if model.sortedDevices.isEmpty && model.routerConnections.savedHosts.isEmpty {
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
                        } else if !model.sortedDevices.isEmpty {
                            Section("Nearby over Bluetooth") {
                                ForEach(model.sortedDevices) { device in
                                    Button {
                                        model.choose(device)
                                    } label: {
                                        DeviceRow(device: device, identity: model.knownDevices[device.id])
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        if !model.routerConnections.savedHosts.isEmpty {
                            Section("Advanced · Saved routers") {
                                ForEach(model.routerConnections.savedHosts) { host in
                                    Button {
                                        model.connectViaRouter(host)
                                    } label: {
                                        RouterHostRow(host: host)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .onDelete { offsets in
                                    let hosts = model.routerConnections.savedHosts
                                    Task {
                                        for index in offsets {
                                            try? await model.routerConnections.remove(hosts[index])
                                        }
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
                    Button("Demo") { model.enterDemo() }
                }
            }
            .sheet(isPresented: $showsRouterSetup) {
                RouterSetupView()
            }
            .sheet(item: Bindable(model).otaRecoveryDevice) { device in
                OTARecoveryView(device: device) {
                    model.otaRecoveryDevice = nil
                }
            }
        }
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
