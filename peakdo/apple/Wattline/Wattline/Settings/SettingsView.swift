import SwiftUI
import WattlineCore
import WattlineUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmShutdown = false
    @State private var confirmRestart = false

    var body: some View {
        List {
            ForEach(composition.rows, id: \.self) { row in
                switch row {
                case .deviceInfo:
                    deviceInfoSection
                case .clock:
                    actionSection(title: "Device Clock") {
                        Button {
                            Task { await model.syncClock() }
                        } label: {
                            Label("Sync now", systemImage: "clock.arrow.circlepath")
                        }
                        Text(model.clockStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .dcPort:
                    actionSection(title: "Power") {
                        settingsStatusRow(
                            title: "DC Port",
                            systemImage: "powerplug",
                            presentation: SettingsStatusPresentation(
                                value: model.state.dc?.enabled,
                                freshness: model.state.freshness
                            ),
                            isPending: isDCPending,
                            action: { model.setDC(!(model.state.dc?.enabled ?? false)) }
                        )
                    }
                case .bypass:
                    actionSection(title: "Bypass") {
                        settingsStatusRow(
                            title: "DC Bypass",
                            systemImage: "arrow.triangle.branch",
                            presentation: SettingsStatusPresentation(
                                value: model.state.dc?.bypassOn,
                                freshness: model.state.freshness
                            ),
                            isPending: isBypassPending,
                            action: { model.setBypass(!(model.state.dc?.bypassOn ?? false)) }
                        )
                    }
                case .restart:
                    actionSection(title: "Device") {
                        Button { confirmRestart = true } label: {
                            Label("Restart", systemImage: "arrow.clockwise")
                        }
                        .disabled(!isConnected || model.maintenanceState != .idle)
                        maintenanceStatus
                    }
                case .shutdown:
                    actionSection(title: "Safety") {
                        Button(role: .destructive) { confirmShutdown = true } label: {
                            Label("Shut Down", systemImage: "power")
                        }
                        .disabled(!isConnected || model.maintenanceState != .idle)
                    }
                case .systemSurfaces:
                    systemSurfacesSection
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
        .confirmationDialog("Shut down this device?", isPresented: $confirmShutdown) {
            Button("Shut Down", role: .destructive) {
                Task { await model.shutdownDevice() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Restart this device?", isPresented: $confirmRestart) {
            Button("Restart", role: .destructive) {
                Task { await model.restartDevice() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var isConnected: Bool {
        model.connectionStatus == .connected
    }

    @ViewBuilder
    private var maintenanceStatus: some View {
        switch model.maintenanceState {
        case .idle: EmptyView()
        case .restarting:
            Label("Restarting…", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case .shuttingDown:
            Label("Shutting down…", systemImage: "power")
                .foregroundStyle(.secondary)
        case let .restartFailed(message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).foregroundStyle(.red)
                Button("Retry") { Task { await model.retryRestart() } }
            }
        }
    }

    private var isDCPending: Bool {
        model.state.pendingMutations.contains { mutation in
            mutation.reconciler == .dcEnabled(true) || mutation.reconciler == .dcEnabled(false)
        }
    }

    private var isBypassPending: Bool {
        model.state.pendingMutations.contains { mutation in
            mutation.reconciler == .bypass(true) || mutation.reconciler == .bypass(false)
        }
    }

    private var composition: SettingsComposition {
        SettingsComposition(
            capabilities: model.capabilities,
            isApplicationMode: model.state.identity?.mode == .application
        )
    }

    @ViewBuilder
    private var systemSurfacesSection: some View {
        Section("System Surfaces") {
            Toggle("Live Activity while charging", isOn: Binding(
                get: { model.systemSurfacePreferences.liveActivityCharging },
                set: { model.setLiveActivityCharging($0) }
            ))
            Toggle("Live Activity while discharging", isOn: Binding(
                get: { model.systemSurfacePreferences.liveActivityDischarging },
                set: { model.setLiveActivityDischarging($0) }
            ))
            Toggle("Low-battery notifications", isOn: Binding(
                get: { model.systemSurfacePreferences.lowBatteryEnabled },
                set: { enabled in Task { _ = await model.setLowBatteryEnabled(enabled) } }
            ))
            if model.systemSurfacePreferences.lowBatteryEnabled {
                Stepper("Threshold \(model.systemSurfacePreferences.lowBatteryThreshold)%", value: Binding(
                    get: { model.systemSurfacePreferences.lowBatteryThreshold },
                    set: { model.setLowBatteryThreshold($0) }
                ), in: 1...99)
                .font(.system(.body, design: .monospaced))
            }
        }
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
                    LabeledContent(row.label) {
                        deviceInfoValue(row.value)
                    }
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
        presentation: SettingsStatusPresentation,
        isPending: Bool = false,
        action: (() -> Void)? = nil
    ) -> some View {
        Button(action: { action?() }) {
          HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(presentation.text)
                if presentation.isStale {
                    Text("Cached")
                        .font(.caption)
                }
                }
                .foregroundStyle(.secondary)
                .opacity(presentation.isStale ? 0.55 : 1)
            if isPending { ProgressView().controlSize(.small) }
          }
        }
        .buttonStyle(.plain)
        .disabled(!isConnected || isPending || action == nil)
    }

    private func deviceInfoValue(_ value: String) -> some View {
        Text(value)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.secondary)
    }
}
