import Foundation

public typealias DeviceTimestamp = Duration

public enum DeviceMode: Equatable, Sendable {
    case application
    case ota
}
public struct DiscoveredDevice: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let localName: String
    public let rssi: Int
    public let mode: DeviceMode

    public init(id: UUID, localName: String, rssi: Int, mode: DeviceMode) {
        self.id = id
        self.localName = localName
        self.rssi = rssi
        self.mode = mode
    }
}

public struct TransportFailure: Error, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

public enum DeviceEvent: Equatable, Sendable {
    case discovered(DiscoveredDevice)
    case handshakeCompleted(DeviceIdentitySnapshot)
    case connected(UUID)
    case reconnecting(UUID)
    case disconnected(TransportFailure?)
    case battery(BatteryStatus, timestamp: DeviceTimestamp)
    case dc(DCPortStatus, timestamp: DeviceTimestamp)
    case typeC(TypeCPortStatus, timestamp: DeviceTimestamp)
    case transactionDepth(Int)
}

public enum CommandOutcome: Equatable, Sendable {
    case reply(CommandReply)
    case sent
}

public protocol DeviceTransport: Sendable {
    var events: AsyncStream<DeviceEvent> { get }
    func startScan() async throws
    func stopScan() async
    func connect(to id: UUID) async throws
    func disconnect() async
    func perform(_ command: DeviceCommand) async throws -> CommandOutcome
    func refreshTelemetry() async throws
    func synchronizeDeviceTime() async throws
    func readDeviceTimeIfSupported() async throws -> Date?
}

public protocol DeviceClock: Sendable {
    var now: DeviceTimestamp { get async }
    func sleep(for duration: Duration) async throws
}

public struct ContinuousDeviceClock: DeviceClock {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    public init() {
        origin = clock.now
    }

    public var now: DeviceTimestamp {
        get async { origin.duration(to: clock.now) }
    }

    public func sleep(for duration: Duration) async throws {
        try await clock.sleep(for: duration)
    }
}
