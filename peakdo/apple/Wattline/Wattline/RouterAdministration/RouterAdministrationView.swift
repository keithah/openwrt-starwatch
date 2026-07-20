import SwiftUI
import WattlineNetwork

struct RouterAdministrationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var adminToken = ""
    let host: RouterHostMetadata

    private var admin: RouterAdministrationModel { model.routerAdministration }

    var body: some View {
        let presentation = RouterAdministrationPresentation(access: admin.access)
        NavigationStack {
            Form {
                Section("Router") {
                    LabeledContent("Name", value: host.displayName)
                    LabeledContent("Address", value: "\(host.host):\(host.port)")
                }

                if presentation.showsClientSections, presentation.showsHistory {
                    Section("History") {
                        RouterHistoryView(model: admin)
                        Button("Refresh history") {
                            Task { await admin.reloadHistory() }
                        }
                    }
                }

                if presentation.showsUnlockField {
                    Section {
                        SecureField("Administrator token", text: $adminToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button(admin.access == .verifying ? "Verifying…" : "Unlock administration") {
                            let token = adminToken
                            adminToken = ""
                            Task { await admin.unlock(token: token) }
                        }
                        .disabled(
                            adminToken.isEmpty
                                || admin.access == .verifying
                                || admin.isTLSRotationRunning
                                || admin.isTLSPromotionRunning
                        )
                        if admin.host?.stagedCertificateFingerprint != nil {
                            Button(
                                admin.isTLSPromotionRunning
                                    ? "Verifying new certificate…"
                                    : admin.tlsPromotionRecoveryAvailable
                                        ? "Verify with administrator token"
                                        : "Verify new certificate"
                            ) {
                                if admin.tlsPromotionRecoveryAvailable {
                                    let token = adminToken
                                    adminToken = ""
                                    Task {
                                        await admin.promoteStagedTLSPin(
                                            administratorToken: token
                                        )
                                    }
                                } else {
                                    Task { await admin.promoteStagedTLSPin() }
                                }
                            }
                            .disabled(
                                admin.access == .verifying
                                    || admin.isTLSRotationRunning
                                    || admin.isTLSPromotionRunning
                                    || (admin.tlsPromotionRecoveryAvailable && adminToken.isEmpty)
                            )
                            Text("Use this after wattlined restarts to verify and promote the staged certificate pin.")
                                .foregroundStyle(.secondary)
                        }
                        if let message = admin.tlsError {
                            Text(message).foregroundStyle(.orange)
                        }
                    } header: {
                        Text("Administration")
                    } footer: {
                        Text("The administrator token is verified against the router and stored in Keychain. Wattline cannot promote a managed client token.")
                    }
                } else if presentation.showsAdministratorSections {
                    Section("Administration") {
                        Button("Lock administration", role: .destructive) {
                            Task { await admin.lock() }
                        }
                        .disabled(admin.isTLSRotationRunning || admin.isTLSPromotionRunning)
                    }
                }

                if presentation.visibleSections.contains(.clientEnrollment) {
                    Section("Client enrollment") {
                        RouterPairingModeView(model: admin)
                    }
                }

                if presentation.visibleSections.contains(.apiClients) {
                    Section("API clients") {
                        RouterTokensView(model: admin)
                    }
                }

                if presentation.visibleSections.contains(.routerConfiguration) {
                    RouterSettingsView(model: admin)
                }

                if let message = admin.adminError {
                    Section { Text(message).foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Router Administration")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: host.endpoint.peripheralID) { await admin.open(host: host) }
            .onDisappear { Task { await admin.end() } }
        }
    }
}
