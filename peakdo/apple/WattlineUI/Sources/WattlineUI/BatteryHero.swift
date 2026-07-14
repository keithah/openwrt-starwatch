import SwiftUI
import WattlineCore

public enum BatteryHeroStyle: String, CaseIterable, Equatable, Sendable {
    case segmented
    case gauge
}

public struct BatteryHero: View {
    public let status: BatteryStatus
    public let style: BatteryHeroStyle
    public let compact: Bool

    public init(
        status: BatteryStatus,
        style: BatteryHeroStyle = .segmented,
        compact: Bool = false
    ) {
        self.status = status
        self.style = style
        self.compact = compact
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 18) {
            HStack(alignment: .firstTextBaseline) {
                Label("Battery", systemImage: "battery.75percent")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WattlineTheme.secondaryText)

                Spacer()

                if status.isFull {
                    Text("FULL")
                        .font(.caption2.weight(.bold))
                        .tracking(0.8)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(WattlineTheme.charging.opacity(0.16), in: Capsule())
                        .foregroundStyle(WattlineTheme.charging)
                }
            }

            switch style {
            case .segmented:
                segmentedMeter
            case .gauge:
                gauge
            }

            HStack(spacing: 7) {
                Image(systemName: status.status.wattlineSymbol)
                    .font(.caption.weight(.bold))
                Text(status.status.wattlineName)
                Text("·")
                    .foregroundStyle(WattlineTheme.secondaryText)
                Text("\(abs(status.power).wattlineFormatted()) W")
                    .monospacedDigit()
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(WattlineTheme.color(for: status.status))
        }
        .wattlinePanel(compact: compact)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery")
        .accessibilityValue(accessibilityValue)
    }

    private var segmentedMeter: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            levelLabel

            HStack(spacing: compact ? 3 : 4) {
                ForEach(0..<20, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(segmentColor(at: index))
                        .frame(maxWidth: .infinity)
                        .frame(height: compact ? 18 : 25)
                }
            }
            .accessibilityHidden(true)
        }
    }

    private var gauge: some View {
        HStack(spacing: compact ? 16 : 24) {
            Gauge(value: Double(status.level), in: 0...100) {
                Text("Battery level")
            } currentValueLabel: {
                Text("\(status.level)%")
                    .font(compact ? .title3.weight(.bold) : .title2.weight(.bold))
                    .monospacedDigit()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(WattlineTheme.color(for: status.status))
            .scaleEffect(compact ? 1.3 : 1.65)
            .frame(width: compact ? 84 : 112, height: compact ? 76 : 104)

            VStack(alignment: .leading, spacing: 5) {
                Text("STATE OF CHARGE")
                    .font(.caption2.weight(.bold))
                    .tracking(1.1)
                    .foregroundStyle(WattlineTheme.secondaryText)
                levelLabel
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var levelLabel: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text("\(status.level)")
                .font(compact ? .system(size: 38, weight: .bold) : .system(size: 52, weight: .bold))
                .monospacedDigit()
            Text("%")
                .font(compact ? .title3.weight(.semibold) : .title2.weight(.semibold))
                .foregroundStyle(WattlineTheme.secondaryText)
        }
        .foregroundStyle(.white)
    }

    private func segmentColor(at index: Int) -> Color {
        let activeSegments = Int(ceil(Double(status.level) / 5.0))
        return index < activeSegments
            ? WattlineTheme.color(for: status.status)
            : WattlineTheme.recessedSurface
    }

    private var accessibilityValue: String {
        let power = abs(status.power).wattlineFormatted()
        let full = status.isFull ? ", fully charged" : ""
        return "\(status.level) percent, \(status.status.wattlineName), \(power) watts\(full)"
    }
}
