import Foundation

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
