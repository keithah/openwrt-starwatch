import SwiftUI
import WattlineCore

public extension PowerLimitLevel {
    var watts: Int {
        switch self {
        case .watts30: 30
        case .watts45: 45
        case .watts60: 60
        case .watts65: 65
        case .watts100: 100
        case .watts140: 140
        }
    }
}

public struct LimitSlider: View {
    public let label: String
    @Binding public var selection: PowerLimitLevel
    public let isPending: Bool
    public let onReset: (@MainActor @Sendable () -> Void)?
    public let onEditingChanged: (@MainActor @Sendable (Bool) -> Void)?

    public init(
        _ label: String,
        selection: Binding<PowerLimitLevel>,
        isPending: Bool = false,
        onReset: (@MainActor @Sendable () -> Void)? = nil,
        onEditingChanged: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        self.label = label
        _selection = selection
        self.isPending = isPending
        self.onReset = onReset
        self.onEditingChanged = onEditingChanged
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.headline)
                Spacer()
                if isPending {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Updating \(label) limit")
                }
                Text("\(selection.watts) W")
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(WattlineTheme.accent)
            }

            Slider(value: sliderValue, in: 0...5, step: 1, onEditingChanged: { editing in
                onEditingChanged?(editing)
            }) {
                Text("\(label) power limit")
            }
            .tint(WattlineTheme.accent)
            .disabled(isPending)
            .accessibilityValue("\(selection.watts) watts")
            .accessibilityIdentifier("\(label) limit")

            HStack(spacing: 0) {
                ForEach(PowerLimitLevel.allCases, id: \.rawValue) { level in
                    Text("\(level.watts)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(level == selection ? .white : WattlineTheme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                }
            }

            if let onReset {
                Button("Reset to default", action: { onReset() })
                    .font(.subheadline.weight(.medium))
                    .disabled(isPending)
                    .accessibilityIdentifier("Reset \(label) limit")
            }
        }
        .wattlinePanel()
    }

    private var sliderValue: Binding<Double> {
        Binding(
            get: { Double(selection.rawValue) },
            set: { rawValue in
                let snapped = UInt8(min(5, max(0, rawValue.rounded())))
                if let level = PowerLimitLevel(rawValue: snapped) {
                    selection = level
                }
            }
        )
    }
}
