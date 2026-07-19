import SwiftUI
import WattlineNetwork

struct RouterTokenRevocationConfirmation: Equatable {
    let title: String
    let actionTitle: String
    let message: String
}

struct RouterTokenRowPresentation: Equatable {
    let showsBootstrapBadge: Bool
    let showsCurrentDeviceBadge: Bool
    let showsRevokeAction: Bool
    let confirmation: RouterTokenRevocationConfirmation?

    init(token: RouterTokenMetadata, isCurrentClient: Bool) {
        showsBootstrapBadge = token.bootstrap
        showsCurrentDeviceBadge = !token.bootstrap && isCurrentClient
        showsRevokeAction = !token.bootstrap
        guard !token.bootstrap else {
            confirmation = nil
            return
        }
        confirmation = RouterTokenRevocationConfirmation(
            title: isCurrentClient
                ? "Revoke this device's token?"
                : "Revoke \(token.label)?",
            actionTitle: "Revoke \(token.label)",
            message: isCurrentClient
                ? "This is this device's own token. Live updates stop immediately and this router returns to setup."
                : "Revocation is immediate and closes that client's live updates."
        )
    }
}

struct RouterTokensView: View {
    let model: RouterAdministrationModel
    @State private var tokenPendingRevocation: RouterTokenMetadata?

    var body: some View {
        Group {
            ForEach(model.tokens) { token in
                let presentation = presentation(for: token)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(token.label)
                        if presentation.showsBootstrapBadge {
                            Text("Bootstrap")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                        if presentation.showsCurrentDeviceBadge {
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
                    if presentation.showsRevokeAction {
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
            pendingPresentation?.confirmation?.title ?? "Revoke this client?",
            isPresented: Binding(
                get: { tokenPendingRevocation != nil },
                set: { if !$0 { tokenPendingRevocation = nil } }
            ),
            presenting: tokenPendingRevocation
        ) { token in
            if let confirmation = presentation(for: token).confirmation {
                Button(confirmation.actionTitle, role: .destructive) {
                    Task { await model.revoke(token) }
                }
            }
        } message: { token in
            Text(presentation(for: token).confirmation?.message ?? "")
        }
    }

    private var pendingPresentation: RouterTokenRowPresentation? {
        tokenPendingRevocation.map(presentation(for:))
    }

    private func presentation(for token: RouterTokenMetadata) -> RouterTokenRowPresentation {
        RouterTokenRowPresentation(
            token: token,
            isCurrentClient: model.isCurrentClient(token)
        )
    }
}
