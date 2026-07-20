import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import WattlineNetwork

struct RouterPairingModeView: View {
    @Environment(\.scenePhase) private var scenePhase
    let model: RouterAdministrationModel

    var body: some View {
        Group {
            switch model.pairingDisplayState {
            case .loading:
                ProgressView("Checking pairing status…")
            case .open:
                if let status = model.pairingStatus {
                    if let pin = status.pin {
                        LabeledContent("Pairing PIN") {
                            Text(pin)
                                .monospacedDigit()
                                .textSelection(.enabled)
                        }
                    }
                    Text("Expires \(status.expiresAt.formatted(date: .omitted, time: .standard))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if let png = model.pairingQRPNG {
                        RouterPairingQRCodeImage(data: png)
                    } else if model.isPairingQRLoading {
                        ProgressView("Loading pairing QR…")
                    } else {
                        Button("Show pairing QR") {
                            Task { await model.loadPairingQR() }
                        }
                    }
                    Button("Close pairing", role: .destructive) {
                        Task { await model.closePairing() }
                    }
                }
            case .closed:
                Text("Pairing is closed. Opening it shows a six-digit PIN and QR for about five minutes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Open pairing") {
                    Task { await model.openPairing() }
                }
            case .expired:
                Text("The pairing window expired. Open a new pairing window or refresh the router status.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Open new pairing") {
                    Task { await model.openPairing() }
                }
                Button("Refresh pairing status") {
                    Task { await model.reloadPairingMode() }
                }
            case .failed:
                Text("Pairing status is unavailable.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Refresh pairing status") {
                    Task { await model.reloadPairingMode() }
                }
            case .unknown:
                Text("Pairing status has not been checked.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Refresh pairing status") {
                    Task { await model.reloadPairingMode() }
                }
            }
            if let message = model.pairingError {
                Text(message).foregroundStyle(.orange)
            }
        }
        .task { await model.pairingDidBecomeActive() }
        .onDisappear { model.clearPairingSecrets() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.pairingDidBecomeActive() }
            } else {
                model.pairingDidEnterBackground()
            }
        }
    }
}

private struct RouterPairingQRCodeImage: View {
    let data: Data

    @ViewBuilder
    var body: some View {
        #if os(iOS)
        if let image = UIImage(data: data) {
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
        }
        #elseif os(macOS)
        if let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(maxWidth: 240)
                .accessibilityLabel("Router pairing QR code")
        }
        #endif
    }
}
