import SwiftUI
import UIKit
import WattlineNetwork

struct RouterPairingModeView: View {
    @Environment(\.scenePhase) private var scenePhase
    let model: RouterAdministrationModel

    var body: some View {
        Group {
            if let status = model.pairingStatus, status.open {
                if let pin = status.pin {
                    LabeledContent("Pairing PIN") {
                        Text(pin)
                            .monospacedDigit()
                            .textSelection(.enabled)
                    }
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Expires \(status.expiresAt.formatted(date: .omitted, time: .standard))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .onChange(of: context.date) {
                            model.expirePairingSecretsIfNeeded()
                        }
                }
                if let png = model.pairingQRPNG,
                   let image = UIImage(data: png)
                {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(maxWidth: 240)
                        .accessibilityLabel("Router pairing QR code")
                    ShareLink(
                        item: Image(uiImage: image),
                        preview: SharePreview(
                            "Wattline pairing QR",
                            image: Image(uiImage: image)
                        )
                    )
                } else {
                    Button("Show pairing QR") {
                        Task { await model.loadPairingQR() }
                    }
                }
                Button("Close pairing", role: .destructive) {
                    Task { await model.closePairing() }
                }
            } else {
                Text("Pairing is closed. Opening it shows a six-digit PIN and QR for about five minutes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Open pairing") {
                    Task { await model.openPairing() }
                }
            }
            if let message = model.pairingError {
                Text(message).foregroundStyle(.orange)
            }
        }
        .task { await model.reloadPairingMode() }
        .onDisappear { model.clearPairingSecrets() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                model.clearPairingSecrets()
            }
        }
    }
}
