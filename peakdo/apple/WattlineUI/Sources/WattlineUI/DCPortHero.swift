import SwiftUI
import WattlineCore

public struct DCPortHero: View {
    public let status: DCPortStatus
    public let compact: Bool

    public init(status: DCPortStatus, compact: Bool = false) {
        self.status = status
        self.compact = compact
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 18) {
            HStack {
                Label("DC Output", systemImage: "powerplug.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WattlineTheme.secondaryText)
                Spacer()
                Text(status.enabled ? "LIVE" : "OFF")
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(status.enabled ? WattlineTheme.color(for: status.status) : WattlineTheme.secondaryText)
            }

            HStack(alignment: .lastTextBaseline, spacing: compact ? 16 : 28) {
                measurement(status.voltage, unit: "V", size: compact ? 38 : 52)

                Rectangle()
                    .fill(WattlineTheme.border)
                    .frame(width: 1, height: compact ? 32 : 43)

                measurement(abs(status.power), unit: "W", size: compact ? 38 : 52)
            }

            HStack(spacing: 7) {
                Image(systemName: status.status.wattlineSymbol)
                Text(status.status.wattlineName)
                Text("· \(status.current.wattlineFormatted(decimals: 2)) A")
                    .monospacedDigit()
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(WattlineTheme.color(for: status.status))
        }
        .wattlinePanel(compact: compact)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("DC output")
        .accessibilityValue(accessibilityValue)
    }

    private func measurement(_ value: Double, unit: String, size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value.wattlineFormatted())
                .font(.system(size: size, weight: .bold))
                .monospacedDigit()
            Text(unit)
                .font(.title3.weight(.semibold))
                .foregroundStyle(WattlineTheme.secondaryText)
        }
    }

    private var accessibilityValue: String {
        guard status.enabled else { return "Off" }
        return "On, \(status.status.wattlineName), \(status.voltage.wattlineFormatted()) volts, \(abs(status.power).wattlineFormatted()) watts"
    }
}
