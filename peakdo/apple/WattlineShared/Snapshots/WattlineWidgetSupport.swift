import Foundation
import WidgetKit
import WattlineCore

protocol WattlineWidgetSnapshotSource: Sendable {
    func read() async -> SharedDeviceSnapshot?
}

struct WattlineWidgetEntry: TimelineEntry, Sendable, Equatable {
    let date: Date
    let snapshot: SharedDeviceSnapshot?
}

struct StoreWidgetSnapshotSource: WattlineWidgetSnapshotSource {
    let store: SharedSnapshotStore
    func read() async -> SharedDeviceSnapshot? { await store.read() }
}

extension SharedSnapshotStore {
    static func widgetProduction() -> SharedSnapshotStore {
        SharedSnapshotStore(backend: WidgetAppGroupSnapshotBackend())
    }
}

private struct WidgetAppGroupSnapshotBackend: SnapshotKeyValueStore, @unchecked Sendable {
    private let defaults: UserDefaults
    init() { defaults = UserDefaults(suiteName: "group.com.keithah.wattline") ?? .standard }
    func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    func set(_ data: Data, forKey key: String) { defaults.set(data, forKey: key) }
    func removeValue(forKey key: String) { defaults.removeObject(forKey: key) }
}
