import Foundation
import WattlineCore

public struct RouterEndpoint: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let scheme: String
    public let host: String
    public let port: Int
    public let certificateFingerprint: String?
    public let allowsInsecureWAN: Bool

    public init(
        scheme: String,
        host: String,
        port: Int,
        certificateFingerprint: String?,
        allowsInsecureWAN: Bool
    ) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.certificateFingerprint = certificateFingerprint
        self.allowsInsecureWAN = allowsInsecureWAN
    }

    public var peripheralID: UUID {
        Self.stableUUID(for: "\(normalizedScheme)://\(normalizedHost):\(port)")
    }

    public var description: String {
        "RouterEndpoint(scheme: \(scheme), host: \(host), port: \(port), "
            + "certificateFingerprint: \(certificateFingerprint ?? "nil"), "
            + "allowsInsecureWAN: \(allowsInsecureWAN))"
    }

    public var debugDescription: String { description }

    private var normalizedScheme: String {
        scheme.lowercased()
    }

    private var normalizedHost: String {
        let lowercaseHost = host.lowercased()
        guard lowercaseHost.count > 1, lowercaseHost.last == "." else {
            return lowercaseHost
        }
        return String(lowercaseHost.dropLast())
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

/// An in-memory bearer credential whose textual representations never reveal its value.
/// Persistence is deliberately left to the credential provider implementation added in Task 7.
public struct RouterCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    let token: String

    public init(token: String) {
        self.token = token
    }

    public var description: String { "RouterCredential([REDACTED])" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["credential": "[REDACTED]"], displayStyle: .struct)
    }
}

public protocol RouterCredentialProvider: Sendable {
    func credential(for endpoint: RouterEndpoint) async throws -> RouterCredential
}

/// A transient provider for callers that already hold a token in memory.
/// It performs no persistence and can be replaced by Task 7's Keychain-backed provider.
public struct TransientRouterCredentialProvider: RouterCredentialProvider,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    private let credential: RouterCredential

    public init(token: String) {
        credential = RouterCredential(token: token)
    }

    public func credential(for endpoint: RouterEndpoint) async throws -> RouterCredential {
        credential
    }

    public var description: String { "TransientRouterCredentialProvider([REDACTED])" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["credential": "[REDACTED]"], displayStyle: .struct)
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

/// PIN enrollment issues a managed client credential. Administrator routes are
/// opt-in because the router never returns its bootstrap credential to clients.
public enum RouterAccessLevel: String, Equatable, Sendable {
    case client
    case administrator
}

public actor RouterTransport: DeviceTransport {
    public nonisolated let events: AsyncStream<DeviceEvent>

    private let connection: RouterConnection
    private let accessLevel: RouterAccessLevel
    private let transactions = SerializedTransactions()
    private let commandMapper = RouterCommandMapper()

    public init(
        endpoint: RouterEndpoint,
        credentials: any RouterCredentialProvider,
        client: any RouterHTTPClient,
        events eventSource: any RouterEventStream,
        clock: any RouterConnectionClock,
        backoff: RouterReconnectBackoff
    ) {
        self.init(
            endpoint: endpoint,
            accessLevel: .client,
            credentials: credentials,
            client: client,
            events: eventSource,
            clock: clock,
            backoff: backoff
        )
    }

    public init(
        endpoint: RouterEndpoint,
        accessLevel: RouterAccessLevel,
        credentials: any RouterCredentialProvider,
        client: any RouterHTTPClient,
        events eventSource: any RouterEventStream,
        clock: any RouterConnectionClock,
        backoff: RouterReconnectBackoff
    ) {
        self.init(
            endpoint: endpoint,
            accessLevel: accessLevel,
            credentials: credentials,
            client: client,
            events: eventSource,
            clock: clock,
            backoff: backoff,
            beforeSnapshotYield: {}
        )
    }

    init(
        endpoint: RouterEndpoint,
        accessLevel: RouterAccessLevel = .client,
        credentials: any RouterCredentialProvider,
        client: any RouterHTTPClient,
        events eventSource: any RouterEventStream,
        clock: any RouterConnectionClock,
        backoff: RouterReconnectBackoff,
        beforeSnapshotYield: @escaping @Sendable () async -> Void
    ) {
        let pair = AsyncStream<DeviceEvent>.makeStream()
        events = pair.stream
        self.accessLevel = accessLevel
        connection = RouterConnection(
            endpoint: endpoint,
            credentials: credentials,
            client: client,
            events: eventSource,
            clock: clock,
            backoff: backoff,
            output: pair.continuation,
            beforeSnapshotYield: beforeSnapshotYield
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
        let request = try commandMapper.route(for: command)
        return try await transactions.enqueue { [connection] in
            try await connection.perform(command, request: request)
        }
    }

    public func refreshTelemetry() async throws {
        try await transactions.enqueue { [connection] in
            try await connection.refreshTelemetry()
        }
    }

    public func synchronizeDeviceTime() async throws {
        guard accessLevel == .administrator else { return }
        try await transactions.enqueue { [connection] in
            try await connection.executeBodyless("POST", "/api/v1/device/clock/sync")
        }
    }

    public func readDeviceTimeIfSupported() async throws -> Date? {
        guard accessLevel == .administrator else { return nil }
        return try await transactions.enqueue { [connection] in
            try await connection.readDeviceTime()
        }
    }
}
