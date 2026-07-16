import Foundation

public protocol SnapshotKeyValueStore: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data, forKey key: String)
    func removeValue(forKey key: String)
}

public actor SharedSnapshotStore {
    public static let defaultKey = "wattline.sharedDeviceSnapshot"
    private let backend: any SnapshotKeyValueStore
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    public init(backend: any SnapshotKeyValueStore, key: String = SharedSnapshotStore.defaultKey) { self.backend = backend; self.key = key }
    public func read() -> SharedDeviceSnapshot? {
        guard let data = backend.data(forKey: key), let envelope = try? decoder.decode(SharedSnapshotEnvelope.self, from: data), envelope.schemaVersion == 1 else { return nil }
        return envelope.snapshot
    }
    public func write(_ snapshot: SharedDeviceSnapshot) throws { let data = try encoder.encode(SharedSnapshotEnvelope(snapshot: snapshot)); backend.set(data, forKey: key) }
    public func clear() { backend.removeValue(forKey: key) }
}
