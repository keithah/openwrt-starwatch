import SwiftUI
import WattlineCore

public struct DCPortHero: View {
    public let status: DCPortStatus
    public let compact: Bool
    public let freshness: TelemetryFreshness

    @ScaledMetric(relativeTo: .largeTitle) private var regularMeasurementSize: CGFloat = 52
    @ScaledMetric(relativeTo: .title) private var compactMeasurementSize: CGFloat = 38

    public init(
        status: DCPortStatus,
        compact: Bool = false,
        freshness: TelemetryFreshness = .live
    ) {
        self.status = status
        self.compact = compact
        self.freshness = freshness
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 18) {
            HStack {
                Label("DC Output", systemImage: "powerplug.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WattlineTheme.secondaryText)
                Spacer()
                WattlineFreshnessBadge(freshness: freshness)
                Text(status.enabled ? "LIVE" : "OFF")
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(status.enabled ? WattlineTheme.color(for: status.status) : WattlineTheme.secondaryText)
            }

            HStack(alignment: .lastTextBaseline, spacing: compact ? 16 : 28) {
                measurement(status.voltage, unit: "V")

                Rectangle()
                    .fill(WattlineTheme.border)
                    .frame(width: 1, height: compact ? 32 : 43)

                measurement(abs(status.power), unit: "W")
            }
            .opacity(freshness.wattlineIsStale ? 0.58 : 1)

            HStack(spacing: 7) {
                Image(systemName: status.status.wattlineSymbol)
                Text(status.status.wattlineName)
                Text("· \(status.current.wattlineFormatted(decimals: 2)) A")
                    .monospacedDigit()
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(WattlineTheme.color(for: status.status))
            .opacity(freshness.wattlineIsStale ? 0.58 : 1)
        }
        .wattlinePanel(compact: compact)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("DC output")
        .accessibilityValue(accessibilityValue)
    }

    private func measurement(_ value: Double, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value.wattlineFormatted())
                .font(.system(size: measurementSize, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(unit)
                .font(.title3.weight(.semibold))
                .foregroundStyle(WattlineTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accessibilityValue: String {
        guard status.enabled else {
            return "Off, \(freshness.wattlineAccessibilityDescription)"
        }
        return "On, \(status.status.wattlineName), \(status.voltage.wattlineFormatted()) volts, \(abs(status.power).wattlineFormatted()) watts, \(freshness.wattlineAccessibilityDescription)"
    }

    private var measurementSize: CGFloat {
        compact ? compactMeasurementSize : regularMeasurementSize
    }
}
