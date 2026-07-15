import SwiftUI
import UIKit
import WattlineCore

struct ScanView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Group {
                if let issue = model.bluetoothIssue {
                    BluetoothExplainer(issue: issue) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    } demo: {
                        model.enterDemo()
                    }
                } else if model.sortedDevices.isEmpty {
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
                    List(model.sortedDevices) { device in
                        Button {
                            model.choose(device)
                        } label: {
                            DeviceRow(device: device, identity: model.knownDevices[device.id])
                        }
                        .buttonStyle(.plain)
                    }
                    .refreshable { await model.refreshScan() }
                }
            }
            .navigationTitle("Devices")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Demo") { model.enterDemo() }
                }
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
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(device.localName).font(.headline)
                if device.mode == .ota {
                    Label("In firmware-update mode", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let identity {
                    Text(identity.macAddress.map { "\(identity.name) · \($0)" } ?? identity.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("New device")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            RSSIBars(rssi: device.rssi)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 5)
    }
}

private struct RSSIBars: View {
    let rssi: Int

    private var strength: Int {
        if rssi >= -54 { return 4 }
        if rssi >= -67 { return 3 }
        if rssi >= -78 { return 2 }
        return 1
    }

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
