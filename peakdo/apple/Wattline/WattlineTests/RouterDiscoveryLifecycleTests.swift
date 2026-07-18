import Foundation
import WattlineCore
import WattlineNetwork
import XCTest
@testable import Wattline

@MainActor
final class RouterDiscoveryLifecycleTests: XCTestCase {
    func testScanLifecycleStartsOnceStopsOnExitAndRejectsOldSessionResults() async throws {
        let source = RecordingRouterDiscoverySource()
        let model = makeModel(discovery: RouterDiscovery(source: source))

        model.startDiscovery()
        model.startDiscovery()
        try await waitUntil { source.startCount == 1 }

        model.stopDiscovery()
        try await waitUntil { source.cancelCount == 1 }
        source.yield([serviceRecord(id: "DC:04:5A:EB:72:2B")], session: 0)
        await Task.yield()
        XCTAssertTrue(model.discoveredRouters.isEmpty)

        model.startDiscovery()
        try await waitUntil { source.startCount == 2 }
        source.yield([serviceRecord(id: "AA:BB:CC:DD:EE:FF")], session: 1)
        try await waitUntil { await model.discoveredRouters.count == 1 }
        XCTAssertEqual(model.discoveredRouters.first?.deviceID, "AABBCCDDEEFF")

        source.yield([serviceRecord(id: "DC:04:5A:EB:72:2B")], session: 0)
        await Task.yield()
        XCTAssertEqual(model.discoveredRouters.first?.deviceID, "AABBCCDDEEFF")
    }

    private func makeModel(discovery: RouterDiscovery) -> RouterConnectionModel {
        RouterConnectionModel(
            hostStore: RouterHostStore(backend: DiscoveryHostBackend()),
            credentialStore: RouterCredentialStore(backend: DiscoveryCredentialBackend()),
            discovery: discovery,
            enrollmentClientFactory: { _ in
                throw NetworkError.unsupported("not used")
            },
            transportFactory: { _, _ in DiscoveryNoopTransport() }
        )
    }

    private func serviceRecord(id: String) -> RouterServiceRecord {
        RouterServiceRecord(
            serviceName: "wattline-\(id)",
            domain: "local.",
            host: "wattline.local.",
            port: 8377,
            txt: [
                "api": Data("1".utf8),
                "auth": Data("pin".utf8),
                "id": Data(id.utf8),
                "model": Data("BP4SL3V2".utf8),
                "cid": Data("0305".utf8),
                "features": Data("00000fff".utf8),
                "tls": Data("none".utf8),
            ]
        )
    }
}

private final class RecordingRouterDiscoverySource: RouterDiscoverySource, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncStream<[RouterServiceRecord]>.Continuation] = []
    private var starts = 0
    private var cancels = 0

    var startCount: Int { lock.withLock { starts } }
    var cancelCount: Int { lock.withLock { cancels } }

    func snapshots(serviceType: String) -> AsyncStream<[RouterServiceRecord]> {
        AsyncStream { continuation in
            lock.withLock {
                starts += 1
                continuations.append(continuation)
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.cancels += 1 }
            }
        }
    }

    func yield(_ records: [RouterServiceRecord], session: Int) {
        lock.withLock {
            guard continuations.indices.contains(session) else { return }
            continuations[session].yield(records)
        }
    }
}

private final class DiscoveryHostBackend: RouterHostKeyValueStore, @unchecked Sendable {
    func data(forKey key: String) -> Data? { nil }
    func set(_ data: Data, forKey key: String) throws {}
    func removeValue(forKey key: String) {}
}

private actor DiscoveryCredentialBackend: RouterCredentialBackend {
    func read(account: String) async throws -> Data? { nil }
    func save(_ data: Data, account: String) async throws {}
    func delete(account: String) async throws {}
}

private actor DiscoveryNoopTransport: DeviceTransport {
    nonisolated let events = AsyncStream<DeviceEvent> { $0.finish() }
    func startScan() async throws {}
    func stopScan() async {}
    func makeConnectionScope(for id: UUID) async -> DeviceConnectionScope {
        DeviceConnectionScope(peripheralID: id, sessionID: UUID())
    }
    func connect(to id: UUID, scope: DeviceConnectionScope) async throws {}
    func disconnect() async {}
    func perform(_ command: DeviceCommand) async throws -> CommandOutcome { .sent }
    func refreshTelemetry() async throws {}
    func synchronizeDeviceTime() async throws {}
    func readDeviceTimeIfSupported() async throws -> Date? { nil }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
