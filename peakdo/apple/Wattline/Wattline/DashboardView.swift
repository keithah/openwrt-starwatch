import SwiftUI
import WattlineCore
import WattlineUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("batteryHeroStyle") private var heroStyleRaw = BatteryHeroStyle.segmented.rawValue

    private var heroStyle: BatteryHeroStyle {
        BatteryHeroStyle(rawValue: heroStyleRaw) ?? .segmented
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                connectionContext

                ForEach(Array(DashboardSections(capabilities: model.capabilities).enumerated()), id: \.offset) { _, section in
                    sectionView(section)
                }

                if model.isDemo {
                    Button(model.demoChargerConnected ? "Unplug charger" : "Plug in charger") {
                        model.setDemoChargerConnected(!model.demoChargerConnected)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("Demo charger")
                }
            }
            .padding()
        }
        .background(WattlineTheme.surface.ignoresSafeArea())
        .foregroundStyle(.white)
        .navigationTitle(model.connectedName ?? "Wattline")
        .refreshable { await model.refreshTelemetry() }
        .accessibilityIdentifier("Dashboard")
    }

    @ViewBuilder
    private func sectionView(_ section: DashboardSection) -> some View {
        switch section {
        case .batteryHero:
            if let battery = model.state.battery {
                VStack(alignment: .leading, spacing: 6) {
                    BatteryHero(status: battery, style: heroStyle, freshness: model.state.freshness)
                        .onLongPressGesture { toggleHeroStyle() }
                        .accessibilityIdentifier("Battery hero")
                    Label(
                        heroStyle == .segmented ? "Segmented battery meter" : "Gauge battery meter",
                        systemImage: heroStyle == .segmented ? "rectangle.split.3x1" : "gauge.with.dots.needle.67percent"
                    )
                    .font(.caption)
                    .foregroundStyle(WattlineTheme.secondaryText)
                    .padding(.leading, 4)
                }
            } else {
                ProgressView("Loading battery…")
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        case .dcHero:
            if let dc = model.state.dc {
                DCPortHero(status: dc, freshness: model.state.freshness)
            }
        case .batteryStats:
            if let battery = model.state.battery {
                HStack(spacing: 10) {
                    StatTile(label: "Capacity", value: "\(Int(battery.capacity)) / \(Int(battery.maxCapacity))", unit: "Wh")
                    StatTile(label: "Runtime", value: runtime(battery.remainingMinutes))
                    StatTile(label: "Voltage", value: formatted(battery.voltage), unit: "V")
                }
            }
        case .dcCard:
            if let dc = model.state.dc {
                PortCard(
                    dcStatus: dc,
                    canToggle: DashboardSections(capabilities: model.capabilities).controlPresentation(for: .dc) == .toggle,
                    isPending: isPending(.dcEnabled(dc.enabled)),
                    freshness: model.state.freshness,
                    onToggle: { model.setDC($0) }
                )
                .accessibilityIdentifier("DC Port card")
            }
        case .usbCard:
            if let typeC = model.state.typeC {
                PortCard(
                    title: "USB-C Port",
                    symbol: "cable.connector",
                    enabled: typeC.mode == .output || typeC.mode == .inputAndOutput,
                    flow: typeC.status,
                    voltage: typeC.voltage,
                    current: typeC.current,
                    power: typeC.power,
                    detail: typeC.isDCInput == true ? "DC input" : nil,
                    canToggle: DashboardSections(capabilities: model.capabilities).controlPresentation(for: .usb) == .toggle,
                    isPending: model.state.pendingMutations.contains { mutation in
                        mutation.reconciler == .typeCOutput(true) || mutation.reconciler == .typeCOutput(false)
                    },
                    freshness: model.state.freshness,
                    toggleLabel: "USB-C Output",
                    onToggle: { model.setTypeCOutput($0) }
                )
                .accessibilityIdentifier("USB-C Port card")
            }
        case .limitsLink:
            NavigationLink {
                LimitsView()
            } label: {
                Label("USB-C Power Limits", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(WattlineTheme.raisedSurface, in: RoundedRectangle(cornerRadius: 16))
            }
            .accessibilityIdentifier("USB-C Power Limits")
        }
    }

    @ViewBuilder
    private var connectionContext: some View {
        switch model.connectionStatus {
        case .connected:
            if model.state.freshness == .stale {
                Label("Last updated more than 10 seconds ago", systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            }
        case .reconnecting:
            Label("Reconnecting… Last-known values are shown.", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case let .disconnected(message):
            Label(message ?? "Disconnected. Reconnecting…", systemImage: "bolt.slash")
                .foregroundStyle(.secondary)
        }
    }

    private func isPending(_ reconciler: MutationReconciler) -> Bool {
        model.state.pendingMutations.contains { $0.reconciler == reconciler }
    }

    private func toggleHeroStyle() {
        heroStyleRaw = heroStyle == .segmented ? BatteryHeroStyle.gauge.rawValue : BatteryHeroStyle.segmented.rawValue
    }

    private func runtime(_ minutes: UInt16) -> String {
        "\(minutes / 60) h \(minutes % 60) m"
    }

    private func formatted(_ value: Double) -> String {
        value.isFinite ? value.formatted(.number.precision(.fractionLength(1))) : "—"
    }
}
