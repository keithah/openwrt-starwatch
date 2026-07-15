import SwiftUI

struct PlaceholderView: View {
    let title: String
    let symbol: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.bold())
            Text("Coming in a future Wattline release.")
                .foregroundStyle(.secondary)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(actionTitle)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .navigationTitle(title)
    }
}
