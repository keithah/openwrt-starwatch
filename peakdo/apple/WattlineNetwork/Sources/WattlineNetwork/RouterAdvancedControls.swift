import Foundation

public struct RouterBypassThreshold: Codable, Equatable, Sendable {
    public let volts: Double
}

public struct RouterDeviceClockStatus: Codable, Equatable, Sendable {
    public let available: Bool
    public let deviceTime: String?
    public let systemTime: String
    public let driftSeconds: Int?

    private enum CodingKeys: String, CodingKey {
        case available
        case deviceTime = "device_time"
        case systemTime = "system_time"
        case driftSeconds = "drift_seconds"
    }
}

public struct RouterClockSyncResult: Codable, Equatable, Sendable {
    public let synced: Bool
    public let systemTime: String

    private enum CodingKeys: String, CodingKey {
        case synced
        case systemTime = "system_time"
    }
}

public struct RouterRunningModeResult: Codable, Equatable, Sendable {
    public let mode: UInt8
}

public struct RouterBarrierFreeResult: Codable, Equatable, Sendable {
    public let enabled: Bool
}

public struct RouterUSBFirmwareVersion: Codable, Equatable, Sendable {
    public let raw: String
    public let major: UInt8
    public let minor: UInt8
    public let patch: UInt8
}

public struct RouterBLEPINUpdateResult: Codable, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    public let updated: Bool

    public var description: String {
        "RouterBLEPINUpdateResult(updated: \(updated))"
    }

    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["updated": updated], displayStyle: .struct)
    }
}

private struct RouterVoltsRequest: Encodable {
    let volts: Double
}

private struct RouterRunningModeRequest: Encodable {
    let mode: UInt8
}

private struct RouterBarrierFreeRequest: Encodable {
    let enabled: Bool
}

private struct RouterBLEPINRequest: Encodable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    private let pin: String

    init(pin: String) {
        self.pin = pin
    }

    private enum CodingKeys: String, CodingKey { case pin }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pin, forKey: .pin)
    }

    var description: String { "RouterBLEPINRequest(pin: [REDACTED])" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["pin": "[REDACTED]"], displayStyle: .struct)
    }
}

extension RouterAdministrationClient {
    public func advancedIdentity() async throws -> RouterDeviceDTO {
        try await advancedGET("/api/v1/device", as: RouterDeviceDTO.self)
    }

    public func bypassThreshold() async throws -> RouterBypassThreshold {
        try await advancedGET(
            "/api/v1/device/dc/bypass/threshold",
            as: RouterBypassThreshold.self
        )
    }

    public func setBypassThreshold(volts: Double) async throws -> RouterBypassThreshold {
        guard volts.isFinite, volts > 0, volts <= 60 else {
            throw RouterAdministrationError.invalidResponse
        }
        return try await advancedMutation(
            "PUT",
            "/api/v1/device/dc/bypass/threshold",
            request: RouterVoltsRequest(volts: volts),
            response: RouterBypassThreshold.self
        )
    }

    public func deviceClock() async throws -> RouterDeviceClockStatus {
        try await advancedGET("/api/v1/device/clock", as: RouterDeviceClockStatus.self)
    }

    public func syncDeviceClock() async throws -> RouterClockSyncResult {
        try await advancedBodylessMutation(
            "POST",
            "/api/v1/device/clock/sync",
            response: RouterClockSyncResult.self
        )
    }

    public func setRunningMode(_ mode: UInt8) async throws -> RouterRunningModeResult {
        try await advancedMutation(
            "PUT",
            "/api/v1/device/advanced/running-mode",
            request: RouterRunningModeRequest(mode: mode),
            response: RouterRunningModeResult.self
        )
    }

    public func barrierFree() async throws -> RouterBarrierFreeResult {
        try await advancedGET(
            "/api/v1/device/advanced/barrier-free",
            as: RouterBarrierFreeResult.self
        )
    }

    public func setBarrierFree(_ enabled: Bool) async throws -> RouterBarrierFreeResult {
        try await advancedMutation(
            "PUT",
            "/api/v1/device/advanced/barrier-free",
            request: RouterBarrierFreeRequest(enabled: enabled),
            response: RouterBarrierFreeResult.self
        )
    }

