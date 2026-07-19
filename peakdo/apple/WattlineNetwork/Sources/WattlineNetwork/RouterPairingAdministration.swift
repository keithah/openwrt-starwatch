import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct RouterPairingMode: Equatable, Sendable, Decodable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    public let open: Bool
    public let expiresAt: Date
    public let pin: String?

    public init(open: Bool, expiresAt: Date, pin: String?) {
        self.open = open
        self.expiresAt = expiresAt
        self.pin = pin
    }

    private enum CodingKeys: String, CodingKey {
        case open
        case expiresAt = "expires_at"
        case pin
    }

    public var description: String {
        "RouterPairingMode(open: \(open), pin: [REDACTED])"
    }

    public var debugDescription: String { description }
}

public struct RouterTokenMetadata: Equatable, Sendable, Identifiable, Decodable {
    public let id: String
    public let label: String
    public let createdAt: Date
    public let lastSeenAt: Date?
    public let bootstrap: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case bootstrap
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
    }
}

extension RouterAdministrationClient {
    public func tokens() async throws -> [RouterTokenMetadata] {
        let (data, _) = try await send("GET", "/api/v1/tokens")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let list = try? decoder.decode([RouterTokenMetadata].self, from: data) else {
            throw RouterAdministrationError.invalidResponse
        }
        return list
    }

    @discardableResult
    public func revokeToken(id: String) async throws -> String {
        guard !id.isEmpty, id != "bootstrap" else {
            throw RouterAdministrationError.protectedToken
        }
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            throw RouterAdministrationError.protectedToken
        }
        struct Revoked: Decodable { let revoked: String }
        let (data, _) = try await sendDurableMutation(
            "DELETE", "/api/v1/tokens/\(encoded)"
        )
        guard let response = try? JSONDecoder().decode(Revoked.self, from: data),
              response.revoked == id
        else {
            throw RouterAdministrationError.invalidResponse
        }
        return response.revoked
    }

    public func pairingMode() async throws -> RouterPairingMode {
        let (data, _) = try await send("GET", "/api/v1/pairing-mode")
        return try Self.decodePairingMode(data)
    }

    public func openPairingMode() async throws -> RouterPairingMode {
        let (data, _) = try await send("POST", "/api/v1/pairing-mode")
        return try Self.decodePairingMode(data)
    }

    public func closePairingMode() async throws {
        struct Closed: Decodable { let open: Bool }

        let (data, _) = try await send("DELETE", "/api/v1/pairing-mode")
        guard let closed = try? JSONDecoder().decode(Closed.self, from: data),
              closed.open == false
        else {
            throw RouterAdministrationError.invalidResponse
        }
    }

    public func pairingQRCodePNG() async throws -> Data {
        let (data, response) = try await send("GET", "/api/v1/pairing-mode/qr.png")
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        let mediaType = contentType
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        guard mediaType.caseInsensitiveCompare("image/png") == .orderedSame,
              data.starts(with: signature)
        else {
            throw RouterAdministrationError.invalidResponse
        }
        return data
    }

    private static func decodePairingMode(_ data: Data) throws -> RouterPairingMode {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let mode = try? decoder.decode(RouterPairingMode.self, from: data),
              mode.open || mode.pin == nil
        else {
            throw RouterAdministrationError.invalidResponse
        }
        return mode
    }
}
