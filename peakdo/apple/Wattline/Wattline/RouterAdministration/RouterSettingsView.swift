import SwiftUI
import WattlineNetwork
import WattlineUI

struct RouterSettingsView: View {
    let model: RouterAdministrationModel

    @State private var original: RouterSettingsValue?
    @State private var draft: RouterSettingsDraft?
    @State private var selectedReplacementID: UUID?
    @State private var confirmations: Set<RouterSettingsConfirmation> = []
    @State private var confirmsListenerMigration = false
    @State private var confirmsInsecureWANHTTP = false
    @State private var confirmsTokenStoreCutover = false

    var body: some View {
        Group {
            if let original, let current = draft {
                listenerSection(
                    title: "HTTP listener",
                    enabled: binding(\.http.enabled, fallback: current.http.enabled),
                    addr4: binding(\.http.addr4, fallback: current.http.addr4),
                    addr6: binding(\.http.addr6, fallback: current.http.addr6),
                    port: binding(\.http.port, fallback: current.http.port)
                )
                listenerSection(
                    title: "HTTPS listener",
                    enabled: binding(\.https.enabled, fallback: current.https.enabled),
                    addr4: binding(\.https.addr4, fallback: current.https.addr4),
                    addr6: binding(\.https.addr6, fallback: current.https.addr6),
                    port: binding(\.https.port, fallback: current.https.port)
                )

                Section("TLS") {
                    TextField("Certificate path", text: binding(\.tls.cert, fallback: current.tls.cert))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Private key path", text: binding(\.tls.key, fallback: current.tls.key))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    LabeledContent("SHA-256", value: original.tls.sha256)
                        .fontDesign(.monospaced)
                }

                Section {
                    TextField(
                        "Token store",
                        text: binding(\.tokenStore, fallback: current.tokenStore)
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    TextField(
                        "Pairing TTL",
                        text: binding(\.pairingTTL, fallback: current.pairingTTL)
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    Toggle(
                        "Pairing always on",
                        isOn: binding(\.pairingAlwaysOn, fallback: current.pairingAlwaysOn)
                    )
                    Toggle("Advanced API", isOn: binding(\.advanced, fallback: current.advanced))
                } header: {
                    Text("Pairing and API")
                } footer: {
                    Text(RouterSettingsCopy.tokenStoreCutover)
                }

                Section("mDNS and access") {
                    Toggle("mDNS", isOn: binding(\.mdns.enabled, fallback: current.mdns.enabled))
                    TextField(
                        "Interfaces (comma separated)",
                        text: interfacesBinding(fallback: current.mdns.interfaces)
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    Toggle("WAN access", isOn: binding(\.wanAccess, fallback: current.wanAccess))
                }

                Section("Bluetooth pairing") {
                    SecureField("BLE PIN", text: binding(\.blePIN, fallback: current.blePIN))
                        .textContentType(.oneTimeCode)
                        .keyboardType(.numberPad)
                        .monospacedDigit()
                }

                saveSection(original: original, draft: current)
            } else if model.isSettingsLoading {
                Section("Router configuration") {
                    ProgressView("Loading configuration…")
                }
            } else {
                Section("Router configuration") {
                    if let message = model.settingsError {
                        Text(message).foregroundStyle(.orange)
                    } else {
                        ProgressView()
                    }
                }
            }
        }
        .task {
            await model.reloadSettings()
            publishAuthoritativeDraft()
        }
        .onDisappear {
            draft = nil
            original = nil
            confirmations = []
            selectedReplacementID = nil
        }
        .confirmationDialog(
            "Change router listeners?",
            isPresented: $confirmsListenerMigration,
            titleVisibility: .visible
        ) {
            Button("Confirm listener migration") { confirm(.listenerMigration) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Listener changes can interrupt access. Keep a verified endpoint available for reconnection.")
        }
        .confirmationDialog(
            "Allow insecure WAN HTTP?",
            isPresented: $confirmsInsecureWANHTTP,
            titleVisibility: .visible
        ) {
            Button("Allow insecure WAN HTTP", role: .destructive) {
                confirm(.insecureWANHTTP)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("HTTP traffic on WAN links is not encrypted.")
        }
        .confirmationDialog(
            "Change token storage?",
            isPresented: $confirmsTokenStoreCutover,
            titleVisibility: .visible
        ) {
            Button("Confirm token-store cutover", role: .destructive) {
                confirm(.tokenStoreCutover)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(RouterSettingsCopy.tokenStoreCutover)
        }
    }

    @ViewBuilder
    private func listenerSection(
        title: String,
        enabled: Binding<Bool>,
        addr4: Binding<String>,
        addr6: Binding<String>,
        port: Binding<String>
    ) -> some View {
        Section(title) {
            Toggle("Enabled", isOn: enabled)
            TextField("IPv4 address", text: addr4)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("IPv6 address", text: addr6)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Port", text: port)
                .keyboardType(.numberPad)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func saveSection(
        original: RouterSettingsValue,
        draft: RouterSettingsDraft
    ) -> some View {
        let decision = RouterSettingsSavePolicy.evaluate(
            original: original,
            draft: draft,
            context: saveContext
        )
        Section("Apply configuration") {
            if decision.blocker == .validatedReplacementRequired {
                Picker("Replacement endpoint", selection: $selectedReplacementID) {
                    Text("Select endpoint").tag(UUID?.none)
                    ForEach(model.replacementCandidates) { candidate in
                        Text("\(candidate.displayName) — \(candidate.scheme)://\(candidate.host):\(candidate.port)")
                            .tag(Optional(candidate.id))
                    }
                }
                if let candidate = selectedReplacement {
                    Button(model.isReplacementValidationRunning ? "Verifying…" : "Verify endpoint") {
                        Task { await model.validateReplacement(candidate) }
                    }
                    .disabled(model.isReplacementValidationRunning)
                }
                if let message = model.replacementValidationError {
                    Text(message).foregroundStyle(.orange)
                }
            }

            if decision.blocker == .invalidDraft {
                Text("Enter a six-digit BLE PIN and listener ports from 1 through 65535.")
                    .foregroundStyle(.orange)
            } else if decision.blocker == .noEnabledListener {
                Text("At least one HTTP or HTTPS listener must remain enabled.")
                    .foregroundStyle(.orange)
            }

            if decision.patch != nil, decision.blocker == nil {
                Button(model.isSettingsSaving ? "Saving…" : "Save configuration") {
                    saveOrConfirm()
                }
                .disabled(model.isSettingsSaving)
            }

            if model.settingsRestartRequired {
                Text(RouterSettingsCopy.restartRequired)
                    .foregroundStyle(.orange)
            }
            if let message = model.settingsError {
                Text(message).foregroundStyle(.orange)
            }
        }
    }

    private var selectedReplacement: RouterHostMetadata? {
        guard let selectedReplacementID else { return nil }
        return model.replacementCandidates.first { $0.id == selectedReplacementID }
    }

    private var saveContext: RouterSettingsSaveContext {
        let correlatedReplacement: RouterReplacementCandidate?
        if let selectedReplacement,
           let validated = model.validatedReplacement,
           selectedReplacement.scheme == validated.scheme,
           selectedReplacement.host == validated.host,
           selectedReplacement.port == validated.port
        {
            correlatedReplacement = validated
        } else {
            correlatedReplacement = nil
        }
        return RouterSettingsSaveContext(
            currentScheme: model.host?.scheme ?? "",
            currentPort: model.host?.port ?? 0,
            expectedDeviceID: model.host?.deviceID,
            replacement: correlatedReplacement,
            confirmations: confirmations
        )
    }

    private func binding<Value>(
        _ keyPath: WritableKeyPath<RouterSettingsDraft, Value>,
        fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: { draft?[keyPath: keyPath] ?? fallback },
            set: { draft?[keyPath: keyPath] = $0 }
        )
    }

    private func interfacesBinding(fallback: [String]) -> Binding<String> {
        Binding(
            get: { (draft?.mdns.interfaces ?? fallback).joined(separator: ", ") },
            set: { value in
                draft?.mdns.interfaces = value
                    .split(separator: ",", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    private func confirm(_ confirmation: RouterSettingsConfirmation) {
        confirmations.insert(confirmation)
        saveOrConfirm()
    }

    private func saveOrConfirm() {
        guard let original, let draft else { return }
        let decision = RouterSettingsSavePolicy.evaluate(
            original: original,
            draft: draft,
            context: saveContext
        )
        if decision.requiredConfirmations.contains(.listenerMigration) {
            confirmsListenerMigration = true
        } else if decision.requiredConfirmations.contains(.insecureWANHTTP) {
            confirmsInsecureWANHTTP = true
        } else if decision.requiredConfirmations.contains(.tokenStoreCutover) {
            confirmsTokenStoreCutover = true
        } else if let patch = decision.patch, decision.blocker == nil {
            Task {
                await model.saveSettings(settingsPatch(patch))
                if model.settingsError == nil {
                    publishAuthoritativeDraft()
                }
            }
        }
    }

    private func publishAuthoritativeDraft() {
        guard let settings = model.settings else { return }
        let value = settingsValue(settings)
        original = value
        draft = RouterSettingsDraft(value)
        confirmations = []
    }
}

private func settingsValue(_ settings: RouterSettings) -> RouterSettingsValue {
    RouterSettingsValue(
        http: .init(
            enabled: settings.http.enabled,
            addr4: settings.http.addr4,
            addr6: settings.http.addr6,
            port: settings.http.port
        ),
        https: .init(
            enabled: settings.https.enabled,
            addr4: settings.https.addr4,
            addr6: settings.https.addr6,
            port: settings.https.port
        ),
        tls: .init(
            cert: settings.tls.cert,
            key: settings.tls.key,
            sha256: settings.tls.sha256
        ),
        tokenStore: settings.tokenStore,
        pairingTTL: settings.pairingTTL,
        pairingAlwaysOn: settings.pairingAlwaysOn,
        advanced: settings.advanced,
        mdns: .init(enabled: settings.mdns.enabled, interfaces: settings.mdns.interfaces),
        wanAccess: settings.wanAccess,
        blePIN: settings.blePIN
    )
}

private func settingsPatch(_ patch: RouterSettingsDraftPatch) -> RouterSettingsPatch {
    RouterSettingsPatch(
        http: patch.http.map {
            RouterListenerSettingsPatch(
                enabled: $0.enabled,
                addr4: $0.addr4,
                addr6: $0.addr6,
                port: $0.port
            )
        },
        https: patch.https.map {
            RouterListenerSettingsPatch(
                enabled: $0.enabled,
                addr4: $0.addr4,
                addr6: $0.addr6,
                port: $0.port
            )
        },
        tls: patch.tls.map { RouterTLSSettingsPatch(cert: $0.cert, key: $0.key) },
        tokenStore: patch.tokenStore,
        pairingTTL: patch.pairingTTL,
        pairingAlwaysOn: patch.pairingAlwaysOn,
        advanced: patch.advanced,
        mdns: patch.mdns.map {
            RouterMDNSSettingsPatch(enabled: $0.enabled, interfaces: $0.interfaces)
        },
        wanAccess: patch.wanAccess,
        blePIN: patch.blePIN
    )
}
