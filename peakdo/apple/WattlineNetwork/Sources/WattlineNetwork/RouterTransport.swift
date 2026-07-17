import Foundation
import WattlineCore

public struct RouterEndpoint: Equatable, Sendable, CustomStringConvertible {
    public let scheme: String
    public let host: String
    public let port: Int
    public let token: String
    public let certificateFingerprint: String?
    public let allowsInsecureWAN: Bool

    public init(
        scheme: String,
        host: String,
        port: Int,
        token: String,
        certificateFingerprint: String?,
        allowsInsecureWAN: Bool
    ) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.token = token
        self.certificateFingerprint = certificateFingerprint
        self.allowsInsecureWAN = allowsInsecureWAN
    }

    public var peripheralID: UUID {
        Self.stableUUID(for: "\(scheme.lowercased())://\(host.lowercased()):\(port)")
    }

    public var description: String {
        "RouterEndpoint(scheme: \(scheme), host: \(host), port: \(port), "
            + "token: [REDACTED], certificateFingerprint: \(certificateFingerprint ?? "nil"), "
            + "allowsInsecureWAN: \(allowsInsecureWAN))"
    }

    private static func stableUUID(for value: String) -> UUID {
        var high: UInt64 = 0xcbf2_9ce4_8422_2325
        var low: UInt64 = 0x8422_2325_cbf2_9ce4
        for byte in value.utf8 {
            high ^= UInt64(byte)
            high &*= 0x0000_0100_0000_01b3
            low ^= UInt64(byte) &+ 0x9d
            low &*= 0x0000_0100_0000_01b3
        }
        var bytes = withUnsafeBytes(of: high.bigEndian, Array.init)
            + withUnsafeBytes(of: low.bigEndian, Array.init)
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

public protocol RouterConnectionClock: Sendable {
    var now: DeviceTimestamp { get async }
    func sampleTimestampOrigin() async -> RouterTimestampOrigin
    func sleep(for duration: Duration) async throws
}

public struct SystemRouterConnectionClock: RouterConnectionClock {
    private let deviceClock: ContinuousDeviceClock

    public init() {
        deviceClock = ContinuousDeviceClock()
    }

    public var now: DeviceTimestamp {
        get async { await deviceClock.now }
    }

    public func sampleTimestampOrigin() async -> RouterTimestampOrigin {
        let deviceTimestamp = await deviceClock.now
        return RouterTimestampOrigin(wallClock: Date(), deviceTimestamp: deviceTimestamp)
    }

    public func sleep(for duration: Duration) async throws {
        try await deviceClock.sleep(for: duration)
    }
}

public struct RouterReconnectBackoff: Equatable, Sendable {
    public let delays: [Duration]

    public init(delays: [Duration]) {
        precondition(!delays.isEmpty, "Router reconnect backoff requires at least one delay")
        self.delays = delays
    }

    func delay(forFailure failure: Int) -> Duration {
        delays[min(failure, delays.count - 1)]
    }
}

public actor RouterTransport: DeviceTransport {
    public nonisolated let events: AsyncStream<DeviceEvent>

    private let connection: RouterConnection

    public init(
        endpoint: RouterEndpoint,
        client: any RouterHTTPClient,
        events eventSource: any RouterEventStream,
        clock: any RouterConnectionClock,
        backoff: RouterReconnectBackoff
    ) {
        let pair = AsyncStream<DeviceEvent>.makeStream()
        events = pair.stream
        connection = RouterConnection(
            endpoint: endpoint,
            client: client,
            events: eventSource,
            clock: clock,
            backoff: backoff,
            output: pair.continuation
        )
    }

    public func startScan() async throws {}

    public func stopScan() async {}

    public func makeConnectionScope(for id: UUID) async -> DeviceConnectionScope {
        await connection.makeConnectionScope()
    }

    public func connect(to id: UUID, scope: DeviceConnectionScope) async throws {
        try await connection.connect(to: id, scope: scope)
    }

    public func disconnect() async {
        await connection.disconnect()
    }

    public func perform(_ command: DeviceCommand) async throws -> CommandOutcome {
        throw NetworkError.unsupported("Router commands are Task 5")
    }

    public func refreshTelemetry() async throws {
        throw NetworkError.unsupported("Router telemetry refresh is Task 5")
    }

    public func synchronizeDeviceTime() async throws {
        throw NetworkError.unsupported("Router time synchronization is unsupported")
    }

    public func readDeviceTimeIfSupported() async throws -> Date? {
        throw NetworkError.unsupported("Router device-time reads are unsupported")
    }
}