    public func usbFirmwareVersion() async throws -> RouterUSBFirmwareVersion {
        try await advancedGET(
            "/api/v1/device/advanced/usb-fw-version",
            as: RouterUSBFirmwareVersion.self
        )
    }

    public func setBLEPIN(_ pin: String) async throws -> RouterBLEPINUpdateResult {
        guard pin.utf8.count == 6,
              pin.utf8.allSatisfy({ (48...57).contains($0) })
        else { throw RouterAdministrationError.invalidResponse }

        let data: Data
        do {
            data = try await advancedMutationData(
                "PUT",
                "/api/v1/device/advanced/ble-pin",
                request: RouterBLEPINRequest(pin: pin)
            )
        } catch {
            throw redactedBLEPINError(error, pin: pin)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["updated"],
              object["updated"] as? Bool == true
        else { throw RouterAdministrationError.invalidResponse }
        return RouterBLEPINUpdateResult(updated: true)
    }

    private func advancedGET<Response: Decodable>(
        _ path: String,
        as type: Response.Type
    ) async throws -> Response {
        let attachment = try attachmentLease()
        await acquirePrivilegedMutation()
        defer { releasePrivilegedMutation() }
        try Task.checkCancellation()
        try validate(attachment: attachment)
        let (data, _) = try await send("GET", path)
        try validate(attachment: attachment)
        return try decodeAdvancedResponse(type, from: data)
    }

    private func advancedBodylessMutation<Response: Decodable>(
        _ method: String,
        _ path: String,
        response type: Response.Type
    ) async throws -> Response {
        let attachment = try attachmentLease()
        await acquirePrivilegedMutation()
        defer { releasePrivilegedMutation() }
        try Task.checkCancellation()
        try validate(attachment: attachment)
        let (data, _) = try await send(method, path)
        try validate(attachment: attachment)
        return try decodeAdvancedResponse(type, from: data)
    }

    private func advancedMutation<Request: Encodable, Response: Decodable>(
        _ method: String,
        _ path: String,
        request: Request,
        response type: Response.Type
    ) async throws -> Response {
        let data = try await advancedMutationData(method, path, request: request)
        return try decodeAdvancedResponse(type, from: data)
    }

    private func advancedMutationData<Request: Encodable>(
        _ method: String,
        _ path: String,
        request: Request
    ) async throws -> Data {
        let attachment = try attachmentLease()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(request)
        await acquirePrivilegedMutation()
        defer { releasePrivilegedMutation() }
        try Task.checkCancellation()
        try validate(attachment: attachment)
        let (data, _) = try await send(method, path, body: body)
        try validate(attachment: attachment)
        return data
    }

    private func decodeAdvancedResponse<Response: Decodable>(
        _ type: Response.Type,
        from data: Data
    ) throws -> Response {
        guard let value = try? JSONDecoder().decode(type, from: data) else {
            throw RouterAdministrationError.invalidResponse
        }
        return value
    }

    private func redactedBLEPINError(_ error: any Error, pin: String) -> any Error {
        if error is CancellationError { return CancellationError() }
        if let administration = error as? RouterAdministrationError {
            return administration
        }
        guard let network = error as? NetworkError else {
            return NetworkError.transport("Advanced BLE PIN request failed")
        }

        func redact(_ value: String) -> String {
            value.replacingOccurrences(of: pin, with: "[REDACTED]")
        }
        func redact(_ code: RouterAPIErrorCode) -> RouterAPIErrorCode {
            if case let .unknown(value) = code { return .unknown(redact(value)) }
            return code
        }

        return switch network {
        case .invalidURL: NetworkError.invalidURL
        case .unauthorized: NetworkError.unauthorized
        case let .api(status, code, message):
            NetworkError.api(status: status, code: redact(code), message: redact(message))
        case let .httpStatus(status, body): NetworkError.httpStatus(status, redact(body))
        case let .decode(message): NetworkError.decode(redact(message))
        case .streamEnded: NetworkError.streamEnded
        case let .unsupported(message): NetworkError.unsupported(redact(message))
        case .timeout: NetworkError.timeout
        case let .transport(message): NetworkError.transport(redact(message))
        }
    }
}
