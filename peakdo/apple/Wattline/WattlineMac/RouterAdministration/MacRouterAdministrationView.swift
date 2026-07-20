import SwiftUI
import WattlineNetwork
import WattlineUI

private enum MacRouterEnrollmentSource: Equatable {
    case discovered(DiscoveredRouter)
    case payload(RouterPairingPayload)
}

struct MacRouterAdministrationView: View {
    let model: RouterAdministrationModel
    let connections: RouterConnectionModel
    let enrollmentRoute: RouterEnrollmentRoute

    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: RouterHostMetadata.ID?
    @State private var selectedDiscoveredRouter: DiscoveredRouter?
    @State private var administratorToken = ""
    @State private var pin = ""
    @State private var enrollmentName = "Wattline Router"
    @State private var enrollmentLabel = "Wattline for Mac"
    @State private var isEnrollmentSubmitting = false
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

    private var savedHostSelection: Binding<RouterHostMetadata.ID?> {
        Binding(
            get: { selection },
            set: { id in
                guard let id else {
                    selection = nil
                    return
                }
                selectSavedHost(id)
            }
        )
    }

    private var enrollmentSource: MacRouterEnrollmentSource? {
        if let selectedDiscoveredRouter { return .discovered(selectedDiscoveredRouter) }
        if let payload = enrollmentRoute.payload { return .payload(payload) }
        return nil
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
            if enrollmentRoute.payload != nil {
                showPairingPayload()
            }
            guard enrollmentSource == nil, selection == nil else { return }
            selection = connections.savedHosts.first?.id
        }
        .task(id: selection) {
            guard enrollmentSource == nil, let selectedHost else {
                await model.end()
                return
            }
            await model.open(host: selectedHost)
        }
        .onChange(of: enrollmentRoute.payload?.deviceID) { _, deviceID in
            if deviceID != nil { showPairingPayload() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { clearEnrollmentSecrets() }
        }
        .onDisappear { clearEnrollmentSecrets() }
        .onDisappear {
            connections.stopDiscovery()
            Task { await model.end() }
        }
    }

