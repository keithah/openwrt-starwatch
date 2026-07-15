import Foundation

public actor BLETransport: DeviceTransport {
    public nonisolated let events: AsyncStream<DeviceEvent>

    private let eventContinuation: AsyncStream<DeviceEvent>.Continuation
    private let bridge: BluetoothDelegateBridge
    private let transactions = SerializedTransactions()
    private var pendingTransactionCount = 0

    public init(restorationIdentifier: String = "ca.peakdo.wattline.central") {
        let pair = AsyncStream<DeviceEvent>.makeStream()
        events = pair.stream
        eventContinuation = pair.continuation
        bridge = BluetoothDelegateBridge(restorationIdentifier: restorationIdentifier) { event in
            pair.continuation.yield(event)
        }
    }

    deinit {
        eventContinuation.finish()
    }

    public func startScan() async throws {
        try await bridge.startScan()
    }

    public func stopScan() async {
        await bridge.stopScan()
    }

    public func connect(to id: UUID) async throws {
        try await bridge.connect(to: id)
    }

    public func disconnect() async {
        await bridge.disconnect()
    }

    public func perform(_ command: DeviceCommand) async throws -> CommandOutcome {
        beginTransaction()
        defer { endTransaction() }
        return try await transactions.enqueue { [bridge] in
            if command.request.target == .command, command.expectsRead {
                let response = try await bridge.commandTransaction(command.request.bytes)
                return .reply(try command.validate(response))
            }

            try await bridge.write(
                command.request.bytes,
                to: command.request.target.gattUUID,
                disconnectPolicy: command.disconnectPolicy
            )
            return .sent
        }
    }

    public func refreshTelemetry() async throws {
        beginTransaction()
        defer { endTransaction() }
        try await transactions.enqueue { [bridge] in
            for uuid in [GATTUUID.extendedBatteryInfo, .dcPortStatus, .typeCPortStatus] {
                do {
                    _ = try await bridge.read(uuid)
                } catch BLETransportError.missingCharacteristic {
                    continue
                }
            }
        }
    }

    public func synchronizeDeviceTime() async throws {
        beginTransaction()
        defer { endTransaction() }
        try await transactions.enqueue { [bridge] in
            try await bridge.write(
                CurrentTimeCodec.encode(Date(), adjustReason: 1),
                to: .currentTime,
                disconnectPolicy: .none
            )
        }
    }

    public func readDeviceTimeIfSupported() async throws -> Date? {
        beginTransaction()
        defer { endTransaction() }
        return try await transactions.enqueue { [bridge] in
            guard let bytes = try await bridge.readIfSupported(.currentTime) else { return nil }
            return try CurrentTimeCodec.decode(bytes)
        }
    }

    private func beginTransaction() {
        pendingTransactionCount += 1
        eventContinuation.yield(.transactionDepth(pendingTransactionCount))
    }

    private func endTransaction() {
        pendingTransactionCount -= 1
        eventContinuation.yield(.transactionDepth(pendingTransactionCount))
    }
}

private extension DeviceWriteTarget {
    var gattUUID: GATTUUID {
        switch self {
        case .command: .command
        case .ota: .ota
        case .factoryMode: .factoryMode
        }
    }
}
