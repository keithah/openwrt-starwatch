import SwiftUI
import WattlineNetwork

struct GoodCloudDevicePresentation: Equatable {
    let name: String
    let model: String
    let mac: String
    let ddns: String?
    let status: String
    let badge: String?
    let isSelectable: Bool

    init(device: GoodCloudDeviceSummary, isSuggested: Bool) {
        name = device.name
        model = device.model
        mac = Self.formattedMAC(device.mac)
        ddns = device.ddns
        status = device.isOnline ? "Online" : "Offline"
        badge = isSuggested ? "Suggested" : nil
        isSelectable = device.isOnline
    }

    static func formattedMAC(_ value: String) -> String {
        guard let compact = DeviceIdentityDeduplicator.normalizedMAC(value), compact.count == 12 else {
            return value.uppercased()
        }
        return stride(from: 0, to: compact.count, by: 2)
            .map { offset in
                let start = compact.index(compact.startIndex, offsetBy: offset)
                let end = compact.index(start, offsetBy: 2)
                return String(compact[start..<end])
            }
            .joined(separator: ":")
    }
}

struct GoodCloudDevicePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDevice: GoodCloudDeviceSummary?
    @State private var showsAssociationError = false

    let model: GoodCloudSettingsModel

    var body: some View {
        NavigationStack {
            List(model.devices) { device in
                let row = GoodCloudDevicePresentation(
                    device: device,
                    isSuggested: model.suggestedDevice?.id == device.id
                )
                Button {
                    pendingDevice = device
                } label: {
                    deviceRow(row)
                }
                .buttonStyle(.plain)
                .disabled(!row.isSelectable)
            }
            .overlay {
                if model.devices.isEmpty {
                    ContentUnavailableView(
                        "No GoodCloud routers",
                        systemImage: "network.slash",
                        description: Text("Routers bound to your GoodCloud account appear here.")
                    )
                }
            }
            .navigationTitle("Choose Router")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .confirmationDialog(
            "Use this GoodCloud router?",
            isPresented: Binding(
                get: { pendingDevice != nil },
                set: { if !$0 { pendingDevice = nil } }
            ),
            presenting: pendingDevice
        ) { device in
            Button("Use \(device.name)") { associate(device) }
            Button("Cancel", role: .cancel) { pendingDevice = nil }
        } message: { device in
            Text("Wattline will use \(device.name) for remote access to the saved router. This does not change LAN or Bluetooth access.")
        }
        .alert("Couldn’t associate router", isPresented: $showsAssociationError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Remote access is unavailable. Please try again.")
        }
    }

    @ViewBuilder
    private func deviceRow(_ row: GoodCloudDevicePresentation) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .foregroundStyle(row.isSelectable ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(row.name).font(.headline)
                    if let badge = row.badge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.15), in: Capsule())
                    }
                }
                Text(row.model).foregroundStyle(.secondary)
                Text(row.mac).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                if let ddns = row.ddns, !ddns.isEmpty {
                    Text(ddns).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(row.status)
                .font(.caption)
                .foregroundStyle(row.isSelectable ? .green : .secondary)
        }
        .contentShape(Rectangle())
    }

    private func associate(_ device: GoodCloudDeviceSummary) {
        pendingDevice = nil
        Task { @MainActor in
            do {
                try await model.associate(deviceID: device.id)
                dismiss()
            } catch {
                showsAssociationError = true
            }
        }
    }
}
