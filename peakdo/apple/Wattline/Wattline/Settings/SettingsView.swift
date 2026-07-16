import SwiftUI
import WattlineCore
import WattlineUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            ForEach(composition.rows, id: \.self) { row in
                switch row {
                case .deviceInfo:
                    deviceInfoSection
                case .clock:
                    actionSection(title: "Device Clock") {
                        Label("Sync now", systemImage: "clock.arrow.circlepath")
                    }
                case .dcPort:
                    actionSection(title: "Power") {
                        settingsStatusRow(
                            title: "DC Port",
                            systemImage: "powerplug",
                            isOn: model.state.dc?.enabled == true
                        )
                    }
                case .bypass:
                    actionSection(title: "Bypass") {
                        settingsStatusRow(
                            title: "DC Bypass",
                            systemImage: "arrow.triangle.branch",
                            isOn: model.state.dc?.bypassOn == true
                        )
                    }
                case .restart:
                    actionSection(title: "Device") {
                        Label("Restart", systemImage: "arrow.clockwise")
                    }
                case .shutdown:
                    actionSection(title: "Safety") {
                        Label("Shut Down", systemImage: "power")
                            .foregroundStyle(.red)
                    }
                }
            }

            if model.isDemo {
                Section {
                    Button("Connect a real device") {
                        model.requestBluetoothAfterPriming()
                    }
                }
            }
        }
        .navigationTitle("Settings")
    }

    private var isConnected: Bool {
        model.connectionStatus == .connected
    }

    private var composition: SettingsComposition {
        SettingsComposition(
            capabilities: model.capabilities,
            isApplicationMode: model.state.identity?.mode == .application
        )
    }

    private var identityPresentation: SettingsIdentityPresentation {
        SettingsIdentityPresentation(
            identity: model.state.identity,
            isConnected: isConnected
        )
    }

    private var deviceInfoSection: some View {
        Section {
            if identityPresentation.rows.isEmpty {
                Text("Device information unavailable")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(identityPresentation.rows) { row in
                    LabeledContent(row.label, value: row.value)
                }
                .opacity(identityPresentation.isStale ? 0.55 : 1)
            }
        } header: {
            HStack {
                Text("Device Info")
                if identityPresentation.isStale {
                    Text("Cached")
                }
            }
        }
    }

    private func actionSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Section(title) {
            content()
                .foregroundStyle(isConnected ? .primary : .secondary)
        }
    }

    private func settingsStatusRow(
        title: String,
        systemImage: String,
        isOn: Bool
    ) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(isOn ? "On" : "Off")
                .foregroundStyle(.secondary)
        }
    }
}
