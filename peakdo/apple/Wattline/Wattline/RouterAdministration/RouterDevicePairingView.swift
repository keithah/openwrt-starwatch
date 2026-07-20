import SwiftUI
import WattlineUI

struct RouterDevicePairingView: View {
    @Bindable var model: RouterAdministrationModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedMAC: String?
    @State private var pin = ""

    private var rows: [RouterPairingRow] {
        RouterDevicePairingPresentation.rows(
            stage: model.devicePairingStatus?.stage.rawValue ?? "idle",
            devices: model.devicePairingStatus?.devices.map {
                RouterPairableDeviceValue(
                    mac: $0.mac, name: $0.name, rssi: $0.rssi, paired: $0.paired
                )
            } ?? []
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let status = model.devicePairingStatus {
                Text(RouterDevicePairingPresentation.statusText(
                    stage: status.stage.rawValue,
                    target: status.target,
                    error: status.error
                ))
                .foregroundStyle(.secondary)
            }

            ForEach(rows, id: \.mac) { row in
                HStack {
                    VStack(alignment: .leading) {
                        Text(row.title)
                        Text(row.detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if row.paired {
                        Button("Remove", role: .destructive) {
                            pin = ""
                            Task { await model.unpairLinkPower(mac: row.mac) }
                        }
                    } else {
                        Button("Select") { selectedMAC = row.mac }
                    }
                }
            }

            if let selectedMAC {
                SecureField("Optional six-digit BLE PIN", text: $pin)
                    .keyboardType(.numberPad)
                Button("Pair selected device") {
                    let submittedPIN = pin
                    pin = ""
                    Task { await model.pairLinkPower(mac: selectedMAC, pin: submittedPIN) }
                }
                .disabled(model.isDevicePairingRunning || (!pin.isEmpty && (pin.count != 6 || !pin.allSatisfy(\.isNumber))))
            }

            Button(model.isDevicePairingRunning ? "Working…" : "Scan for Link-Power") {
                pin = ""
                Task { await model.scanForLinkPower() }
            }
            .disabled(model.isDevicePairingRunning)

            if let error = model.devicePairingError {
                Text(error).foregroundStyle(.orange)
            }
        }
        .task { await model.refreshDevicePairing() }
        .onDisappear { pin = "" }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { pin = "" }
        }
    }
}
