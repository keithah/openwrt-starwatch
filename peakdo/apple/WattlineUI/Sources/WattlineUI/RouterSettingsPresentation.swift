import Foundation

public struct RouterListenerSettingsValue: Equatable, Sendable {
    public var enabled: Bool
    public var addr4: String
    public var addr6: String
    public var port: Int

    public init(enabled: Bool, addr4: String, addr6: String, port: Int) {
        self.enabled = enabled
        self.addr4 = addr4
        self.addr6 = addr6
        self.port = port
    }
}

public struct RouterTLSSettingsValue: Equatable, Sendable {
    public var cert: String
    public var key: String
    public var sha256: String

    public init(cert: String, key: String, sha256: String) {
        self.cert = cert
        self.key = key
        self.sha256 = sha256
    }
}

public struct RouterMDNSSettingsValue: Equatable, Sendable {
    public var enabled: Bool
    public var interfaces: [String]

    public init(enabled: Bool, interfaces: [String]) {
        self.enabled = enabled
        self.interfaces = interfaces
    }
}

public struct RouterSettingsValue: Equatable, Sendable {
    public var http: RouterListenerSettingsValue
    public var https: RouterListenerSettingsValue
    public var tls: RouterTLSSettingsValue
    public var tokenStore: String
    public var pairingTTL: String
    public var pairingAlwaysOn: Bool
    public var advanced: Bool
    public var mdns: RouterMDNSSettingsValue
    public var wanAccess: Bool
    public var blePIN: String

    public init(
        http: RouterListenerSettingsValue,
        https: RouterListenerSettingsValue,
        tls: RouterTLSSettingsValue,
        tokenStore: String,
        pairingTTL: String,
        pairingAlwaysOn: Bool,
        advanced: Bool,
        mdns: RouterMDNSSettingsValue,
        wanAccess: Bool,
        blePIN: String
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
}

public struct RouterListenerDraft: Equatable, Sendable {
    public var enabled: Bool
    public var addr4: String
    public var addr6: String
    public var port: String
}

public struct RouterTLSDraft: Equatable, Sendable {
    public var cert: String
    public var key: String
}

public struct RouterMDNSDraft: Equatable, Sendable {
    public var enabled: Bool
    public var interfaces: [String]
}

public struct RouterSettingsDraft: Equatable, Sendable {
    public var http: RouterListenerDraft
    public var https: RouterListenerDraft
    public var tls: RouterTLSDraft
    public var tokenStore: String
    public var pairingTTL: String
    public var pairingAlwaysOn: Bool
    public var advanced: Bool
    public var mdns: RouterMDNSDraft
    public var wanAccess: Bool
    public var blePIN: String

    public init(_ value: RouterSettingsValue) {
        http = RouterListenerDraft(
            enabled: value.http.enabled,
            addr4: value.http.addr4,
            addr6: value.http.addr6,
            port: String(value.http.port)
        )
        https = RouterListenerDraft(
            enabled: value.https.enabled,
            addr4: value.https.addr4,
            addr6: value.https.addr6,
            port: String(value.https.port)
        )
        tls = RouterTLSDraft(cert: value.tls.cert, key: value.tls.key)
        tokenStore = value.tokenStore
        pairingTTL = value.pairingTTL
        pairingAlwaysOn = value.pairingAlwaysOn
        advanced = value.advanced
        mdns = RouterMDNSDraft(enabled: value.mdns.enabled, interfaces: value.mdns.interfaces)
        wanAccess = value.wanAccess
        blePIN = value.blePIN
    }

