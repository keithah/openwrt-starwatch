import SwiftUI
import WattlineCore

public struct PortCard: View {
    public let title: String
    public let symbol: String
    public let enabled: Bool
    public let flow: PowerFlow
    public let voltage: Double
    public let current: Double
    public let power: Double
    public let detail: String?
    public let compact: Bool
    public let canToggle: Bool
    public let isPending: Bool
    public let freshness: TelemetryFreshness
    public let toggleLabel: String?
    public let onToggle: (@MainActor @Sendable (Bool) -> Void)?
    public let onSelect: (@MainActor @Sendable () -> Void)?

    public init(
        title: String,
        symbol: String,
        enabled: Bool,
        flow: PowerFlow,
        voltage: Double,
        current: Double,
        power: Double,
        detail: String? = nil,
        compact: Bool = false,
        canToggle: Bool = true,
        isPending: Bool = false,
        freshness: TelemetryFreshness = .live,
        toggleLabel: String? = nil,
        onToggle: (@MainActor @Sendable (Bool) -> Void)? = nil,
        onSelect: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.title = title
        self.symbol = symbol
        self.enabled = enabled
        self.flow = flow
        self.voltage = voltage
        self.current = current
        self.power = power
        self.detail = detail
        self.compact = compact
        self.canToggle = canToggle
        self.isPending = isPending
        self.freshness = freshness
        self.toggleLabel = toggleLabel
        self.onToggle = onToggle
        self.onSelect = onSelect
    }

    public init(
        dcStatus status: DCPortStatus,
        showsBypass: Bool = false,
        compact: Bool = false,
        canToggle: Bool = true,
        isPending: Bool = false,
        freshness: TelemetryFreshness = .live,
        onToggle: (@MainActor @Sendable (Bool) -> Void)? = nil,
        onSelect: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.init(
            title: "DC Port",
            symbol: "powerplug.fill",
            enabled: status.enabled,
            flow: status.status,
            voltage: status.voltage,
            current: status.current,
            power: status.power,
            detail: showsBypass && status.bypassOn == true ? "Bypass" : nil,
            compact: compact,
            canToggle: canToggle,
            isPending: isPending,
            freshness: freshness,
            toggleLabel: "DC Port",
            onToggle: onToggle,
            onSelect: onSelect
        )
    }

    public init(
        typeCStatus status: TypeCPortStatus,
        showsDCInput: Bool = false,
        compact: Bool = false,
        canToggle: Bool = true,
        isPending: Bool = false,
        freshness: TelemetryFreshness = .live,
        onToggle: (@MainActor @Sendable (Bool) -> Void)? = nil,
        onSelect: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.init(
            title: "USB-C Port",
            symbol: "cable.connector",
            enabled: status.enabled,
            flow: status.status,
            voltage: status.voltage,
            current: status.current,
            power: status.power,
            detail: wattlineTypeCDetail(status, showsDCInput: showsDCInput),
            compact: compact,
            canToggle: canToggle,
            isPending: isPending,
            freshness: freshness,
            toggleLabel: "USB-C Output",
            onToggle: onToggle,
            onSelect: onSelect
        )
    }

    public var body: some View {
        card
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            HStack(spacing: 10) {
                PortIdentityBadge(symbol: symbol, flow: flow)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(enabled ? flow.wattlineName : "Off")
                        .font(.caption)
                        .foregroundStyle(WattlineTheme.secondaryText)
                }

                Spacer()

                WattlineFreshnessBadge(freshness: freshness)

                if isPending {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Updating \(title)")
                        .accessibilityValue("Pending")
                }

                if let onToggle, canToggle {
                    Toggle(
                        toggleLabel ?? "\(title) power",
                        isOn: Binding(
                            get: { enabled },
                            set: { newValue in onToggle(newValue) }
                        )
                    )
                    .labelsHidden()
                    .tint(WattlineTheme.accent)
                    .disabled(isPending)
                    .accessibilityValue(toggleAccessibilityValue)
                    .accessibilityIdentifier(toggleLabel ?? "\(title) power")
                    .accessibilityHint(isPending ? "Update in progress" : "Changes \(title) power")
                } else {
                    statusPill
                }
            }

            Divider()
                .overlay(WattlineTheme.border)

            HStack(spacing: 0) {
                reading(value: voltage, unit: "V", label: "Voltage")
                reading(value: current, unit: "A", label: "Current")
                reading(value: abs(power), unit: "W", label: "Power")
            }
            .opacity(freshness.wattlineIsStale ? 0.58 : 1)

