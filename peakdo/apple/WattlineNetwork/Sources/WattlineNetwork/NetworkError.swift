import Foundation

public enum RouterAPIErrorCode: Equatable, Sendable {
    case invalidRequest
    case invalidOrExpiredPIN
    case adminRequired
    case advancedDisabled
    case capabilityUnsupported
    case operationInProgress
    case deviceDisconnected
    case bleOperationFailed
    case commandTimeout
    case notFound
    case internalError
    case unknown(String)

    init(_ rawValue: String) {
        self = switch rawValue {
        case "invalid_request": .invalidRequest
        case "invalid_or_expired_pin": .invalidOrExpiredPIN
        case "admin_required": .adminRequired
        case "advanced_disabled": .advancedDisabled
        case "capability_unsupported": .capabilityUnsupported
        case "operation_in_progress": .operationInProgress
        case "device_disconnected": .deviceDisconnected
        case "ble_operation_failed": .bleOperationFailed
        case "command_timeout": .commandTimeout
        case "not_found": .notFound
        case "internal_error": .internalError
        default: .unknown(rawValue)
        }
    }
}

public enum NetworkError: Error, Equatable, Sendable {
    case invalidURL
    case unauthorized
    case api(status: Int, code: RouterAPIErrorCode, message: String)
    case httpStatus(Int, String)
    case decode(String)
    case streamEnded
    case unsupported(String)
    case timeout
    case transport(String)
}

enum RouterHTTPErrorMapper {
    private struct Envelope: Decodable {
        struct Failure: Decodable {
            let code: String
            let message: String
        }
        let error: Failure
    }

    static func error(status: Int, data: Data, token: String) -> NetworkError {
        let redactedBody = redact(String(data: data, encoding: .utf8) ?? "", token: token)
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return status == 401 ? .unauthorized : .httpStatus(status, redactedBody)
        }
        let decodedCode = RouterAPIErrorCode(envelope.error.code)
        let code = switch decodedCode {
        case .unknown:
            RouterAPIErrorCode.unknown(redact(envelope.error.code, token: token))
        default:
            decodedCode
        }
        if status == 401, code != .invalidOrExpiredPIN {
            return .unauthorized
        }
        return .api(
            status: status,
            code: code,
            message: redact(envelope.error.message, token: token)
        )
    }

    static func redact(_ value: String, token: String) -> String {
        guard !token.isEmpty else { return value }
        return value.replacingOccurrences(of: token, with: "[REDACTED]")
    }
}
