import SwiftUI
import WattlineUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack(alignment: .bottom) {
            switch model.route {
            case .onboarding:
                OnboardingView()
            case .scan:
                ScanView()
            case .connected:
                ConnectedShellView()
            }

            if let message = model.toastMessage {
                ToastView(message: message)
                    .padding(.bottom, 72)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: model.toastMessage)
    }
}

private struct ConnectedShellView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            demoSurface {
                NavigationStack {
                    DashboardView()
                        .toolbar {
                            if !model.isDemo {
                                Button("Devices") { model.returnToScan() }
                            }
                        }
                }
            }
            .tabItem { Label("Home", systemImage: "house.fill") }

            demoSurface {
                NavigationStack { PlaceholderView(title: "Shortcuts", symbol: "wand.and.stars") }
            }
            .tabItem { Label("Shortcuts", systemImage: "square.grid.2x2") }

            demoSurface {
                NavigationStack {
                    SettingsView()
                }
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(.indigo)
    }

    private func demoSurface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .overlay(alignment: .topTrailing) {
                if model.isDemo {
                    DemoBadge()
                        .accessibilityLabel("DEMO")
                        .padding(.top, 8)
                        .padding(.trailing, 12)
                }
            }
    }
}
