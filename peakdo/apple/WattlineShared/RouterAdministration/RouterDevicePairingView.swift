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

    private var actions: RouterDevicePairingActions {
        RouterDevicePairingPresentation.actions(
            isOperationRunning: model.isDevicePairingRunning,
            stage: model.devicePairingStatus?.stage.rawValue ?? "idle",
            hasSelection: selectedMAC != nil
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
                    if row.paired, actions.showsUnpair {
                        Button("Remove", role: .destructive) {
                            pin = ""
                            Task { await model.unpairLinkPower(mac: row.mac) }
                        }
                    } else if !row.paired, actions.showsSelect {
                        Button("Select") { selectedMAC = row.mac }
                    }
                }
            }

            if let selectedMAC, actions.showsPair {
                SecureField("Optional BLE PIN (up to six digits)", text: $pin)
                    .routerNumberInput()
                Button("Pair selected device") {
                    let submittedPIN = pin
                    pin = ""
                    Task { await model.pairLinkPower(mac: selectedMAC, pin: submittedPIN) }
                }
                .disabled(!RouterDevicePairingPresentation.isValidPIN(pin))
            }

            if actions.showsScan {
                Button("Scan for Link-Power") {
                    pin = ""
                    Task { await model.scanForLinkPower() }
                }
            }

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
