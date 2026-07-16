import SwiftUI
import WidgetKit
import WattlineCore

struct WattlineWidgetProvider: TimelineProvider {
    private let source: any WattlineWidgetSnapshotSource
    init(source: any WattlineWidgetSnapshotSource = StoreWidgetSnapshotSource(store: .widgetProduction())) { self.source = source }

    func placeholder(in context: Context) -> WattlineWidgetEntry { placeholderEntry() }
    func placeholderEntry() -> WattlineWidgetEntry {
        WattlineWidgetEntry(date: Date(timeIntervalSince1970: 0), snapshot: Self.sampleSnapshot)
    }
    func getSnapshot(in context: Context, completion: @escaping (WattlineWidgetEntry) -> Void) {
        let callback = CompletionBox(completion)
        Task { @MainActor in
            let entry = WattlineWidgetEntry(date: Date(), snapshot: await readAvailableSnapshot())
            callback.call(entry)
        }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<WattlineWidgetEntry>) -> Void) {
        let callback = CompletionBox(completion)
        Task { @MainActor in
            let entry = WattlineWidgetEntry(date: Date(), snapshot: await readAvailableSnapshot())
            callback.call(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
        }
    }

    func snapshotEntry() async -> WattlineWidgetEntry { WattlineWidgetEntry(date: Date(), snapshot: await readAvailableSnapshot()) }
    func timelineEntry() async -> WattlineWidgetEntry { await snapshotEntry() }

    private func readAvailableSnapshot() async -> SharedDeviceSnapshot? {
        guard let snapshot = await source.read(), snapshot.battery != nil else { return nil }
        return snapshot
    }

    private static let sampleSnapshot = SharedDeviceSnapshot(
        peripheralID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!, featuresRawValue: 0,
        battery: SharedBatterySnapshot(enabled: true, status: .idle, isFull: false, maxCapacity: 100, capacity: 84, level: 84, voltage: 12, current: 0, power: 0, remainingMinutes: 90),
        dc: nil, typeC: nil, connection: .live, observedAt: Date(timeIntervalSince1970: 0))
}

private final class CompletionBox<Value>: @unchecked Sendable {
    private let completion: (Value) -> Void
    init(_ completion: @escaping (Value) -> Void) { self.completion = completion }
    func call(_ value: Value) { completion(value) }
}

struct WattlineWidgetView: View {
    let entry: WattlineWidgetEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        Group {
            if let snapshot = entry.snapshot { content(snapshot) } else { unavailable }
        }.widgetURL(URL(string: "wattline://dashboard"))
    }
    private var unavailable: some View { VStack(alignment: .leading) { Text("Wattline").font(.headline); Text("Unavailable").foregroundStyle(.secondary) } }
    @ViewBuilder private func content(_ snapshot: SharedDeviceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text("\(snapshot.battery?.level ?? 0)%").font(.system(size: 30, weight: .bold, design: .monospaced)); Spacer(); Text(state(snapshot)).font(.caption).foregroundStyle(color(snapshot)) }
            if family == .systemMedium {
                if let minutes = snapshot.battery?.remainingMinutes { Text(runtime(minutes, status: snapshot.battery?.status)).font(.caption).fontDesign(.monospaced) }
                HStack { Text("DC \(watts(snapshot.dc)) W"); Text("USB-C \(watts(snapshot.typeC)) W") }.font(.caption2).fontDesign(.monospaced)
            }
            if snapshot.connection != .live {
                Text(staleness(snapshot)).font(.caption2).foregroundStyle(.secondary)
            }
        }.padding()
    }
    private func state(_ snapshot: SharedDeviceSnapshot) -> String { snapshot.battery?.status == .charging ? "Charging" : snapshot.battery?.status == .discharging ? "Discharging" : "Idle" }
    private func color(_ snapshot: SharedDeviceSnapshot) -> Color { snapshot.battery?.status == .charging ? .green : snapshot.battery?.status == .discharging ? .orange : .secondary }
    private func watts(_ port: SharedPortSnapshot?) -> String { guard let p = port, p.power.isFinite else { return "—" }; return String(format: "%.0f", p.power) }
    private func runtime(_ minutes: UInt16, status: PowerFlow?) -> String { "\(status == .discharging ? "Left" : "To full"): \(minutes / 60)h \(minutes % 60)m" }
    private func staleness(_ snapshot: SharedDeviceSnapshot) -> String { let age = snapshot.age(now: Date()); return age < 60 ? "As of now" : "As of \(Int(age / 60))m ago" }
}
