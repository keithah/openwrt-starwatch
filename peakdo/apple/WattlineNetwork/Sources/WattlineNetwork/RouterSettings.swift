import Foundation

public struct RouterListenerSettings: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let addr4: String
    public let addr6: String
    public let port: Int

    public init(enabled: Bool, addr4: String, addr6: String, port: Int) {
        self.enabled = enabled
        self.addr4 = addr4
        self.addr6 = addr6
        self.port = port
    }
}

public struct RouterTLSSettings: Codable, Equatable, Sendable {
    public let cert: String
    public let key: String
    public let sha256: String

    public init(cert: String, key: String, sha256: String) {
        self.cert = cert
        self.key = key
        self.sha256 = sha256
    }
}

public struct RouterMDNSSettings: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let interfaces: [String]

    public init(enabled: Bool, interfaces: [String]) {
        self.enabled = enabled
        self.interfaces = interfaces
    }
}

public struct RouterSettings: Codable, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    public let http: RouterListenerSettings
    public let https: RouterListenerSettings
    public let tls: RouterTLSSettings
    public let tokenStore: String
    public let pairingTTL: String
    public let pairingAlwaysOn: Bool
    public let advanced: Bool
    public let mdns: RouterMDNSSettings
    public let wanAccess: Bool
    public let blePIN: String

    enum CodingKeys: String, CodingKey {
        case http, https, tls, advanced, mdns
        case tokenStore = "token_store"
        case pairingTTL = "pairing_ttl"
        case pairingAlwaysOn = "pairing_always_on"
        case wanAccess = "wan_access"
        case blePIN = "ble_pin"
    }

    public var description: String { "RouterSettings(blePIN: [REDACTED])" }
    public var debugDescription: String { description }
}

public struct RouterListenerSettingsPatch: Encodable, Equatable, Sendable {
    public let enabled: Bool?
    public let addr4: String?
    public let addr6: String?
    public let port: Int?

    public init(
        enabled: Bool? = nil,
        addr4: String? = nil,
        addr6: String? = nil,
        port: Int? = nil
    ) {
        self.enabled = enabled
        self.addr4 = addr4
        self.addr6 = addr6
        self.port = port
    }
}

public struct RouterTLSSettingsPatch: Encodable, Equatable, Sendable {
    public let cert: String?
    public let key: String?

    public init(cert: String? = nil, key: String? = nil) {
        self.cert = cert
        self.key = key
    }
}

public struct RouterMDNSSettingsPatch: Encodable, Equatable, Sendable {
    public let enabled: Bool?
    public let interfaces: [String]?

    public init(enabled: Bool? = nil, interfaces: [String]? = nil) {
        self.enabled = enabled
        self.interfaces = interfaces
    }
}

public struct RouterSettingsPatch: Encodable, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    public let http: RouterListenerSettingsPatch?
    public let https: RouterListenerSettingsPatch?
    public let tls: RouterTLSSettingsPatch?
    public let tokenStore: String?
    public let pairingTTL: String?
    public let pairingAlwaysOn: Bool?
    public let advanced: Bool?
    public let mdns: RouterMDNSSettingsPatch?
    public let wanAccess: Bool?
    public let blePIN: String?

    public init(
        http: RouterListenerSettingsPatch? = nil,
        https: RouterListenerSettingsPatch? = nil,
        tls: RouterTLSSettingsPatch? = nil,
        tokenStore: String? = nil,
        pairingTTL: String? = nil,
        pairingAlwaysOn: Bool? = nil,
        advanced: Bool? = nil,
        mdns: RouterMDNSSettingsPatch? = nil,
        wanAccess: Bool? = nil,
        blePIN: String? = nil
    ) {
        self.http = http
        self.https = https
        self.tls = tls
        self.tokenStore = tokenStore
        self.pairingTTL = pairingTTL
        self.pairingAlwaysOn = pairingAlwaysOn
        self.advanced = advanced
        self.mdns = mdns
        self.wanAccess = wanAccess
        self.blePIN = blePIN
    }

    enum CodingKeys: String, CodingKey {
        case http, https, tls, advanced, mdns
        case tokenStore = "token_store"
        case pairingTTL = "pairing_ttl"
        case pairingAlwaysOn = "pairing_always_on"
        case wanAccess = "wan_access"
        case blePIN = "ble_pin"
    }

    public var description: String { "RouterSettingsPatch(blePIN: [REDACTED])" }
    public var debugDescription: String { description }
}

public struct RouterSettingsUpdateResult: Equatable, Sendable, Decodable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    public let settings: RouterSettings
    public let restartRequired: Bool

    public init(from decoder: Decoder) throws {
        settings = try RouterSettings(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        restartRequired = try values.decode(Bool.self, forKey: .restartRequired)
    }

    enum CodingKeys: String, CodingKey {
        case restartRequired = "restart_required"
    }

    public var description: String {
        "RouterSettingsUpdateResult(settings: [REDACTED], restartRequired: \(restartRequired))"
    }

    public var debugDescription: String { description }
}

extension RouterAdministrationClient {
    public func settings() async throws -> RouterSettings {
        let (data, _) = try await send("GET", "/api/v1/settings")
        guard let value = try? JSONDecoder().decode(RouterSettings.self, from: data) else {
            throw RouterAdministrationError.invalidResponse
        }
        return value
    }

    public func updateSettings(_ patch: RouterSettingsPatch) async throws -> RouterSettingsUpdateResult {
        let attachment = try attachmentLease()
        await acquirePrivilegedMutation()
        defer { releasePrivilegedMutation() }
        try Task.checkCancellation()
        try validate(attachment: attachment)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(patch)
        let (data, _) = try await send("PUT", "/api/v1/settings", body: body)
        try validate(attachment: attachment)
        guard let value = try? JSONDecoder().decode(RouterSettingsUpdateResult.self, from: data) else {
            throw RouterAdministrationError.invalidResponse
        }
        return value
    }
}
