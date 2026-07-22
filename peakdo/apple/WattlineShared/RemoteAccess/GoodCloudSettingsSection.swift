import SwiftUI

struct GoodCloudSettingsSection: View {
    @State private var showsLogin = false
    @State private var showsDevicePicker = false
    @State private var showsRemovalError = false

    let model: GoodCloudSettingsModel

    var body: some View {
        Section("Remote Access") {
            switch model.state {
            case .loading:
                HStack {
                    ProgressView()
                    Text("Contacting GoodCloud…")
                }
            case .loggedOut, .requiresLogin, .failed:
                signedOutContent
            case .authenticated:
                signedInContent
            }
        }
        .task { await model.load() }
        .sheet(isPresented: $showsLogin) {
            GoodCloudLoginView(model: model)
        }
        .sheet(isPresented: $showsDevicePicker) {
            GoodCloudDevicePickerView(model: model)
        }
        .alert("Couldn’t remove router", isPresented: $showsRemovalError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Remote access is unavailable. Please try again.")
        }
    }

    @ViewBuilder
    private var signedOutContent: some View {
        let presentation = GoodCloudSettingsPresentation(modelState: model.state)
        LabeledContent("GoodCloud", value: presentation.title)
        if let message = presentation.message {
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
        Button("Sign in to GoodCloud") { showsLogin = true }
    }

    @ViewBuilder
    private var signedInContent: some View {
        LabeledContent("GoodCloud", value: "Signed in")
        LabeledContent("Local", value: "Preferred")
        if let association = model.association {
            LabeledContent("Remote", value: association.isOnline ? "Available" : "Device offline")
            VStack(alignment: .leading, spacing: 3) {
                Text(association.name)
                Text(association.model).font(.caption).foregroundStyle(.secondary)
                Text(formattedMAC(association.mac))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let ddns = association.ddns, !ddns.isEmpty {
                    Text(ddns).font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Change GoodCloud router") { showsDevicePicker = true }
            Button("Remove GoodCloud router", role: .destructive) { removeAssociation() }
        } else {
            LabeledContent("Remote", value: "Router not selected")
            if let suggestion = model.suggestedDevice {
                Text("Suggested: \(suggestion.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Choose GoodCloud router") { showsDevicePicker = true }
        }
        Button("Sign out of GoodCloud", role: .destructive) {
            Task { await model.logout() }
        }
    }

    private func removeAssociation() {
        Task { @MainActor in
            do {
                try await model.removeAssociation()
            } catch {
                showsRemovalError = true
            }
        }
    }

    private func formattedMAC(_ value: String) -> String {
        GoodCloudDevicePresentation.formattedMAC(value)
    }
}
