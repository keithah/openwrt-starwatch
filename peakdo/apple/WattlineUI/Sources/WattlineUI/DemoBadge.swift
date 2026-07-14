import SwiftUI

public struct DemoBadge: View {
    public init() {}

    public var body: some View {
        Text("DEMO")
            .font(.caption2.weight(.bold))
            .monospaced()
            .tracking(0.8)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(WattlineTheme.accent, in: Capsule())
            .foregroundStyle(.white)
            .accessibilityLabel("Demo mode")
    }
}
