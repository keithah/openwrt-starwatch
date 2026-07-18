import Foundation
import Observation
import WattlineNetwork

@MainActor
@Observable
final class RouterEnrollmentCoordinator {
    typealias Connect = @MainActor (RouterHostMetadata) -> Void

    private(set) var isSubmitting = false
    private(set) var errorMessage: String?

    private let connections: RouterConnectionModel
    private let connect: Connect

    init(connections: RouterConnectionModel, connect: @escaping Connect) {
        self.connections = connections
        self.connect = connect
    }

    @discardableResult
    func submit(
        pin: String,
        label: String,
        router: DiscoveredRouter
    ) async throws -> RouterHostMetadata {
        guard !isSubmitting else { throw RouterEnrollmentError.invalidRequest }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let host = try await connections.enroll(router: router, pin: pin, label: label)
            connect(host)
            return host
        } catch {
            errorMessage = Self.message(for: error)
            throw error
        }
    }

    @discardableResult
    func submit(
        payload: RouterPairingPayload,
        displayName: String,
        label: String
    ) async throws -> RouterHostMetadata {
        guard !isSubmitting else { throw RouterEnrollmentError.invalidRequest }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let host = try await connections.enroll(
                payload: payload,
                displayName: displayName,
                reachability: .lan,
                label: label
            )
            connect(host)
            return host
        } catch {
            errorMessage = Self.message(for: error)
            throw error
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case NetworkError.api(_, let code, let message):
            code == .invalidOrExpiredPIN ? "The pairing PIN is invalid or expired." : message
        case NetworkError.unauthorized:
            "The router rejected the pairing request."
        case RouterEnrollmentError.deviceIdentityMismatch:
            "The router identity did not match the discovered device."
        case RouterEnrollmentError.certificateFingerprintMismatch:
            "The router certificate did not match the discovered fingerprint."
        default:
            "Could not pair with the router. Try again."
        }
    }
}
