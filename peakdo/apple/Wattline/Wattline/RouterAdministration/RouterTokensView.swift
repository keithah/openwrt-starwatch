import SwiftUI
import WattlineNetwork

struct RouterTokensView: View {
    let model: RouterAdministrationModel
    @State private var tokenPendingRevocation: RouterTokenMetadata?

    var body: some View {
        Group {
            ForEach(model.tokens) { token in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(token.label)
                        if token.bootstrap {
                            Text("Bootstrap")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                        if model.isCurrentClient(token) {
                            Text("This device")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.tint.opacity(0.2), in: Capsule())
                        }
                    }
                    Text(token.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text("Created \(token.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .swipeActions {
                    if !token.bootstrap {
                        Button("Revoke", role: .destructive) {
                            tokenPendingRevocation = token
                        }
                    }
                }
            }
            if let message = model.tokensError {
                Text(message).foregroundStyle(.orange)
            }
        }
        .task { await model.reloadTokens() }
        .confirmationDialog(
            "Revoke this client?",
            isPresented: Binding(
                get: { tokenPendingRevocation != nil },
                set: { if !$0 { tokenPendingRevocation = nil } }
            ),
            presenting: tokenPendingRevocation
        ) { token in
            Button("Revoke \(token.label)", role: .destructive) {
                Task { await model.revoke(token) }
            }
        } message: { token in
            if model.isCurrentClient(token) {
                Text("This is this device's own token. Live updates stop immediately and this router returns to setup.")
            } else {
                Text("Revocation is immediate and closes that client's live updates.")
            }
        }
    }
}