    public func patch(from original: RouterSettingsValue) throws -> RouterSettingsDraftPatch {
        guard let httpPort = Int(http.port), (1...65_535).contains(httpPort) else {
            throw RouterSettingsValidationError.invalidHTTPPort
        }
        guard let httpsPort = Int(https.port), (1...65_535).contains(httpsPort) else {
            throw RouterSettingsValidationError.invalidHTTPSPort
        }
        let pinBytes = Array(blePIN.utf8)
        guard pinBytes.count == 6, pinBytes.allSatisfy({ (48...57).contains($0) }) else {
            throw RouterSettingsValidationError.invalidBLEPIN
        }
        return RouterSettingsDraftPatch(
            http: RouterListenerDraftPatch.changed(
                draft: http,
                port: httpPort,
                original: original.http
            ),
            https: RouterListenerDraftPatch.changed(
                draft: https,
                port: httpsPort,
                original: original.https
            ),
            tls: RouterTLSDraftPatch.changed(draft: tls, original: original.tls),
            tokenStore: tokenStore == original.tokenStore ? nil : tokenStore,
            pairingTTL: pairingTTL == original.pairingTTL ? nil : pairingTTL,
            pairingAlwaysOn: pairingAlwaysOn == original.pairingAlwaysOn ? nil : pairingAlwaysOn,
            advanced: advanced == original.advanced ? nil : advanced,
            mdns: RouterMDNSDraftPatch.changed(draft: mdns, original: original.mdns),
            wanAccess: wanAccess == original.wanAccess ? nil : wanAccess,
            blePIN: blePIN == original.blePIN ? nil : blePIN
        )
    }
}

public enum RouterSettingsValidationError: Error, Equatable, Sendable {
    case invalidHTTPPort
    case invalidHTTPSPort
    case invalidBLEPIN
}

public enum RouterSettingsSaveBlocker: Equatable, Sendable {
    case invalidDraft
    case noEnabledListener
    case validatedReplacementRequired
}

public enum RouterSettingsConfirmation: Hashable, Sendable {
    case insecureWANHTTP
    case listenerMigration
    case tokenStoreCutover
}

public enum RouterReplacementValidation: Equatable, Sendable {
    case unvalidated
    case failed
    case verified(deviceID: String)
}

public struct RouterReplacementCandidate: Equatable, Sendable {
    public let scheme: String
    public let host: String
    public let port: Int
    public let validation: RouterReplacementValidation

    public init(
        scheme: String,
        host: String,
        port: Int,
        validation: RouterReplacementValidation
    ) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.validation = validation
    }
}

public struct RouterSettingsSaveContext: Equatable, Sendable {
    public let currentScheme: String
    public let currentPort: Int
    public let expectedDeviceID: String?
    public let replacement: RouterReplacementCandidate?
    public let confirmations: Set<RouterSettingsConfirmation>

    public init(
        currentScheme: String,
        currentPort: Int,
        expectedDeviceID: String? = nil,
        replacement: RouterReplacementCandidate? = nil,
        confirmations: Set<RouterSettingsConfirmation> = []
    ) {
        self.currentScheme = currentScheme
        self.currentPort = currentPort
        self.expectedDeviceID = expectedDeviceID
        self.replacement = replacement
        self.confirmations = confirmations
    }
}

public struct RouterSettingsSaveDecision: Equatable, Sendable {
    public let patch: RouterSettingsDraftPatch?
    public let blocker: RouterSettingsSaveBlocker?
    public let requiredConfirmations: Set<RouterSettingsConfirmation>

    public var canSave: Bool {
        blocker == nil && requiredConfirmations.isEmpty && patch != nil
    }
}

public enum RouterSettingsSavePolicy {
    public static func evaluate(
        original: RouterSettingsValue,
        draft: RouterSettingsDraft,
        context: RouterSettingsSaveContext
    ) -> RouterSettingsSaveDecision {
        let patch: RouterSettingsDraftPatch
        do {
            patch = try draft.patch(from: original)
        } catch {
            return RouterSettingsSaveDecision(
                patch: nil,
                blocker: .invalidDraft,
                requiredConfirmations: []
            )
        }
        guard draft.http.enabled || draft.https.enabled else {
            return RouterSettingsSaveDecision(
                patch: patch,
                blocker: .noEnabledListener,
                requiredConfirmations: []
            )
        }
        let currentRemains = context.currentScheme.lowercased() == "https"
            ? draft.https.enabled && Int(draft.https.port) == context.currentPort
            : draft.http.enabled && Int(draft.http.port) == context.currentPort
        if !currentRemains && !replacementIsCorrelated(context) {
            return RouterSettingsSaveDecision(
                patch: patch,
                blocker: .validatedReplacementRequired,
                requiredConfirmations: []
            )
        }
        var required: Set<RouterSettingsConfirmation> = []
        if draft.wanAccess && draft.http.enabled
            && (!original.wanAccess || !original.http.enabled)
        {
            required.insert(.insecureWANHTTP)
        }
        if patch.http != nil || patch.https != nil || patch.tls != nil {
            required.insert(.listenerMigration)
        }
        if patch.tokenStore != nil {
            required.insert(.tokenStoreCutover)
        }
        required.subtract(context.confirmations)
        return RouterSettingsSaveDecision(
            patch: patch.isEmpty ? nil : patch,
            blocker: nil,
            requiredConfirmations: required
        )
    }

