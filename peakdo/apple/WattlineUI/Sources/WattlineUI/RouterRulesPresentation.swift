import Foundation

public enum RouterRuleDurationUnit: String, CaseIterable, Equatable, Sendable {
    case seconds
    case minutes
    case hours

    fileprivate var nanoseconds: Decimal {
        switch self {
        case .seconds: Decimal(1_000_000_000)
        case .minutes: Decimal(60_000_000_000)
        case .hours: Decimal(3_600_000_000_000)
        }
    }
}

public enum RouterRuleDurationDraftError: Error, Equatable, Sendable {
    case invalidValue
    case overflow
}

public struct RouterRuleDurationDraft: Equatable, Sendable {
    public var value: String
    public var unit: RouterRuleDurationUnit

    public init(value: String, unit: RouterRuleDurationUnit) {
        self.value = value
        self.unit = unit
    }

    public init(nanoseconds: Int64) {
        guard nanoseconds >= 0 else {
            value = String(nanoseconds)
            unit = .seconds
            return
        }
        if nanoseconds > 0, nanoseconds.isMultiple(of: 3_600_000_000_000) {
            value = String(nanoseconds / 3_600_000_000_000)
            unit = .hours
        } else if nanoseconds > 0, nanoseconds.isMultiple(of: 60_000_000_000) {
            value = String(nanoseconds / 60_000_000_000)
            unit = .minutes
        } else {
            let wholeSeconds = nanoseconds / 1_000_000_000
            let remainder = nanoseconds % 1_000_000_000
            if remainder == 0 {
                value = String(wholeSeconds)
            } else {
                let fraction = String(format: "%09lld", remainder)
                    .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
                value = "\(wholeSeconds).\(fraction)"
            }
            unit = .seconds
        }
    }

    public func nanoseconds() throws -> Int64 {
        let locale = Locale(identifier: "en_US_POSIX")
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let parsed = Decimal(string: value, locale: locale),
              parsed >= 0
        else { throw RouterRuleDurationDraftError.invalidValue }

        var lhs = parsed
        var rhs = unit.nanoseconds
        var product = Decimal()
        let multiplication = NSDecimalMultiply(&product, &lhs, &rhs, .plain)
        guard multiplication != .overflow else {
            throw RouterRuleDurationDraftError.overflow
        }
        guard multiplication == .noError else {
            throw RouterRuleDurationDraftError.invalidValue
        }

        var printable = product
        if let answer = Int64(NSDecimalString(&printable, locale)) {
            return answer
        }
        if product > Decimal(Int64.max) {
            throw RouterRuleDurationDraftError.overflow
        }
        throw RouterRuleDurationDraftError.invalidValue
    }
}

public struct RouterRulePresentationValue: Equatable, Sendable, Identifiable {
    public let name: String
    public let summary: String
    public let isKnown: Bool
    public let hasWebhook: Bool
    public let hasShutdown: Bool

    public var id: String { name }

    public init(
        name: String,
        summary: String,
        isKnown: Bool,
        hasWebhook: Bool,
        hasShutdown: Bool
    ) {
        self.name = name
        self.summary = summary
        self.isKnown = isKnown
        self.hasWebhook = hasWebhook
        self.hasShutdown = hasShutdown
    }
}

public struct RouterRuleRowPresentation: Equatable, Sendable {
    public let isReadOnly: Bool
    public let showsEditAction: Bool
    public let jsonSummary: String?

    public init(isReadOnly: Bool, showsEditAction: Bool, jsonSummary: String?) {
        self.isReadOnly = isReadOnly
        self.showsEditAction = showsEditAction
        self.jsonSummary = jsonSummary
    }
}

public enum RouterRuleConfirmation: Equatable, Sendable {
    case shutdown
    case resetPowerLossPreset
}

public enum RouterPowerLossEditorMode: Equatable, Sendable {
    case editablePreservingFields
    case readOnlyUntilReset
}

public struct RouterPowerLossPresentation: Equatable, Sendable {
    public let editorMode: RouterPowerLossEditorMode

    public init(editorMode: RouterPowerLossEditorMode) {
        self.editorMode = editorMode
    }

    public static let compatible = Self(editorMode: .editablePreservingFields)
    public static let incompatible = Self(editorMode: .readOnlyUntilReset)
}

public enum RouterRulesPresentation {
    public static let webhookWarning =
        "The router—not the Wattline app—makes this outbound request."

    public static func canSave(hasWebhook: Bool, adminVerified: Bool) -> Bool {
        !hasWebhook || adminVerified
    }

    public static func confirmation(
        hasShutdown: Bool,
        resetsPreset: Bool
    ) -> RouterRuleConfirmation? {
        if resetsPreset { return .resetPowerLossPreset }
        if hasShutdown { return .shutdown }
        return nil
    }

    public static func row(
        for value: RouterRulePresentationValue,
        adminVerified: Bool
    ) -> RouterRuleRowPresentation {
        RouterRuleRowPresentation(
            isReadOnly: !value.isKnown,
            showsEditAction: value.isKnown && adminVerified,
            jsonSummary: value.isKnown ? nil : value.summary
        )
    }
}