            if let detail {
                Text(detail.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(0.7)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(WattlineTheme.accent.opacity(0.16), in: Capsule())
                    .foregroundStyle(WattlineTheme.accent)
                    .accessibilityLabel(detail)
                    .opacity(freshness.wattlineIsStale ? 0.58 : 1)
            }

            if let onSelect {
                Divider()
                    .overlay(WattlineTheme.border)

                Button(action: { onSelect() }) {
                    HStack {
                        Text("View \(title) details")
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .font(.subheadline.weight(.medium))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(WattlineTheme.accent)
                .accessibilityHint("Opens details")
            }
        }
        .wattlinePanel(compact: compact)
    }

    private var statusPill: some View {
        Text(enabled ? "ON" : "OFF")
            .font(.caption2.weight(.bold))
            .tracking(0.7)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(WattlineTheme.recessedSurface, in: Capsule())
            .foregroundStyle(enabled ? WattlineTheme.color(for: flow) : WattlineTheme.secondaryText)
    }

    private func reading(value: Double, unit: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.7)
                .foregroundStyle(WattlineTheme.secondaryText)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value.wattlineFormatted())
                    .font(compact ? .subheadline.weight(.semibold) : .title3.weight(.semibold))
                    .monospacedDigit()
                Text(unit)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(WattlineTheme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(value.wattlineFormatted()) \(unit), \(freshness.wattlineAccessibilityDescription)")
    }

    private var toggleAccessibilityValue: String {
        let state = enabled ? "On" : "Off"
        return isPending ? "\(state), update pending" : state
    }
}

/// Shared USB-C detail-text computation, used by both `PortCard` and `PortCardPresentation` so
/// the "In / Out / DC input" labeling logic is computed once, not forked. Kept as a plain
/// (non-isolated) function since it's pure data mapping with no UI concerns.
func wattlineTypeCDetail(_ status: TypeCPortStatus, showsDCInput: Bool) -> String? {
    var details: [String] = []
    if let mode = status.mode {
        switch mode {
        case .disabled: details.append("Disabled")
        case .input: details.append("In")
        case .output: details.append("Out")
        case .inputAndOutput: details.append("In · Out")
        }
    }
    if showsDCInput && status.isDCInput == true {
        details.append("DC input")
    }
    return details.isEmpty ? nil : details.joined(separator: " · ")
}

/// Shared icon badge (symbol in a tinted rounded square) used by both the full-size and compact
/// port cards, so the semantic-color mapping is never forked between them.
struct PortIdentityBadge: View {
    let symbol: String
    let flow: PowerFlow
    var compact: Bool = false

    var body: some View {
        Image(systemName: symbol)
            .font(compact ? .subheadline : .headline)
            .frame(width: compact ? 22 : 30, height: compact ? 22 : 30)
            .background(WattlineTheme.recessedSurface, in: RoundedRectangle(cornerRadius: compact ? 6 : 8, style: .continuous))
            .foregroundStyle(WattlineTheme.color(for: flow))
    }
}

/// The presentation data needed to render a port's identity and telemetry, independent of size
/// (full or compact) and interaction context (toggle callback, pending state, freshness). Both
/// `PortCard` and `CompactPortCard` are built from this so the DC/USB-C detail text and field
/// mapping are computed once, not duplicated per variant.
public struct PortCardPresentation: Equatable, Sendable {
    public let title: String
    public let symbol: String
    public let enabled: Bool
    public let flow: PowerFlow
    public let voltage: Double
    public let current: Double
    public let power: Double
    public let detail: String?
    public let canToggle: Bool
    public let toggleLabel: String?

    public init(
        title: String,
        symbol: String,
        enabled: Bool,
        flow: PowerFlow,
        voltage: Double,
        current: Double,
        power: Double,
        detail: String? = nil,
        canToggle: Bool = true,
        toggleLabel: String? = nil
    ) {
        self.title = title
        self.symbol = symbol
        self.enabled = enabled
        self.flow = flow
        self.voltage = voltage
        self.current = current
        self.power = power
        self.detail = detail
        self.canToggle = canToggle
        self.toggleLabel = toggleLabel
    }

    public init(dcStatus status: DCPortStatus, showsBypass: Bool = false, canToggle: Bool = true) {
        self.init(
            title: "DC Port",
            symbol: "powerplug.fill",
            enabled: status.enabled,
            flow: status.status,
            voltage: status.voltage,
            current: status.current,
            power: status.power,
            detail: showsBypass && status.bypassOn == true ? "Bypass" : nil,
            canToggle: canToggle,
            toggleLabel: "DC Port"
        )
    }

    public init(typeCStatus status: TypeCPortStatus, showsDCInput: Bool = false, canToggle: Bool = true) {
        self.init(
            title: "USB-C Port",
            symbol: "cable.connector",
            enabled: status.enabled,
            flow: status.status,
            voltage: status.voltage,
            current: status.current,
            power: status.power,
            detail: wattlineTypeCDetail(status, showsDCInput: showsDCInput),
            canToggle: canToggle,
            toggleLabel: "USB-C Output"
        )
    }
}
