import SwiftUI
import WattlineUI

private enum MacNavigationDestination: String, CaseIterable, Identifiable {
    case home = "Home"
    case shortcuts = "Shortcuts"
    case settings = "Settings"
    case routerAdministration = "Router Administration"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .home: "house"
        case .shortcuts: "bolt.badge.clock"
        case .settings: "gearshape"
        case .routerAdministration: "network"
        }
    }
}

struct MacRootView: View {
    let model: MacAppModel
    @State private var selection: MacNavigationDestination? = .home

    var body: some View {
        NavigationSplitView {
            List(MacNavigationDestination.allCases, selection: $selection) { destination in
                Label(destination.rawValue, systemImage: destination.symbol)
                    .tag(destination)
            }
            .navigationTitle("Wattline")
            .safeAreaInset(edge: .bottom) {
                if model.isDemo {
                    VStack(alignment: .leading, spacing: 8) {
                        DemoBadge()
                            .accessibilityIdentifier("demo.badge")
                            .accessibilityLabel("Demo mode")
                        Button("Connect a real device") {
                            model.connectRealDevice()
                        }
                        .accessibilityIdentifier("connect.real-device")
                        .accessibilityLabel("Connect a real device")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
            }
        } detail: {
            switch selection ?? .home {
            case .home:
                MacHomeView(model: model)
            case .shortcuts:
                MacShortcutsView()
            case .settings:
                MacSettingsView(model: model)
            case .routerAdministration:
                MacRouterAdministrationView(
                    model: model.routerAdministration,
                    connections: model.routerConnections,
                    enrollmentRoute: model.routerEnrollmentRoute,
                    servicesGeneration: model.routerServicesGeneration
                )
            }
        }
        .task {
            if model.routerEnrollmentRoute.payload != nil {
                selection = .routerAdministration
            }
        }
        .onChange(of: model.routerEnrollmentRoute.payload) { _, payload in
            if payload != nil { selection = .routerAdministration }
        }
    }
}

private struct MacHomeView: View {
    let model: MacAppModel

    var body: some View {
        ContentUnavailableView {
            Label(model.isDemo ? "Demo device" : "Select a device", systemImage: "bolt.fill")
        } description: {
            Text(model.isDemo
                 ? "Explore Wattline without connecting to hardware."
                 : "Wattline is looking for nearby and saved devices.")
        } actions: {
            if model.isDemo {
                Button("Connect a real device") { model.connectRealDevice() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("connect.real-device")
                    .accessibilityLabel("Connect a real device")
            }
        }
        .navigationTitle("Home")
    }
}

private struct MacShortcutsView: View {
    var body: some View {
        ContentUnavailableView(
            "Shortcuts",
            systemImage: "bolt.badge.clock",
            description: Text("Device actions become available after a real device connects.")
        )
        .navigationTitle("Shortcuts")
    }
}

private struct MacSettingsView: View {
    let model: MacAppModel

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Mode", value: model.isDemo ? "Demo" : "Real device")
                if model.isDemo {
                    Button("Connect a real device") { model.connectRealDevice() }
                        .accessibilityIdentifier("connect.real-device")
                        .accessibilityLabel("Connect a real device")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}
