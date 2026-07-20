import SwiftUI
import WattlineUI

struct RouterAdvancedView: View {
    @Environment(\.scenePhase) private var scenePhase
    let model: RouterAdministrationModel

    @State private var thresholdText = ""
    @State private var selectedRunningMode: UInt8 = 0
    @State private var blePIN = ""
    @State private var confirmsRunningMode = false
    @State private var confirmsBLEPIN = false

    private var visibleSurfaces: [RouterAdvancedSurface] {
        RouterAdvancedSurface.allCases.filter(model.advancedVisibility.surfaces.contains)
    }

    var body: some View {
        Group {
            if model.isAdvancedLoading {
                Section("Advanced device") { ProgressView("Loading advanced controls…") }
            } else if model.advancedVisibility.showsEnableAdvancedAffordance {
                Section("Advanced device") {
                    NavigationLink {
                        Form { RouterSettingsView(model: model) }
                            .navigationTitle("Router Configuration")
                    } label: {
                        Label("Enable Advanced in Router Configuration", systemImage: "gearshape")
                    }
                }
            } else {
                ForEach(visibleSurfaces, id: \.self) { surface in
                    surfaceSection(surface)
                }
            }

            if let error = model.advancedError {
                Section { Text(error).foregroundStyle(.orange) }
            }
        }
        .task { await model.reloadAdvanced() }
        .onDisappear { blePIN = "" }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { blePIN = "" }
        }
        .onChange(of: confirmsBLEPIN) { wasPresented, isPresented in
            if wasPresented, !isPresented { blePIN = "" }
        }
        .onChange(of: model.advancedVisibility.surfaces.contains(.blePIN)) {
            wasVisible, isVisible in
            if RouterAdvancedSecretPolicy.shouldClearBLEPIN(
                wasVisible: wasVisible,
                isVisible: isVisible
            ) {
                blePIN = ""
                confirmsBLEPIN = false
            }
        }
        .onChange(of: model.settings?.advanced) { wasEnabled, isEnabled in
            if wasEnabled == false, isEnabled == true {
                Task { await model.reloadAdvanced() }
            }
        }
        .confirmationDialog(
            "Change Link-Power running mode?",
            isPresented: $confirmsRunningMode,
            titleVisibility: .visible
        ) {
            Button("Change running mode", role: .destructive) {
                let mode = selectedRunningMode
                Task { await model.setAdvancedRunningMode(mode, confirmation: .runningMode) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Changing running mode can interrupt the station's current operation.")
        }
        .confirmationDialog(
            "Change the Link-Power BLE PIN?",
            isPresented: $confirmsBLEPIN,
            titleVisibility: .visible
        ) {
            Button("Change BLE PIN", role: .destructive) {
                let pin = blePIN
                blePIN = ""
                Task { await model.setAdvancedBLEPIN(pin, confirmation: .blePIN) }
            }
            Button("Cancel", role: .cancel) { blePIN = "" }
        } message: {
            Text("Existing BLE clients may need the new six-digit PIN to reconnect.")
        }
    }

    @ViewBuilder
    private func surfaceSection(_ surface: RouterAdvancedSurface) -> some View {
        switch surface {
        case .bypassThreshold:
            Section("DC bypass threshold") {
                if let volts = model.advancedValues.bypassThresholdVolts {
                    LabeledContent("Observed", value: volts.formatted(.number.precision(.fractionLength(1))) + " V")
                        .fontDesign(.monospaced)
                }
                TextField("Volts", text: $thresholdText)
                    .keyboardType(.decimalPad)
                Button("Apply and read back") {
                    guard let volts = Double(thresholdText) else { return }
                    Task { await model.setAdvancedBypassThreshold(volts: volts) }
                }
                Button("Refresh") { Task { await model.loadAdvancedBypassThreshold() } }
            }
        case .clock:
            Section("Device clock") {
                if let clock = model.advancedValues.clock {
                    LabeledContent("Available", value: clock.available ? "Yes" : "No")
                    if let drift = clock.driftSeconds {
                        LabeledContent("Drift", value: "\(drift) s").fontDesign(.monospaced)
                    }
                }
                Button("Refresh") { Task { await model.loadAdvancedClock() } }
                Button("Sync now") { Task { await model.syncAdvancedClock() } }
            }
        case .runningMode:
            Section("Running mode") {
                if let observed = model.advancedValues.runningMode {
                    LabeledContent("Observed", value: observed == 0 ? "Normal" : "Factory")
                }
                Picker("Requested mode", selection: $selectedRunningMode) {
                    Text("Normal").tag(UInt8(0))
                    Text("Factory").tag(UInt8(1))
                }
                Button("Change running mode", role: .destructive) {
                    confirmsRunningMode = true
                }
            }
        case .barrierFree:
            Section("Barrier-free mode") {
                if let observed = model.advancedValues.barrierFreeEnabled {
                    Toggle("Enabled", isOn: Binding(
                        get: { observed },
                        set: { requested in Task { await model.setAdvancedBarrierFree(requested) } }
                    ))
                } else {
                    Button("Load status") { Task { await model.loadAdvancedBarrierFree() } }
                }
            }
        case .usbFirmware:
            Section("USB firmware") {
                if let firmware = model.advancedValues.usbFirmware {
                    LabeledContent("Version", value: firmware.displayVersion).fontDesign(.monospaced)
                    LabeledContent("Raw", value: firmware.raw).fontDesign(.monospaced)
                }
                Button("Refresh") { Task { await model.loadAdvancedUSBFirmware() } }
            }
        case .blePIN:
            Section("Link-Power BLE PIN") {
                SecureField("Six-digit PIN", text: $blePIN)
                    .keyboardType(.numberPad)
                    .textContentType(.password)
                Button("Change BLE PIN", role: .destructive) {
                    confirmsBLEPIN = true
                }
                .disabled(!isValidBLEPIN)
                if model.advancedValues.blePINUpdated == true {
                    Text("PIN updated on the Link-Power.").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var isValidBLEPIN: Bool {
        blePIN.utf8.count == 6 && blePIN.utf8.allSatisfy { (48...57).contains($0) }
    }
}
