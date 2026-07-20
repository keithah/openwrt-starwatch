import SwiftUI
import WattlineNetwork

struct MacRouterAdministrationView: View {
    let model: RouterAdministrationModel
    let connections: RouterConnectionModel
    let enrollmentRoute: RouterEnrollmentRoute

    @State private var selection: RouterHostMetadata.ID?
    @State private var administratorToken = ""
    @State private var enrollmentName = "Wattline Router"
    @State private var enrollmentLabel = "Wattline for Mac"
    @State private var enrollmentError: String?
    @State private var enrollmentAdapter: MacRouterEnrollmentAdapter

    init(
        model: RouterAdministrationModel,
        connections: RouterConnectionModel,
        enrollmentRoute: RouterEnrollmentRoute
    ) {
        self.model = model
        self.connections = connections
        self.enrollmentRoute = enrollmentRoute
        _enrollmentAdapter = State(
            initialValue: MacRouterEnrollmentAdapter(route: enrollmentRoute)
        )
    }

    private var selectedHost: RouterHostMetadata? {
        connections.savedHosts.first { $0.id == selection }
    }

    var body: some View {
        HSplitView {
            routerList
                .frame(minWidth: 220, idealWidth: 260)
            administrationDetail
                .frame(minWidth: 520)
        }
        .navigationTitle("Router Administration")
        .task {
            await connections.reloadSavedHosts()
            connections.startDiscovery()
            if selection == nil { selection = connections.savedHosts.first?.id }
        }
        .task(id: selection) {
            guard let selectedHost else {
                await model.end()
                return
            }
            await model.open(host: selectedHost)
        }
        .onDisappear {
            connections.stopDiscovery()
            Task { await model.end() }
        }
    }

    private var routerList: some View {
        List(selection: $selection) {
            Section("Saved routers") {
                ForEach(connections.savedHosts) { host in
                    VStack(alignment: .leading) {
                        Text(host.displayName)
                        Text("\(host.host):\(host.port)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(host.id)
                }
            }

            if !connections.discoveredRouters.isEmpty {
                Section("Nearby routers") {
                    ForEach(connections.discoveredRouters, id: \.deviceID) { router in
                        Label(router.serviceName, systemImage: "wifi")
                    }
                }
            }

            Section("Pair a router") {
                Button("Paste pairing link") { pastePairingLink() }
                Button("Import QR image") { importQRImage() }
                if enrollmentRoute.payload != nil {
                    Label("Pairing link ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                if let enrollmentError {
                    Text(enrollmentError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private var administrationDetail: some View {
        if let host = selectedHost {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    routerSummary(host)
                    historySection
                    linkPowerSection
                    administrationSection
                    if model.access == .unlocked {
                        administratorSections
                    }
                    rulesSection
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
            }
        } else if enrollmentRoute.payload != nil {
            enrollmentForm
        } else {
            ContentUnavailableView(
                "No router selected",
                systemImage: "network",
                description: Text("Select a saved router or import a pairing link.")
            )
        }
    }

    private func routerSummary(_ host: RouterHostMetadata) -> some View {
        GroupBox("Router") {
            Grid(alignment: .leading) {
                GridRow { Text("Name"); Text(host.displayName) }
                GridRow { Text("Address"); Text("\(host.host):\(host.port)").monospaced() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var historySection: some View {
        GroupBox("History") {
            HStack {
                Text(model.history.isEmpty
                     ? "No router history loaded."
                     : "\(model.history.count) recorded samples")
                Spacer()
                Button("Refresh history") { Task { await model.reloadHistory() } }
            }
        }
    }

    private var linkPowerSection: some View {
        GroupBox("Link-Power pairing") {
            HStack {
                Text(model.devicePairingStatus == nil
                     ? "Pairing status is not loaded."
                     : "Pairing status available")
                Spacer()
                Button("Refresh") { Task { await model.refreshDevicePairing() } }
            }
        }
    }

    private var administrationSection: some View {
        GroupBox("Administration") {
            if model.access == .unlocked {
                HStack {
                    Label("Unlocked", systemImage: "lock.open")
                    Spacer()
                    Button("Lock", role: .destructive) { Task { await model.lock() } }
                }
            } else {
                HStack {
                    SecureField("Administrator token", text: $administratorToken)
                    Button(model.access == .verifying ? "Verifying…" : "Unlock") {
                        let token = administratorToken
                        administratorToken = ""
                        Task { await model.unlock(token: token) }
                    }
                    .disabled(administratorToken.isEmpty || model.access == .verifying)
                }
            }
            if let error = model.adminError {
                Text(error).foregroundStyle(.orange)
            }
        }
    }

    private var administratorSections: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Client enrollment") {
                Text("Open or close the router pairing window for managed clients.")
            }
            GroupBox("API clients") {
                Text("\(model.tokens.count) managed clients")
            }
            GroupBox("Router Configuration") {
                Text(model.settings == nil
                     ? "Configuration has not been loaded."
                     : "Router configuration loaded.")
            }
            GroupBox("Advanced device") {
                Text("\(model.advancedVisibility.surfaces.count) controls available")
            }
        }
    }

    private var rulesSection: some View {
        GroupBox("Automation Rules") {
            HStack {
                Text("\(model.rules.count) rules")
                Spacer()
                Button("Refresh rules") { Task { await model.reloadRules() } }
            }
        }
    }

    private var enrollmentForm: some View {
        Form {
            Section("Client enrollment") {
                TextField("Router name", text: $enrollmentName)
                TextField("Client label", text: $enrollmentLabel)
                Button("Pair router") { enrollPairingLink() }
                    .buttonStyle(.borderedProminent)
                if let enrollmentError {
                    Text(enrollmentError).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func pastePairingLink() {
        do {
            try enrollmentAdapter.pastePairingLink()
            selection = nil
            enrollmentError = nil
        } catch {
            enrollmentError = "The clipboard does not contain a Wattline pairing link."
        }
    }

    private func importQRImage() {
        Task {
            do {
                try await enrollmentAdapter.importQRImage()
                selection = nil
                enrollmentError = nil
            } catch {
                enrollmentError = "The selected image does not contain a Wattline pairing QR code."
            }
        }
    }

    private func enrollPairingLink() {
        guard let payload = enrollmentRoute.payload else { return }
        Task {
            do {
                let host = try await connections.enroll(
                    payload: payload,
                    displayName: enrollmentName,
                    reachability: .lan,
                    label: enrollmentLabel
                )
                enrollmentRoute.clear()
                enrollmentError = nil
                selection = host.id
            } catch {
                enrollmentError = "Could not pair with the router. Try again."
            }
        }
    }
}
