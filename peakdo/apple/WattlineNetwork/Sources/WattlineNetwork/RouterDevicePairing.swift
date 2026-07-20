import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum RouterDevicePairingStage: String, Codable, Sendable {
    case idle
    case scanning
    case pairing
    case connected
    case failed
}

public struct RouterPairableDevice: Codable, Equatable, Sendable {
    public let mac: String
    public let name: String
    public let rssi: Int
    public let paired: Bool

    public init(mac: String, name: String, rssi: Int, paired: Bool) {
        self.mac = mac
        self.name = name
        self.rssi = rssi
        self.paired = paired
    }
}

public struct RouterDevicePairingStatus: Codable, Equatable, Sendable {
    public let stage: RouterDevicePairingStage
    public let target: String?
    public let devices: [RouterPairableDevice]
    public let error: String?

    public init(
        stage: RouterDevicePairingStage,
        target: String?,
        devices: [RouterPairableDevice],
        error: String?
    ) {
        self.stage = stage
        self.target = target
        self.devices = devices
        self.error = error
    }
}

public enum RouterDevicePairingError: Error, Equatable, Sendable {
    case invalidMAC
    case invalidPIN
    case operationInProgress(RouterDevicePairingStatus)
    case timedOut
    case invalidResponse
}

/// Client-token HTTP facade for router-to-Link-Power pairing. It owns no BLE
/// objects and never persists the optional device PIN.
public actor RouterDevicePairingClient {
    private struct Accepted: Decodable { let status: String }
    private struct PairPayload: Encodable, CustomStringConvertible,
        CustomDebugStringConvertible, CustomReflectable
    {
        let mac: String
        let pin: String
        var description: String { "PairPayload([REDACTED])" }
        var debugDescription: String { description }
        var customMirror: Mirror {
            Mirror(self, children: ["mac": mac, "pin": "[REDACTED]"], displayStyle: .struct)
        }
    }

    private let endpoint: RouterEndpoint
    private let credentials: RouterCredentialStore
    private let http: any RouterHTTPClient
    private let clock: any RouterConnectionClock
    private let timeout: Duration
    private let pollInterval: Duration
    private var generation: UInt64 = 0
    private var operationID: UUID?
    private var lastStatus: RouterDevicePairingStatus?
    private var pollingTask: Task<RouterDevicePairingStatus, Error>?
    private var pollingID: UUID?

    public init(
        endpoint: RouterEndpoint,
        credentials: RouterCredentialStore,
        http: any RouterHTTPClient,
        clock: any RouterConnectionClock,
        timeout: Duration = .seconds(30),
        pollInterval: Duration = .milliseconds(500)
    ) {
        self.endpoint = endpoint
        self.credentials = credentials
        self.http = http
        self.clock = clock
        self.timeout = timeout
        self.pollInterval = pollInterval
    }

    public func status() async throws -> RouterDevicePairingStatus {
        let requestGeneration = generation
        return try await readStatus(generation: requestGeneration)
    }

    public func scan() async throws -> RouterDevicePairingStatus {
        try await start(kind: .scan(mac: nil, pin: nil))
    }

    public func pair(mac: String, pin: String) async throws -> RouterDevicePairingStatus {
        guard let normalized = Self.normalizedDisplayMAC(mac) else {
            throw RouterDevicePairingError.invalidMAC
        }
        guard pin.isEmpty || Self.isSixASCIIDigits(pin) else {
            throw RouterDevicePairingError.invalidPIN
        }
        return try await start(kind: .pair(mac: normalized, pin: pin))
    }

    public func unpair(mac: String) async throws -> RouterDevicePairingStatus {
        guard let normalized = Self.normalizedDisplayMAC(mac) else {
            throw RouterDevicePairingError.invalidMAC
        }
        guard operationID == nil else {
            throw RouterDevicePairingError.operationInProgress(try await status())
        }
        let operation = UUID()
        operationID = operation
        defer { if operationID == operation { operationID = nil } }
        let requestGeneration = generation
        let encoded = Self.percentEncodePathSegment(normalized)
        let (data, response) = try await request(
            "DELETE", "/api/v1/pairing/device/\(encoded)", body: nil,
            generation: requestGeneration
        )
        guard response.statusCode == 200,
              (try? JSONDecoder().decode(Accepted.self, from: data).status) == "removed"
        else { throw RouterDevicePairingError.invalidResponse }
        return try await readStatus(generation: requestGeneration)
    }

    public func cancel() {
        generation &+= 1
        pollingTask?.cancel()
        pollingTask = nil
        pollingID = nil
        operationID = nil
    }

    private enum StartKind {
        case scan(mac: String?, pin: String?)
        case pair(mac: String?, pin: String?)
    }

    private func start(kind: StartKind) async throws -> RouterDevicePairingStatus {
        guard operationID == nil else {
            throw RouterDevicePairingError.operationInProgress(
                lastStatus ?? RouterDevicePairingStatus(
                    stage: .scanning, target: nil, devices: [], error: nil
                )
            )
        }
        let operation = UUID()
        operationID = operation
        defer { if operationID == operation { operationID = nil } }
        let requestGeneration = generation
        let current = try await readStatus(generation: requestGeneration)
        if current.stage == .scanning || current.stage == .pairing {
            return try await runPolling(from: current, generation: requestGeneration)
        }
        let method = "POST"
        let path: String
        let body: Data?
        let expected: String
        switch kind {
        case .scan:
            path = "/api/v1/pairing/scan"
            body = nil
            expected = "scanning"
        case let .pair(mac?, pin?):
            path = "/api/v1/pairing/pair"
            body = try Self.encoder.encode(PairPayload(mac: mac, pin: pin))
            expected = "pairing"
        default:
            throw RouterDevicePairingError.invalidResponse
        }
        do {
            let (data, response) = try await request(
                method, path, body: body, generation: requestGeneration
            )
            guard response.statusCode == 202,
                  (try? JSONDecoder().decode(Accepted.self, from: data).status) == expected
            else { throw RouterDevicePairingError.invalidResponse }
        } catch NetworkError.api(409, .operationInProgress, _) {
            // The daemon already owns the operation. Adopt its authoritative
            // status instead of retrying the mutation.
        }
        let adopted = try await readStatus(generation: requestGeneration)
        return try await runPolling(from: adopted, generation: requestGeneration)
    }

    private func runPolling(
        from status: RouterDevicePairingStatus,
        generation requestGeneration: UInt64
    ) async throws -> RouterDevicePairingStatus {
        let id = UUID()
        let task = Task { try await self.poll(from: status, generation: requestGeneration) }
        pollingID = id
        pollingTask = task
        defer {
            if pollingID == id {
                pollingTask = nil
                pollingID = nil
            }
        }
        return try await task.value
    }

    private func poll(
        from initial: RouterDevicePairingStatus,
        generation requestGeneration: UInt64
    ) async throws -> RouterDevicePairingStatus {
        var current = initial
        var elapsed: Duration = .zero
        while current.stage == .scanning || current.stage == .pairing {
            guard generation == requestGeneration else { throw CancellationError() }
            guard elapsed < timeout else { throw RouterDevicePairingError.timedOut }
            try await clock.sleep(for: pollInterval)
            try Task.checkCancellation()
            guard generation == requestGeneration else { throw CancellationError() }
            elapsed += pollInterval
            current = try await readStatus(generation: requestGeneration)
        }
        return current
    }

    private func readStatus(generation requestGeneration: UInt64) async throws
        -> RouterDevicePairingStatus
    {
        let (data, response) = try await request(
            "GET", "/api/v1/pairing/status", body: nil, generation: requestGeneration
        )
        guard response.statusCode == 200,
              let decoded = try? JSONDecoder().decode(RouterDevicePairingStatus.self, from: data)
        else { throw RouterDevicePairingError.invalidResponse }
        let sanitized = RouterDevicePairingStatus(
            stage: decoded.stage,
            target: decoded.target.flatMap(Self.normalizedDisplayMAC) ?? decoded.target,
            devices: decoded.devices,
            error: Self.sanitizedAsyncError(decoded.error)
        )
        lastStatus = sanitized
        return sanitized
    }

    private func request(
        _ method: String,
        _ path: String,
        body: Data?,
        generation requestGeneration: UInt64
    ) async throws -> (Data, HTTPURLResponse) {
        guard generation == requestGeneration else { throw CancellationError() }
        let token: String
        do {
            guard let value = try await credentials.readToken(for: endpoint, role: .client) else {
                throw NetworkError.unauthorized
            }
            token = value
        } catch is CancellationError {
            throw CancellationError()
        }
        guard generation == requestGeneration else { throw CancellationError() }
        do {
            let result = try await http.request(method, path, body: body, token: token)
            guard generation == requestGeneration else { throw CancellationError() }
            return result
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }

    private static let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.outputFormatting = [.sortedKeys]
        return value
    }()

    private static func normalizedDisplayMAC(_ value: String) -> String? {
        guard let compact = DeviceIdentityDeduplicator.normalizedMAC(value) else { return nil }
        return stride(from: 0, to: compact.count, by: 2).map { offset in
            let start = compact.index(compact.startIndex, offsetBy: offset)
            let end = compact.index(start, offsetBy: 2)
            return String(compact[start..<end])
        }.joined(separator: ":")
    }

    private static func percentEncodePathSegment(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static func sanitizedAsyncError(_ value: String?) -> String? {
        guard let value else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")
        guard value.count <= 64,
              value.unicodeScalars.allSatisfy(allowed.contains)
        else { return "pair_failed" }
        return value
    }

    private static func isSixASCIIDigits(_ value: String) -> Bool {
        value.utf8.count == 6 && value.utf8.allSatisfy { (48...57).contains($0) }
    }
}
