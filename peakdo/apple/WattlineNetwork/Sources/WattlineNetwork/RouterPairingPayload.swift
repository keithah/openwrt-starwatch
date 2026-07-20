import Foundation

public enum RouterPairingPayloadError: Error, Equatable, Sendable {
    case invalidPayload
    case unsupportedVersion
}

public struct RouterPairingPayload: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    public let deviceID: String
    public let host: String
    public let httpPort: Int?
    public let httpsPort: Int?
    public let pin: String
    public let certificateFingerprint: String?

    public var enrollmentEndpoint: RouterEndpoint {
        if let httpsPort, let certificateFingerprint {
            return RouterEndpoint(
                scheme: "https",
                host: host,
                port: httpsPort,
                certificateFingerprint: certificateFingerprint,
                allowsInsecureWAN: false
            )
        }
        return RouterEndpoint(
            scheme: "http",
            host: host,
            port: httpPort!,
            certificateFingerprint: nil,
            allowsInsecureWAN: false
        )
    }

    public var description: String {
        "RouterPairingPayload(deviceID: \(deviceID), host: \(host), pin: [REDACTED])"
    }

    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["payload": "[REDACTED]"], displayStyle: .struct)
    }

    public static func parse(_ url: URL) throws -> RouterPairingPayload {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "wattline",
              components.host?.lowercased() == "pair",
              components.path.isEmpty || components.path == "/",
              components.fragment == nil,
              let queryItems = components.queryItems
        else { throw RouterPairingPayloadError.invalidPayload }

        var values: [String: String] = [:]
        for item in queryItems {
            guard values[item.name] == nil, let value = item.value else {
                throw RouterPairingPayloadError.invalidPayload
            }
            values[item.name] = value
        }
        let allowedFields: Set<String> = ["v", "id", "host", "http", "https", "pin", "tls"]
        guard Set(values.keys).isSubset(of: allowedFields) else {
            throw RouterPairingPayloadError.invalidPayload
        }
        guard values["v"] == "1" else {
            if values["v"] != nil { throw RouterPairingPayloadError.unsupportedVersion }
            throw RouterPairingPayloadError.invalidPayload
        }
        guard let rawID = values["id"],
              let deviceID = DeviceIdentityDeduplicator.normalizedMAC(rawID),
              let host = values["host"], isValidHost(host),
              let pin = values["pin"], isSixDigitPIN(pin)
        else { throw RouterPairingPayloadError.invalidPayload }

        let httpPort = try port(values["http"])
        let httpsPort = try port(values["https"])
        guard httpPort != nil || httpsPort != nil else {
            throw RouterPairingPayloadError.invalidPayload
        }

        let fingerprint: String?
        if let rawTLS = values["tls"] {
            guard httpsPort != nil,
                  let normalized = RouterHostValidator.normalizeFingerprint(rawTLS)
            else { throw RouterPairingPayloadError.invalidPayload }
            fingerprint = normalized
        } else {
            guard httpsPort == nil else { throw RouterPairingPayloadError.invalidPayload }
            fingerprint = nil
        }

        return RouterPairingPayload(
            deviceID: deviceID,
            host: normalizedHost(host),
            httpPort: httpPort,
            httpsPort: httpsPort,
            pin: pin,
            certificateFingerprint: fingerprint
        )
    }

    static func isSixDigitPIN(_ value: String) -> Bool {
        value.count == 6 && value.unicodeScalars.allSatisfy { (48...57).contains($0.value) }
    }

    private static func port(_ value: String?) throws -> Int? {
        guard let value else { return nil }
        guard !value.isEmpty, value.allSatisfy(\.isNumber),
              let port = Int(value), (1...65_535).contains(port)
        else { throw RouterPairingPayloadError.invalidPayload }
        return port
    }

    private static func isValidHost(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.whitespacesAndNewlines.contains($0)
                      && !CharacterSet.controlCharacters.contains($0)
              }),
              !value.contains("/"), !value.contains("@"), !value.contains("?"), !value.contains("#")
        else { return false }
        var components = URLComponents()
        components.scheme = "http"
        components.host = value
        return components.url != nil
    }

    private static func normalizedHost(_ value: String) -> String {
        let lowercase = value.lowercased()
        return lowercase.last == "." ? String(lowercase.dropLast()) : lowercase
    }
}
