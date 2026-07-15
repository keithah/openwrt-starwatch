import SwiftUI

struct ToastView: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 8)
            .accessibilityIdentifier("Error toast")
    }
}
