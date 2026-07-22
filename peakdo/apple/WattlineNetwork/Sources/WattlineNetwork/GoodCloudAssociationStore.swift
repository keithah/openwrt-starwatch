import Foundation

public struct GoodCloudAssociation: Codable, Equatable, Sendable {
    public let hostID: UUID
    public let routerMAC: String
    public let goodCloudDeviceID: String
    public let name: String
    public let mac: String
    public let ddns: String?
    public let model: String
    public let isOnline: Bool

    public init(
        hostID: UUID,
        routerMAC: String,
        goodCloudDeviceID: String,
        name: String,
        mac: String,
        ddns: String?,
        model: String,
        isOnline: Bool
    ) {
        self.hostID = hostID
        self.routerMAC = routerMAC
        self.goodCloudDeviceID = goodCloudDeviceID
        self.name = name
        self.mac = mac
        self.ddns = ddns
        self.model = model
        self.isOnline = isOnline
    }

    public init(hostID: UUID, routerMAC: String, device: GoodCloudDeviceSummary) {
        self.init(
            hostID: hostID,
            routerMAC: routerMAC,
            goodCloudDeviceID: device.id,
            name: device.name,
            mac: device.mac,
            ddns: device.ddns,
            model: device.model,
            isOnline: device.isOnline
        )
    }
}

public protocol GoodCloudAssociationKeyValueStore: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

public actor GoodCloudAssociationStore {
    private static let storageKey = "wattline.goodCloudAssociations"

    private let backend: any GoodCloudAssociationKeyValueStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(backend: any GoodCloudAssociationKeyValueStore) {
        self.backend = backend
    }

    public init(defaults: UserDefaults = .standard) {
        self.backend = UserDefaultsAssociationBackend(defaults: defaults)
    }

    public func allAssociations() -> [GoodCloudAssociation] {
        (try? load()) ?? []
    }

    public func association(forHostID hostID: UUID) -> GoodCloudAssociation? {
        allAssociations().first { $0.hostID == hostID }
    }

    public func save(_ association: GoodCloudAssociation) throws {
        var associations = try load()
        if let index = associations.firstIndex(where: { $0.hostID == association.hostID }) {
            associations[index] = association
        } else {
            associations.append(association)
        }
        try persist(associations)
    }

    public func remove(hostID: UUID) throws {
        var associations = try load()
        associations.removeAll { $0.hostID == hostID }
        try persist(associations)
    }

    public nonisolated func suggestedDevice(
        forRouterMAC routerMAC: String,
        devices: [GoodCloudDeviceSummary]
    ) -> GoodCloudDeviceSummary? {
        guard let normalizedRouterMAC = DeviceIdentityDeduplicator.normalizedMAC(routerMAC) else {
            return nil
        }
        return devices.first {
            DeviceIdentityDeduplicator.normalizedMAC($0.mac) == normalizedRouterMAC
        }
    }

    private func load() throws -> [GoodCloudAssociation] {
        guard let data = backend.data(forKey: Self.storageKey) else { return [] }
        return try decoder.decode([GoodCloudAssociation].self, from: data)
    }

    private func persist(_ associations: [GoodCloudAssociation]) throws {
        backend.set(try encoder.encode(associations), forKey: Self.storageKey)
    }
}

private final class UserDefaultsAssociationBackend: GoodCloudAssociationKeyValueStore, @unchecked Sendable {
    let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func data(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    func set(_ data: Data?, forKey key: String) {
        defaults.set(data, forKey: key)
    }
}
