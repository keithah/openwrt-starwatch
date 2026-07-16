import SwiftUI
import WattlineCore

/// A single-row battery summary for space-constrained surfaces (macOS menu bar / popover).
///
/// Reuses `WattlineTheme.color(for:)`, `Double.wattlineFormatted()`, `TelemetryFreshness`
/// staleness rules, and `BatteryFlowLine` (shared with `BatteryHero`) rather than forking any of
/// that formatting. Telemetry is authoritative: this view renders only what `snapshot` reports,
/// with no optimistic state.
///
/// When the device does not report battery telemetry (`snapshot.battery == nil`), the view
/// renders nothing — the capability is absent from composition, not merely hidden or disabled.
public struct CompactBatteryHero: View {
    public let snapshot: SharedDeviceSnapshot
    public let freshness: TelemetryFreshness

    public init(snapshot: SharedDeviceSnapshot, freshness: TelemetryFreshness) {
        self.snapshot = snapshot
        self.freshness = freshness
    }

    public var body: some View {
        if let battery = snapshot.battery {
            HStack(spacing: 10) {
                Image(systemName: "battery.75percent")
                    .font(.subheadline)
                    .frame(width: 22, height: 22)
                    .background(WattlineTheme.recessedSurface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .foregroundStyle(WattlineTheme.color(for: battery.status))

                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(battery.level)")
                            .font(.headline.weight(.bold))
                            .monospacedDigit()
                        Text("%")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(WattlineTheme.secondaryText)
                        if battery.isFull {
                            Text("FULL")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(WattlineTheme.charging)
                        }
                    }

                    BatteryFlowLine(flow: battery.status, power: battery.power, freshness: freshness, font: .caption.weight(.medium))
                }
            }
            .opacity(telemetryOpacity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Battery")
            .accessibilityValue(accessibilityValue(for: battery))
        }
    }

    var telemetryOpacity: Double { freshness.wattlineIsStale ? 0.58 : 1 }
    var isSupported: Bool { snapshot.battery != nil }

    private func accessibilityValue(for battery: SharedBatterySnapshot) -> String {
        let power = abs(battery.power).wattlineFormatted()
        let full = battery.isFull ? ", fully charged" : ""
        return "\(battery.level) percent, \(battery.status.wattlineName), \(power) watts\(full), \(freshness.wattlineAccessibilityDescription)"
    }
}

/// A single-row port summary for space-constrained surfaces (macOS menu bar / popover).
///
/// Built from `PortCardPresentation` — the same presentation data `PortCard` uses — so the
/// DC/USB-C detail text, semantic colors, and telemetry formatting are never forked between the
/// full-size and compact variants.
///
/// When the port cannot be toggled (`presentation.canToggle == false`), no toggle control is
/// rendered; a plain status readout takes its place. This keeps unsupported capabilities absent
/// from composition rather than disabled.
///
/// `onToggle` takes no value: it signals "the user asked to flip this port's power," leaving the
/// caller (which already knows the current state) to issue the appropriate command. Telemetry is
/// authoritative — this view never predicts the post-toggle state itself.
public struct CompactPortCard: View {
    public let presentation: PortCardPresentation
    public let isPending: Bool
    public let onToggle: (() -> Void)?

    public init(
        presentation: PortCardPresentation,
        isPending: Bool,
        onToggle: (() -> Void)?
    ) {
        self.presentation = presentation
        self.isPending = isPending
        self.onToggle = onToggle
    }

    public var body: some View {
        HStack(spacing: 10) {
            PortIdentityBadge(symbol: presentation.symbol, flow: presentation.flow, compact: true)

            VStack(alignment: .leading, spacing: 1) {
                Text(presentation.title)
                    .font(.caption.weight(.semibold))
                Text(presentation.enabled ? presentation.flow.wattlineName : "Off")
                    .font(.caption2)
                    .foregroundStyle(WattlineTheme.secondaryText)
            }

            Spacer(minLength: 8)

            Text("\(abs(presentation.power).wattlineFormatted()) W")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(WattlineTheme.color(for: presentation.flow))

            trailingControl
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.title)
        .accessibilityValue(accessibilityValue)
    }

    @ViewBuilder
    private var trailingControl: some View {
        if isPending {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Updating \(presentation.title)")
                .accessibilityValue("Pending")
        } else if presentation.canToggle, let onToggle {
            Toggle(
                presentation.toggleLabel ?? "\(presentation.title) power",
                isOn: Binding(
                    get: { presentation.enabled },
                    set: { _ in onToggle() }
                )
            )
            .labelsHidden()
            .tint(WattlineTheme.accent)
            .accessibilityIdentifier(presentation.toggleLabel ?? "\(presentation.title) power")
        } else {
            Text(presentation.enabled ? "ON" : "OFF")
                .font(.caption2.weight(.bold))
                .tracking(0.6)
                .foregroundStyle(presentation.enabled ? WattlineTheme.color(for: presentation.flow) : WattlineTheme.secondaryText)
        }
    }

    private var accessibilityValue: String {
        let power = abs(presentation.power).wattlineFormatted()
        let state = presentation.enabled ? presentation.flow.wattlineName : "Off"
        return isPending ? "\(state), \(power) watts, update pending" : "\(state), \(power) watts"
    }
}