    private static func replacementIsCorrelated(_ context: RouterSettingsSaveContext) -> Bool {
        guard let expected = normalizedMAC(context.expectedDeviceID),
              let candidate = context.replacement,
              (1...65_535).contains(candidate.port),
              candidate.scheme == "http" || candidate.scheme == "https",
              case let .verified(deviceID) = candidate.validation
        else { return false }
        return normalizedMAC(deviceID) == expected
    }

    private static func normalizedMAC(_ value: String?) -> String? {
        guard let value else { return nil }
        let bytes = value.utf8.filter { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
        guard bytes.count == 12 else { return nil }
        return String(decoding: bytes, as: UTF8.self).uppercased()
    }
}

public enum RouterSettingsCopy {
    public static let restartRequired =
        "wattlined or the router must restart before these changes take effect."
    public static let tokenStoreCutover =
        "Changing token storage closes existing managed live-update streams; Wattline does not migrate tokens between stores."
}

public struct RouterSettingsDraftPatch: Equatable, Sendable {
    public var http: RouterListenerDraftPatch?
    public var https: RouterListenerDraftPatch?
    public var tls: RouterTLSDraftPatch?
    public var tokenStore: String?
    public var pairingTTL: String?
    public var pairingAlwaysOn: Bool?
    public var advanced: Bool?
    public var mdns: RouterMDNSDraftPatch?
    public var wanAccess: Bool?
    public var blePIN: String?

    public init(
        http: RouterListenerDraftPatch? = nil,
        https: RouterListenerDraftPatch? = nil,
        tls: RouterTLSDraftPatch? = nil,
        tokenStore: String? = nil,
        pairingTTL: String? = nil,
        pairingAlwaysOn: Bool? = nil,
        advanced: Bool? = nil,
        mdns: RouterMDNSDraftPatch? = nil,
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

    public var isEmpty: Bool {
        http == nil && https == nil && tls == nil && tokenStore == nil && pairingTTL == nil
            && pairingAlwaysOn == nil && advanced == nil && mdns == nil
            && wanAccess == nil && blePIN == nil
    }
}

public struct RouterListenerDraftPatch: Equatable, Sendable {
    public var enabled: Bool?
    public var addr4: String?
    public var addr6: String?
    public var port: Int?

    public init(enabled: Bool? = nil, addr4: String? = nil, addr6: String? = nil, port: Int? = nil) {
        self.enabled = enabled
        self.addr4 = addr4
        self.addr6 = addr6
        self.port = port
    }

    static func changed(
        draft: RouterListenerDraft,
        port: Int,
        original: RouterListenerSettingsValue
    ) -> Self? {
        let value = Self(
            enabled: draft.enabled == original.enabled ? nil : draft.enabled,
            addr4: draft.addr4 == original.addr4 ? nil : draft.addr4,
            addr6: draft.addr6 == original.addr6 ? nil : draft.addr6,
            port: port == original.port ? nil : port
        )
        return value.enabled == nil && value.addr4 == nil && value.addr6 == nil && value.port == nil
            ? nil : value
    }
}

public struct RouterTLSDraftPatch: Equatable, Sendable {
    public var cert: String?
    public var key: String?

    public init(cert: String? = nil, key: String? = nil) {
        self.cert = cert
        self.key = key
    }


    static func changed(draft: RouterTLSDraft, original: RouterTLSSettingsValue) -> Self? {
        let value = Self(
            cert: draft.cert == original.cert ? nil : draft.cert,
            key: draft.key == original.key ? nil : draft.key
        )
        return value.cert == nil && value.key == nil ? nil : value
    }
}

public struct RouterMDNSDraftPatch: Equatable, Sendable {
    public var enabled: Bool?
    public var interfaces: [String]?

    public init(enabled: Bool? = nil, interfaces: [String]? = nil) {
        self.enabled = enabled
        self.interfaces = interfaces
    }


    static func changed(draft: RouterMDNSDraft, original: RouterMDNSSettingsValue) -> Self? {
        let value = Self(
            enabled: draft.enabled == original.enabled ? nil : draft.enabled,
            interfaces: draft.interfaces == original.interfaces ? nil : draft.interfaces
        )
        return value.enabled == nil && value.interfaces == nil ? nil : value
    }
}