    private var routerList: some View {
        List(selection: savedHostSelection) {
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
                        Button(router.serviceName) { beginEnrollment(router) }
                            .buttonStyle(.plain)
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
        if let enrollmentSource {
            enrollmentForm(enrollmentSource)
        } else if let host = selectedHost {
            administrationForm(host)
        } else {
            ContentUnavailableView(
                "No router selected",
                systemImage: "network",
                description: Text("Select a saved router or import a pairing link.")
            )
        }
    }

    private func administrationForm(_ host: RouterHostMetadata) -> some View {
        let presentation = RouterAdministrationPresentation(access: model.access)
        return Form {
            Section("Router") {
                LabeledContent("Name", value: host.displayName)
                LabeledContent("Address", value: "\(host.host):\(host.port)")
                    .fontDesign(.monospaced)
            }

            if presentation.showsClientSections, presentation.showsHistory {
                Section("History") {
                    RouterHistoryView(model: model)
                    Button("Refresh history") { Task { await model.reloadHistory() } }
                }
            }

            if model.host != nil {
                Section("Link-Power pairing") {
                    RouterDevicePairingView(model: model)
                }
            }

            if presentation.showsUnlockField {
                administrationUnlockSection
            } else if presentation.showsAdministratorSections {
                Section("Administration") {
                    Button("Lock administration", role: .destructive) {
                        Task { await model.lock() }
                    }
                    .disabled(model.isTLSRotationRunning || model.isTLSPromotionRunning)
                }
            }

            if presentation.visibleSections.contains(.clientEnrollment) {
                Section("Client enrollment") {
                    RouterPairingModeView(model: model)
                }
            }

            if presentation.visibleSections.contains(.apiClients) {
                Section("API clients") {
                    RouterTokensView(model: model)
                }
            }

            if presentation.visibleSections.contains(.routerConfiguration) {
                RouterSettingsView(model: model)
                RouterAdvancedView(model: model)
            }

            if presentation.showsClientSections {
                RouterRulesView(model: model)
            }

            if let message = model.adminError {
                Section { Text(message).foregroundStyle(.orange) }
            }
        }
        .formStyle(.grouped)
    }

    private var administrationUnlockSection: some View {
        Section {
            SecureField("Administrator token", text: $administratorToken)
            Button(model.access == .verifying ? "Verifying…" : "Unlock administration") {
                let token = administratorToken
                administratorToken = ""
                Task { await model.unlock(token: token) }
            }
            .disabled(
                administratorToken.isEmpty
                    || model.access == .verifying
                    || model.isTLSRotationRunning
                    || model.isTLSPromotionRunning
            )
            if model.host?.stagedCertificateFingerprint != nil {
                Button(
                    model.isTLSPromotionRunning
                        ? "Verifying new certificate…"
                        : model.tlsPromotionRecoveryAvailable
                            ? "Verify with administrator token"
                            : "Verify new certificate"
                ) {
                    if model.tlsPromotionRecoveryAvailable {
                        let token = administratorToken
                        administratorToken = ""
                        Task { await model.promoteStagedTLSPin(administratorToken: token) }
                    } else {
                        Task { await model.promoteStagedTLSPin() }
                    }
                }
                .disabled(
                    model.access == .verifying
                        || model.isTLSRotationRunning
                        || model.isTLSPromotionRunning
                        || (model.tlsPromotionRecoveryAvailable && administratorToken.isEmpty)
                )
                Text("Use this after wattlined restarts to verify and promote the staged certificate pin.")
                    .foregroundStyle(.secondary)
            }
            if let message = model.tlsError {
                Text(message).foregroundStyle(.orange)
            }
        } header: {
            Text("Administration")
        } footer: {
            Text("The administrator token is verified against the router and stored in Keychain. Wattline cannot promote a managed client token.")
        }
    }

    private func enrollmentForm(_ source: MacRouterEnrollmentSource) -> some View {
        Form {
            Section("Router") {
                LabeledContent("Device", value: enrollmentDeviceID(source))
                LabeledContent("Address", value: enrollmentAuthority(source))
                TextField("Router name", text: $enrollmentName)
                TextField("Client label", text: $enrollmentLabel)
            }
            if case .discovered = source {
                Section("Current pairing PIN") {
                    SecureField("6-digit PIN", text: $pin)
                        .routerNumberInput()
                }
            }
            Section {
                Button(isEnrollmentSubmitting ? "Pairing…" : "Pair and connect") {
                    enroll(source)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canEnroll(source) || isEnrollmentSubmitting)
            } footer: {
                Text("The managed client token is stored in Keychain. Wattline never stores the pairing PIN.")
            }
            if let enrollmentError {
                Section { Text(enrollmentError).foregroundStyle(.orange) }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func enrollmentDeviceID(_ source: MacRouterEnrollmentSource) -> String {
        switch source {
        case let .discovered(router): router.deviceID
        case let .payload(payload): payload.deviceID
        }
    }

    private func enrollmentAuthority(_ source: MacRouterEnrollmentSource) -> String {
        switch source {
        case let .discovered(router):
            "\(router.endpoint.host):\(router.endpoint.port)"
        case let .payload(payload):
            "\(payload.enrollmentEndpoint.host):\(payload.enrollmentEndpoint.port)"
        }
    }

    private func canEnroll(_ source: MacRouterEnrollmentSource) -> Bool {
        !enrollmentLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !enrollmentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && {
                if case .discovered = source {
                    return pin.utf8.count == 6
                        && pin.utf8.allSatisfy { (48...57).contains($0) }
                }
                return true
            }()
    }

    private func beginEnrollment(_ router: DiscoveredRouter) {
        enrollmentRoute.clear()
        selectedDiscoveredRouter = router
        selection = nil
        enrollmentName = router.serviceName
        clearEnrollmentSecrets()
        enrollmentError = nil
    }

    private func showPairingPayload() {
        guard let payload = enrollmentRoute.payload else { return }
        selectedDiscoveredRouter = nil
        selection = nil
        enrollmentName = payload.host
        clearEnrollmentSecrets()
        enrollmentError = nil
    }

    private func pastePairingLink() {
        do {
            try enrollmentAdapter.pastePairingLink()
            showPairingPayload()
        } catch {
            enrollmentError = "The clipboard does not contain a Wattline pairing link."
        }
    }

    private func importQRImage() {
        Task {
            do {
                try await enrollmentAdapter.importQRImage()
                showPairingPayload()
            } catch {
                enrollmentError = "The selected image does not contain a Wattline pairing QR code."
            }
        }
    }

    private func enroll(_ source: MacRouterEnrollmentSource) {
        isEnrollmentSubmitting = true
        enrollmentError = nil
        let submittedPIN = pin
        pin = ""
        Task {
            let coordinator = RouterEnrollmentCoordinator(
                connections: connections,
                connect: { host in selectSavedHost(host.id) }
            )
            do {
                switch source {
                case let .discovered(router):
                    try await coordinator.submit(
                        pin: submittedPIN,
                        label: enrollmentLabel,
                        router: router
                    )
                case let .payload(payload):
                    try await coordinator.submit(
                        payload: payload,
                        displayName: enrollmentName,
                        label: enrollmentLabel
                    )
                }
                enrollmentRoute.clear()
                selectedDiscoveredRouter = nil
                enrollmentError = nil
            } catch {
                enrollmentError = coordinator.errorMessage
            }
            pin = ""
            isEnrollmentSubmitting = false
        }
    }

    private func clearEnrollmentSecrets() {
        pin = ""
        administratorToken = ""
    }

    private func selectSavedHost(_ id: RouterHostMetadata.ID) {
        enrollmentRoute.clear()
        selectedDiscoveredRouter = nil
        enrollmentError = nil
        clearEnrollmentSecrets()
        selection = id
    }
}
