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

extension RouterAdministrationClient {
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
