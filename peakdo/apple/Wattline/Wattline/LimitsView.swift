import SwiftUI
import WattlineCore
import WattlineUI

struct LimitsView: View {
    @Environment(AppModel.self) private var model
    @State private var selections: [PowerLimitType: PowerLimitLevel] = [:]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if model.limitsLoading && model.limits.isEmpty {
                    ProgressView("Reading power limits…")
                }

                limitSlider("Global", type: .global)
                limitSlider("Input", type: .input)
                limitSlider("Output", type: .output)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Runtime limit")
                        .font(.headline)
                    StatTile(
                        label: "Runtime limit",
                        value: model.limits[.runtime].map { "\($0.watts)" } ?? "—",
                        unit: model.limits[.runtime] == nil ? nil : "W",
                        symbol: "bolt.fill"
                    )
                }
                .accessibilityIdentifier("Runtime limit section")

                Text("Limits are stored on the device and survive restarts. Setting a low input limit slows charging; a low output limit may cause connected laptops to charge slowly or not at all.")
                    .font(.footnote)
                    .foregroundStyle(WattlineTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(WattlineTheme.raisedSurface, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityIdentifier("Power limits safety note")
            }
            .padding()
        }
        .background(WattlineTheme.surface.ignoresSafeArea())
        .foregroundStyle(.white)
        .navigationTitle("USB-C Power Limits")
        .task {
            await model.loadLimits()
            selections = model.limits
        }
        .onChange(of: model.limits) { _, values in selections = values }
        .onChange(of: model.limitsRevision) { _, _ in selections = model.limits }
        .accessibilityIdentifier("Limits screen")
    }

    @ViewBuilder
    private func limitSlider(_ label: String, type: PowerLimitType) -> some View {
        if let current = selections[type] ?? model.limits[type] {
            LimitSlider(
                label,
                selection: binding(type, fallback: current),
                isPending: model.pendingLimits.contains(type),
                onReset: { Task { await model.resetLimit(type) } },
                onEditingChanged: { editing in
                    guard !editing, let level = selections[type] else { return }
                    Task { await model.setLimit(type, level: level) }
                }
            )
        } else if model.limitReadFailures.contains(type) {
            Label("\(label) limit unavailable", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 90)
        } else {
            ProgressView("Reading \(label.lowercased()) limit…")
                .frame(maxWidth: .infinity, minHeight: 90)
        }
    }

    private func binding(_ type: PowerLimitType, fallback: PowerLimitLevel) -> Binding<PowerLimitLevel> {
        Binding(
            get: { selections[type] ?? fallback },
            set: { selections[type] = $0 }
        )
    }
}
