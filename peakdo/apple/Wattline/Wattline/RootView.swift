import SwiftUI
import WattlineUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.route {
        case .onboarding:
            OnboardingView()
        case .scan:
            ScanView()
        case .connected:
            ConnectedShellView()
        }
    }
}

private struct ConnectedShellView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if model.isDemo {
                    DemoBadge()
                        .accessibilityLabel("DEMO")
                }

                Image(systemName: statusSymbol)
                    .font(.system(size: 52))
                    .foregroundStyle(.orange)

                Text(model.connectedName ?? "Wattline device")
                    .font(.title2.bold())

                switch model.connectionStatus {
                case .connected:
                    Text(model.isDemo ? "Demo telemetry is connected." : "Connected. Device details will appear after the identity handshake.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                case .reconnecting:
                    ProgressView("Reconnecting…")
                case let .disconnected(message):
                    VStack(spacing: 12) {
                        Text(message ?? "Device disconnected")
                            .foregroundStyle(.secondary)
                        if !model.isDemo {
                            Button("Reconnect") { model.retryConnection() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }

                Spacer()
            }
            .padding(28)
            .navigationTitle("Wattline")
            .toolbar {
                if !model.isDemo {
                    Button("Devices") { model.returnToScan() }
                }
            }
        }
    }

    private var statusSymbol: String {
        switch model.connectionStatus {
        case .connected: "bolt.circle.fill"
        case .reconnecting: "arrow.triangle.2.circlepath.circle"
        case .disconnected: "bolt.slash.circle"
        }
    }
}
