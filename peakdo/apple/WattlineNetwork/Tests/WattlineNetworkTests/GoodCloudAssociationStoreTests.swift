import Foundation
import XCTest
@testable import WattlineNetwork

final class GoodCloudAssociationStoreTests: XCTestCase {
    private let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    func test_exactNormalizedMACIsSuggestedButNotPersistedUntilSelected() async throws {
        let backend = MemoryAssociationBackend()
        let store = GoodCloudAssociationStore(backend: backend)
        let devices = [GoodCloudDeviceSummary.fixture]

        XCTAssertEqual(
            store.suggestedDevice(forRouterMAC: "aa:bb:cc:dd:ee:ff", devices: devices)?.id,
            "42"
        )
        let associationBeforeSave = await store.association(forHostID: hostID)
        XCTAssertNil(associationBeforeSave)

        try await store.save(.init(
            hostID: hostID,
            routerMAC: "AA:BB:CC:DD:EE:FF",
            device: devices[0]
        ))

        let associationAfterSave = await store.association(forHostID: hostID)
        XCTAssertEqual(associationAfterSave?.goodCloudDeviceID, "42")
    }

    func test_saveReplacesAssociationForSameHost() async throws {
        let backend = MemoryAssociationBackend()
        let store = GoodCloudAssociationStore(backend: backend)
        try await store.save(.fixture)
        let replacement = GoodCloudAssociation(
            hostID: GoodCloudAssociation.fixture.hostID,
            routerMAC: "11:22:33:44:55:66",
            goodCloudDeviceID: "99",
            name: "Replacement",
            mac: "11-22-33-44-55-66",
            ddns: nil,
            model: "GL-MT3000",
            isOnline: false
        )

        try await store.save(replacement)
        let associations = await store.allAssociations()

        XCTAssertEqual(associations, [replacement])
    }

    func test_removingAssociationMutatesOnlyGoodCloudAssociationKey() async throws {
        let backend = MemoryAssociationBackend()
        let store = GoodCloudAssociationStore(backend: backend)
        try await store.save(.fixture)
        backend.clearRecordedKeys()

        try await store.remove(hostID: GoodCloudAssociation.fixture.hostID)
        let association = await store.association(forHostID: GoodCloudAssociation.fixture.hostID)

        XCTAssertNil(association)
        XCTAssertEqual(backend.recordedKeys, ["wattline.goodCloudAssociations"])
    }

    func test_corruptStoredDataThrowsWithoutOverwritingIt() async {
        let data = Data("not-json".utf8)
        let backend = MemoryAssociationBackend(initialData: data)
        let store = GoodCloudAssociationStore(backend: backend)

        do {
            try await store.save(.fixture)
            XCTFail("Expected decoding to fail")
        } catch {
            XCTAssertEqual(backend.data(forKey: "wattline.goodCloudAssociations"), data)
        }
    }
}

private final class MemoryAssociationBackend: GoodCloudAssociationKeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data]
    private var keys: [String] = []

    init(initialData: Data? = nil) {
        storage = initialData.map { ["wattline.goodCloudAssociations": $0] } ?? [:]
    }

    var recordedKeys: [String] { lock.withLock { keys } }

    func data(forKey key: String) -> Data? {
        lock.withLock { storage[key] }
    }

    func set(_ data: Data?, forKey key: String) {
        lock.withLock {
            storage[key] = data
            keys.append(key)
        }
    }

    func clearRecordedKeys() {
        lock.withLock { keys.removeAll() }
    }
}

private extension GoodCloudDeviceSummary {
    static let fixture = GoodCloudDeviceSummary(
        id: "42",
        name: "X3000",
        mac: "AA-BB-CC-DD-EE-FF",
        ddns: "x3000",
        model: "GL-X3000",
        isOnline: true
    )
}

private extension GoodCloudAssociation {
    static let fixture = GoodCloudAssociation(
        hostID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        routerMAC: "AA:BB:CC:DD:EE:FF",
        goodCloudDeviceID: "42",
        name: "X3000",
        mac: "AA-BB-CC-DD-EE-FF",
        ddns: "x3000",
        model: "GL-X3000",
        isOnline: true
    )
}
