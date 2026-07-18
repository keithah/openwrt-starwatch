import Foundation

public enum RouterHostReachability: String, Codable, Equatable, Sendable {
    case lan
    case vpn
    case wan
}

public enum RouterHostValidationError: Error, Equatable, Sendable {
    case invalidAddress
    case invalidScheme
    case invalidPort
    case invalidDeviceID
    case invalidCertificateFingerprint
    case insecureWANRequiresOptIn
    case missingCertificateFingerprint
    case certificateFingerprintMismatch
}

public struct RouterHostMetadata: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let scheme: String
    public let host: String
    public let port: Int
    public let reachability: RouterHostReachability
    public let allowsInsecureWAN: Bool
    public let deviceID: String?
    public let certificateFingerprint: String?

    public var endpoint: RouterEndpoint {
        RouterEndpoint(
            scheme: scheme,
            host: host,
            port: port,
            certificateFingerprint: certificateFingerprint,
            allowsInsecureWAN: allowsInsecureWAN
        )
    }
}

public enum RouterHostValidator {
    public static func validate(
        _ address: String,
        displayName: String,
        reachability: RouterHostReachability,
        allowsInsecureWAN: Bool,
        deviceID: String?,
        certificateFingerprint: String?
    ) throws -> RouterHostMetadata {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RouterHostValidationError.invalidAddress }
        let addressWithScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let components = URLComponents(string: addressWithScheme),
              let rawScheme = components.scheme,
              let rawHost = components.host,
              !rawHost.isEmpty,
              components.user == nil,
              components.password == nil,
              components.path.isEmpty || components.path == "/",
              components.query == nil,
              components.fragment == nil
        else { throw RouterHostValidationError.invalidAddress }

        let scheme = rawScheme.lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw RouterHostValidationError.invalidScheme
        }
        let port = components.port ?? (scheme == "https" ? 8378 : 8377)
        guard (1...65_535).contains(port) else { throw RouterHostValidationError.invalidPort }
        if reachability == .wan, scheme == "http", !allowsInsecureWAN {
            throw RouterHostValidationError.insecureWANRequiresOptIn
        }

        let normalizedDeviceID: String?
        if let deviceID {
            guard let value = DeviceIdentityDeduplicator.normalizedMAC(deviceID) else {
                throw RouterHostValidationError.invalidDeviceID
            }
            normalizedDeviceID = value
        } else {
            normalizedDeviceID = nil
        }

        let normalizedFingerprint: String?
        if let certificateFingerprint {
            guard let value = normalizeFingerprint(certificateFingerprint) else {
                throw RouterHostValidationError.invalidCertificateFingerprint
            }
            normalizedFingerprint = value
        } else {
            normalizedFingerprint = nil
        }
        if reachability == .wan, scheme == "https", normalizedFingerprint == nil {
            throw RouterHostValidationError.missingCertificateFingerprint
        }

        return RouterHostMetadata(
            id: stableID(scheme: scheme, host: rawHost, port: port),
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            scheme: scheme,
            host: normalizeHost(rawHost),
            port: port,
            reachability: reachability,
            allowsInsecureWAN: reachability == .wan && scheme == "http" && allowsInsecureWAN,
            deviceID: normalizedDeviceID,
            certificateFingerprint: normalizedFingerprint
        )
    }

    public static func validateCertificateFingerprint(
        expected: String,
        presented: String
    ) throws -> String {
        guard let expected = normalizeFingerprint(expected),
              let presented = normalizeFingerprint(presented)
        else { throw RouterHostValidationError.invalidCertificateFingerprint }
        guard expected == presented else {
            throw RouterHostValidationError.certificateFingerprintMismatch
        }
        return expected
    }

    public static func normalizeFingerprint(_ value: String) -> String? {
        let separators = CharacterSet(charactersIn: ":- ")
        let scalarView = value.unicodeScalars.filter { !separators.contains($0) }
        guard scalarView.count == 64,
              scalarView.allSatisfy({ scalar in
                  switch scalar.value {
                  case 48...57, 65...70, 97...102: true
                  default: false
                  }
              })
        else { return nil }
        return String(String.UnicodeScalarView(scalarView)).uppercased()
    }

    private static func normalizeHost(_ host: String) -> String {
        let lowercase = host.lowercased()
        return lowercase.last == "." ? String(lowercase.dropLast()) : lowercase
    }

    private static func stableID(scheme: String, host: String, port: Int) -> UUID {
        RouterEndpoint(
            scheme: scheme,
            host: host,
            port: port,
            certificateFingerprint: nil,
            allowsInsecureWAN: false
        ).peripheralID
    }
}

public protocol RouterHostKeyValueStore: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data, forKey key: String) throws
    func removeValue(forKey key: String) throws
}

public actor RouterHostStore {
    public static let defaultKey = "wattline.routerHosts"
    private let backend: any RouterHostKeyValueStore
    private let key: String

    public init(
        backend: any RouterHostKeyValueStore,
        key: String = RouterHostStore.defaultKey
    ) {
        self.backend = backend
        self.key = key
    }

    public func hosts() -> [RouterHostMetadata] {
        guard let data = backend.data(forKey: key),
              let hosts = try? JSONDecoder().decode([RouterHostMetadata].self, from: data)
        else { return [] }
        return hosts
    }

    public func save(_ host: RouterHostMetadata) throws {
        var current = hosts()
        current.removeAll { $0.id == host.id }
        current.append(host)
        current.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        try backend.set(try JSONEncoder().encode(current), forKey: key)
    }

    public func remove(id: UUID) throws {
        let remaining = hosts().filter { $0.id != id }
        if remaining.isEmpty {
            try backend.removeValue(forKey: key)
        } else {
            try backend.set(try JSONEncoder().encode(remaining), forKey: key)
        }
    }
}
