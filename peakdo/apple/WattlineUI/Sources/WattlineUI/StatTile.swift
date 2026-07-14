import SwiftUI

public struct StatTile: View {
    public let label: String
    public let value: String
    public let unit: String?
    public let symbol: String?
    public let compact: Bool

    public init(
        label: String,
        value: String,
        unit: String? = nil,
        symbol: String? = nil,
        compact: Bool = false
    ) {
        self.label = label
        self.value = value
        self.unit = unit
        self.symbol = symbol
        self.compact = compact
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 10) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                }
                Text(label.uppercased())
            }
            .font(.caption2.weight(.semibold))
            .tracking(0.7)
            .foregroundStyle(WattlineTheme.secondaryText)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(compact ? .headline : .title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                if let unit {
                    Text(unit)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(WattlineTheme.secondaryText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .wattlinePanel(compact: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue([value, unit].compactMap { $0 }.joined(separator: " "))
    }
}
