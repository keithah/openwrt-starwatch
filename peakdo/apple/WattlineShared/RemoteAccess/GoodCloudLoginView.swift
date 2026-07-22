import SwiftUI

struct GoodCloudLoginPresentation: Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    struct Credentials: Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        let email: String
        let password: String

        var description: String { "GoodCloud credentials (redacted)" }
        var debugDescription: String { description }
        var customMirror: Mirror {
            Mirror(self, children: ["email": "<redacted>", "password": "<redacted>"])
        }
    }

    let email: String
    let password: String
    let isLoading: Bool

    var description: String { "GoodCloud login presentation (redacted, loading: \(isLoading))" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "email": "<redacted>",
                "password": "<redacted>",
                "isLoading": isLoading,
            ]
        )
    }

    var isSubmitDisabled: Bool {
        email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || password.isEmpty
            || isLoading
    }

    var credentialsForSubmission: Credentials {
        Credentials(
            email: email.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password
        )
    }
}

struct GoodCloudLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var email = ""
    @State private var password = ""
    @State private var loginTask: Task<Void, Never>?
    @FocusState private var focusedField: Field?

    let model: GoodCloudSettingsModel

    private enum Field {
        case email
        case password
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        #endif
                        .autocorrectionDisabled()
                        .textContentType(.username)
                        .focused($focusedField, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.go)
                        .onSubmit(submit)
                } header: {
                    Text("GoodCloud account")
                } footer: {
                    Text("Your GoodCloud token is stored in the system Keychain. Wattline never stores your password.")
                }

                if let errorMessage = model.errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(action: submit) {
                        HStack {
                            if isLoading {
                                ProgressView()
                            }
                            Text(isLoading ? "Signing In…" : "Sign In")
                        }
                    }
                    .disabled(presentation.isSubmitDisabled)
                }
            }
            .navigationTitle("GoodCloud")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        clearPassword()
                        dismiss()
                    }
                }
            }
        }
        .task {
            if email.isEmpty { focusedField = .email }
        }
        .onDisappear(perform: cancelLogin)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancelLogin() }
        }
    }

    private var isLoading: Bool {
        model.state == .loading
    }

    private var presentation: GoodCloudLoginPresentation {
        GoodCloudLoginPresentation(email: email, password: password, isLoading: isLoading)
    }

    private func submit() {
        guard !presentation.isSubmitDisabled else { return }
        focusedField = nil
        let credentials = presentation.credentialsForSubmission
        clearPassword()
        loginTask?.cancel()
        loginTask = Task { @MainActor in
            await model.login(email: credentials.email, password: credentials.password)
            guard !Task.isCancelled else { return }
            loginTask = nil
            if model.state == .authenticated { dismiss() }
        }
    }

    private func clearPassword() {
        password = ""
    }

    private func cancelLogin() {
        clearPassword()
        loginTask?.cancel()
        loginTask = nil
    }
}
