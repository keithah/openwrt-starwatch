import Foundation

public struct DemoIdentity: Equatable, Sendable {
    public let name: String
    public let cid: UInt16
    public let features: FeatureFlags
    public let firmware: String

    public init(name: String, cid: UInt16, features: FeatureFlags, firmware: String) {
        self.name = name
        self.cid = cid
        self.features = features
        self.firmware = firmware
    }
}

public struct DemoSnapshot: Equatable, Sendable {
    public let battery: BatteryStatus
    public let dc: DCPortStatus
    public let typeC: TypeCPortStatus
    public let limits: [PowerLimitType: PowerLimitLevel]
    public let chargerConnected: Bool

    public init(
        battery: BatteryStatus,
        dc: DCPortStatus,
        typeC: TypeCPortStatus,
        limits: [PowerLimitType: PowerLimitLevel],
        chargerConnected: Bool
    ) {
        self.battery = battery
        self.dc = dc
        self.typeC = typeC
        self.limits = limits
        self.chargerConnected = chargerConnected
    }
}

public enum DemoTransportError: Error, Equatable, Sendable {
    case unsupportedCommand
    case malformedCommand
}

public actor DemoTransport: DeviceTransport {
    public nonisolated let events: AsyncStream<DeviceEvent>

    public static let identity = DemoIdentity(
        name: "Link-Power 2 (Demo)",
        cid: 0x0305,
        features: FeatureFlags(rawValue: 0x7FFF),
        firmware: "1.4.9"
    )

    public static let deviceID = UUID(uuidString: "57415454-4C49-4E45-8000-000000000305")!
    private static let initialLimits: [PowerLimitType: PowerLimitLevel] = [
        .global: .watts140,
        .input: .watts140,
        .output: .watts140,
    ]
    private static let resetLimits: [PowerLimitType: PowerLimitLevel] = [
        .global: .watts65,
        .input: .watts65,
        .output: .watts65,
    ]
    private static let identitySnapshot = DeviceIdentitySnapshot(
        peripheralID: deviceID,
        advertisedName: identity.name,
        mode: .application,
        modelNumber: "BP4SL3V2",
        hardwareRevision: "V5#0305",
        otaFirmwareRevision: nil,
        appFirmwareRevision: identity.firmware,
        cid: identity.cid,
        rawFeatures: identity.features.rawValue,
        capabilities: DeviceCapabilities(features: identity.features)
    )

    private let continuation: AsyncStream<DeviceEvent>.Continuation
    private let clock: any DeviceClock
    private let scopeSeed: UInt64
    private let typeCOutputCurrent: Double
    private let transactions = SerializedTransactions()
    private var random: SeededGenerator
    private var telemetryTask: Task<Void, Never>?
    private var connected = false
    private var connectionCount: UInt64 = 0
    private var activeScope: DeviceConnectionScope?
    private var dcEnabled = true
    private var typeCOutputPreferred = true
    private var bypassEnabled = false
    private var chargerConnected = false
    private var limits = DemoTransport.initialLimits
    private var simulatedDeviceTime = Date()

    public private(set) var snapshot: DemoSnapshot
    public private(set) var pendingTransactionCount = 0
    public private(set) var maximumPendingTransactionCount = 0

    public init(
        seed: UInt64,
        clock: any DeviceClock = ContinuousDeviceClock(),
        typeCOutputCurrent: Double = 1.4
    ) {
        let pair = AsyncStream<DeviceEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
        self.clock = clock
        scopeSeed = seed
        self.typeCOutputCurrent = typeCOutputCurrent
        random = SeededGenerator(seed: seed)
        snapshot = Self.makeSnapshot(
            dcEnabled: true,
            typeCOutputPreferred: true,
            bypassEnabled: false,
            chargerConnected: false,
            limits: Self.initialLimits,
            typeCOutputCurrent: typeCOutputCurrent
        )
    }

    deinit {
        telemetryTask?.cancel()
        continuation.finish()
    }

    public func startScan() async throws {
        continuation.yield(.discovered(DiscoveredDevice(
            id: Self.deviceID,
            localName: Self.identity.name,
            rssi: -48,
            mode: .application
        )))
    }

    public func stopScan() async {}

    public func makeConnectionScope(for id: UUID) async -> DeviceConnectionScope {
        connectionCount &+= 1
        return DeviceConnectionScope(
            peripheralID: id,
            sessionID: Self.deterministicSessionID(seed: scopeSeed, connection: connectionCount)
        )
    }

    public func connect(to id: UUID, scope: DeviceConnectionScope) async throws {
        guard !connected else { return }
        precondition(scope.peripheralID == id)
        connected = true
        activeScope = scope
        continuation.yield(.handshakeCompleted(Self.identitySnapshot, scope: scope))
        continuation.yield(.connected(scope))
        let timestamp = await clock.now
        guard connected else { return }
        snapshot = makeSnapshot(jittered: false)
        emitCurrentSnapshot(at: timestamp)
        startTelemetryCadence()
    }

    @discardableResult
    public func connectDemo() async throws -> DemoIdentity {
        let scope = await makeConnectionScope(for: Self.deviceID)
        try await connect(to: Self.deviceID, scope: scope)
        return Self.identity
    }

    public func disconnect() async {
        guard connected, let scope = activeScope else { return }
        connected = false
        activeScope = nil
        telemetryTask?.cancel()
        telemetryTask = nil
        continuation.yield(.disconnected(scope, nil))
    }

    private static func deterministicSessionID(seed: UInt64, connection: UInt64) -> UUID {
        let bytes = withUnsafeBytes(of: seed.bigEndian, Array.init)
            + withUnsafeBytes(of: connection.bigEndian, Array.init)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    public func perform(_ command: DeviceCommand) async throws -> CommandOutcome {
        beginTransaction()
        do {
            let outcome = try await transactions.enqueue { [self] in
                try await execute(command)
            }
            endTransaction()
            return outcome
        } catch {
            endTransaction()
            throw error
        }
    }

    public func refreshTelemetry() async throws {
        beginTransaction()
        do {
            try await transactions.enqueue { [self] in
                await executeTelemetryRefresh()
            }
            endTransaction()
        } catch {
            endTransaction()
            throw error
        }
    }

    public func synchronizeDeviceTime() async throws {
        beginTransaction()
        do {
            try await transactions.enqueue { [self] in
                await updateSimulatedDeviceTime()
            }
            endTransaction()
        } catch {
            endTransaction()
            throw error
        }
    }

    public func readDeviceTimeIfSupported() async throws -> Date? {
        beginTransaction()
        do {
            let date = try await transactions.enqueue { [self] in
                await currentSimulatedDeviceTime()
            }
            endTransaction()
            return date
        } catch {
            endTransaction()
            throw error
        }
    }

    public func setChargerConnected(_ connected: Bool) async {
        beginTransaction()
        _ = try? await transactions.enqueue { [self] in
            await executeChargerConnection(connected)
        }
        endTransaction()
    }

    private func updateSimulatedDeviceTime() {
        simulatedDeviceTime = Date()
    }

    private func currentSimulatedDeviceTime() -> Date {
        simulatedDeviceTime
    }

    private func execute(_ command: DeviceCommand) async throws -> CommandOutcome {

        if command.request.target == .factoryMode {
            await disconnect()
            return .sent
        }
        if command.request.target == .command,
           command.request.command?.command == .restart {
            await disconnect()
            // Reconnect is intentionally broker-driven after the scoped
            // disconnect; this keeps Demo behavior aligned with the real
            // transport and prevents a connected fast-path from succeeding.
            return .sent
        }

        guard command.request.target == .command, let request = command.request.command else {
            throw DemoTransportError.unsupportedCommand
        }

        let result: UInt8
        let payload: [UInt8]
        switch (request.command, request.action) {
        case (.dcControl, .set):
            dcEnabled = try Self.boolPayload(request.payload, count: 1, at: 0)
            result = 0
            payload = []
        case (.typeCControl, .set):
            guard request.payload.count == 2, request.payload.first == 0x02 else {
                throw DemoTransportError.malformedCommand
            }
            typeCOutputPreferred = try Self.boolPayload(request.payload, count: 2, at: 1)
            result = 0
            payload = []
        case (.dcBypassControl, .set):
            bypassEnabled = try Self.boolPayload(request.payload, count: 1, at: 0)
            result = 0
            payload = []
        case (.typeCPowerLimit, .get):
            let type = try Self.limitType(request.payload, count: 1)
            if let level = limits[type] {
                result = 0
                payload = [level.rawValue]
            } else {
                result = 0xFF
                payload = []
            }
        case (.typeCPowerLimit, .set):
            let type = try Self.limitType(request.payload, count: 2)
            guard
                  let level = PowerLimitLevel(rawValue: request.payload[1])
            else { throw DemoTransportError.malformedCommand }
            limits[type] = level
            result = 0
            payload = []
        case (.typeCPowerLimit, .delete):
            let type = try Self.limitType(request.payload, count: 1)
            limits[type] = Self.resetLimits[type]
            result = 0
            payload = []
        case (.runningModeControl, .set):
            guard request.payload.count == 1,
                  RunningMode(rawValue: request.payload[0]) != nil
            else { throw DemoTransportError.malformedCommand }
            result = 0
            payload = []
        default:
            throw DemoTransportError.unsupportedCommand
        }

        let nextSnapshot = makeSnapshot(jittered: false)
        let timestamp = await clock.now
        snapshot = nextSnapshot
        emitCurrentSnapshot(at: timestamp)

        let replyBytes = Data([request.command.rawValue, request.action.rawValue | 0x80, result] + payload)
        return .reply(try command.validate(replyBytes))
    }

    private func executeTelemetryRefresh() async {
        let timestamp = await clock.now
        snapshot = makeSnapshot(jittered: true)
        emitCurrentSnapshot(at: timestamp)
    }

    private func executeChargerConnection(_ connected: Bool) async {
        chargerConnected = connected
        let nextSnapshot = makeSnapshot(jittered: false)
        let timestamp = await clock.now
        snapshot = nextSnapshot
        emitCurrentSnapshot(at: timestamp)
    }

    private func startTelemetryCadence() {
        guard telemetryTask == nil else { return }
        let clock = clock
        telemetryTask = Task { [weak self, clock] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                let timestamp = await clock.now
                guard !Task.isCancelled, let self else { return }
                guard await self.emitCadenceTick(at: timestamp) else { return }
            }
        }
    }

    private func emitCadenceTick(at timestamp: DeviceTimestamp) -> Bool {
        guard connected else { return false }
        snapshot = makeSnapshot(jittered: true)
        emitCurrentSnapshot(at: timestamp)
        return true
    }

    private func makeSnapshot(jittered: Bool) -> DemoSnapshot {
        Self.makeSnapshot(
            dcEnabled: dcEnabled,
            typeCOutputPreferred: typeCOutputPreferred,
            bypassEnabled: bypassEnabled,
            chargerConnected: chargerConnected,
            limits: limits,
            typeCOutputCurrent: typeCOutputCurrent,
            jitter: jittered ? { [self] value in random.jitter(value) } : nil
        )
    }

    private func emitCurrentSnapshot(at timestamp: DeviceTimestamp) {
        continuation.yield(.battery(snapshot.battery, timestamp: timestamp))
        continuation.yield(.dc(snapshot.dc, timestamp: timestamp))
        continuation.yield(.typeC(snapshot.typeC, timestamp: timestamp))
    }

    private func beginTransaction() {
        pendingTransactionCount += 1
        maximumPendingTransactionCount = max(
            maximumPendingTransactionCount,
            pendingTransactionCount
        )
        continuation.yield(.transactionDepth(pendingTransactionCount))
    }

    private func endTransaction() {
        pendingTransactionCount -= 1
        continuation.yield(.transactionDepth(pendingTransactionCount))
    }

    private static func boolPayload(_ payload: [UInt8], count: Int, at index: Int) throws -> Bool {
        guard payload.count == count, payload.indices.contains(index), payload[index] <= 1 else {
            throw DemoTransportError.malformedCommand
        }
        return payload[index] == 1
    }

    private static func limitType(_ payload: [UInt8], count: Int) throws -> PowerLimitType {
        guard payload.count == count,
              let raw = payload.first,
              let type = PowerLimitType(rawValue: raw)
        else {
            throw DemoTransportError.malformedCommand
        }
        return type
    }

    private static func makeSnapshot(
        dcEnabled: Bool,
        typeCOutputPreferred: Bool,
        bypassEnabled: Bool,
        chargerConnected: Bool,
        limits: [PowerLimitType: PowerLimitLevel],
        typeCOutputCurrent: Double,
        jitter: ((Double) -> Double)? = nil
    ) -> DemoSnapshot {
        let vary = jitter ?? { $0 }
        let inputLimit = min(limitWatts(limits[.global]), limitWatts(limits[.input]))
        let outputLimit = min(limitWatts(limits[.global]), limitWatts(limits[.output]))
        let batteryVoltage = vary(16)
        let batteryPower = chargerConnected
            ? min(batteryVoltage * 6.25, inputLimit)
            : batteryVoltage * (-45 / 16)
        let batteryCapacity = 153.6 * 0.62
        let runtime = UInt16((batteryCapacity / abs(batteryPower) * 60).rounded())
        let battery = try! BatteryStatus(frame: batteryFrame(
            status: chargerConnected ? .charging : .discharging,
            capacity: batteryCapacity,
            voltage: batteryVoltage,
            current: batteryPower / batteryVoltage,
            power: batteryPower,
            remainingMinutes: runtime
        ))

        let dcVoltage = dcEnabled ? vary(19.6) : 0
        let dcPower = dcEnabled ? dcVoltage * 1.2 : 0
        let dcCurrent = dcEnabled ? dcPower / dcVoltage : 0
        let dc = try! DCPortStatus(frame: dcFrame(
            enabled: dcEnabled,
            status: dcEnabled ? .discharging : .idle,
            voltage: dcVoltage,
            current: dcCurrent,
            power: dcPower,
            bypassOn: bypassEnabled
        ))

        let effectiveTypeCOutput = typeCOutputPreferred && !chargerConnected
        let typeCMode: TypeCPortMode = effectiveTypeCOutput ? .output : .input
        let typeCStatus: PowerFlow = chargerConnected ? .charging : (effectiveTypeCOutput ? .discharging : .idle)
        let typeCVoltage = chargerConnected ? vary(20) : (effectiveTypeCOutput ? vary(12) : 0)
        let typeCPower = chargerConnected
            ? min(typeCVoltage * 5, inputLimit)
            : (effectiveTypeCOutput ? min(typeCVoltage * typeCOutputCurrent, outputLimit) : 0)
        let typeCCurrent = typeCVoltage == 0 ? 0 : typeCPower / typeCVoltage
        let typeC = try! TypeCPortStatus(frame: typeCFrame(
            status: typeCStatus,
            voltage: typeCVoltage,
            current: typeCCurrent,
            power: typeCPower,
            mode: typeCMode,
            isDCInput: chargerConnected
        ))

        return DemoSnapshot(
            battery: battery,
            dc: dc,
            typeC: typeC,
            limits: limits,
            chargerConnected: chargerConnected
        )
    }

    private static func limitWatts(_ level: PowerLimitLevel?) -> Double {
        switch level {
        case .watts30: 30
        case .watts45: 45
        case .watts60: 60
        case .watts65: 65
        case .watts100: 100
        case .watts140, nil: 140
        }
    }

    private static func batteryFrame(
        status: PowerFlow,
        capacity: Double,
        voltage: Double,
        current: Double,
        power: Double,
        remainingMinutes: UInt16
    ) -> Data {
        Data([1, flowByte(status), 0])
            + sfloat(153.6) + sfloat(capacity) + Data([62])
            + sfloat(voltage) + sfloat(current) + sfloat(power)
            + Data([UInt8(remainingMinutes & 0xFF), UInt8(remainingMinutes >> 8)])
    }

    private static func dcFrame(
        enabled: Bool,
        status: PowerFlow,
        voltage: Double,
        current: Double,
        power: Double,
        bypassOn: Bool
    ) -> Data {
        Data([enabled ? 1 : 0, flowByte(status)])
            + sfloat(voltage) + sfloat(current) + sfloat(power) + Data([bypassOn ? 1 : 0])
    }

    private static func typeCFrame(
        status: PowerFlow,
        voltage: Double,
        current: Double,
        power: Double,
        mode: TypeCPortMode,
        isDCInput: Bool
    ) -> Data {
        Data([1, flowByte(status)])
            + sfloat(voltage) + sfloat(current) + sfloat(power) + sfloat(31)
            + Data([0, mode.rawValue, isDCInput ? 1 : 0])
    }

    private static func flowByte(_ flow: PowerFlow) -> UInt8 {
        UInt8(bitPattern: flow.rawValue)
    }

    private static func sfloat(_ value: Double) -> Data {
        let exponent: Int8 = abs(value * 100) <= 2_047 ? -2 : -1
        let scale = pow(10, Double(exponent))
        let mantissa = Int16((value / scale).rounded())
        let exponentBits = UInt16(UInt8(bitPattern: exponent) & 0x0F) << 12
        let mantissaBits = UInt16(bitPattern: mantissa) & 0x0FFF
        let raw = exponentBits | mantissaBits
        return Data([UInt8(raw & 0xFF), UInt8(raw >> 8)])
    }
}

private struct SeededGenerator: Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func jitter(_ value: Double) -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let unit = Double(state >> 11) / Double(UInt64(1) << 53)
        // Leave encoding headroom so SFLOAT rounding cannot cross the advertised ±2% bound.
        return value * (0.981 + unit * 0.038)
    }
}
