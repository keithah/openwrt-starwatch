import Foundation

private func exactDouble(_ value: Decimal) -> Double? {
    let converted = NSDecimalNumber(decimal: value).doubleValue
    guard converted.isFinite,
          Decimal(
              string: String(converted),
              locale: Locale(identifier: "en_US_POSIX")
          ) == value
    else { return nil }
    return converted
}

public enum RouterRuleValidationError: Error, Equatable, Sendable {
    case invalidDuration
    case durationOverflow
    case invalidRule
    case unknownRuleCannotMutate
    case incompatiblePreset
    case resetConfirmationRequired
}

public enum RouterJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case decimal(Decimal)
    /// Preserved for source compatibility when callers construct JSON values
    /// from an already-represented finite Double. Decoding uses the exact
    /// integer and Decimal cases instead.
    case number(Double)
    case string(String)
    case array([RouterJSONValue])
    case object([String: RouterJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            let converted = Double(value)
            self = Int64(exactly: converted) == value
                ? .number(converted)
                : .integer(value)
        } else if let value = try? container.decode(Decimal.self) {
            self = exactDouble(value).map(Self.number) ?? .decimal(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([RouterJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: RouterJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .decimal(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}

public struct RouterRuleDuration: Equatable, Sendable {
    public let value: Duration

    public init(_ value: Duration) {
        self.value = value
    }

    public init(nanoseconds: Int64) throws {
        guard nanoseconds >= 0 else {
            throw RouterRuleValidationError.invalidDuration
        }
        value = .seconds(nanoseconds / 1_000_000_000)
            + .nanoseconds(nanoseconds % 1_000_000_000)
    }

    public func nanoseconds() throws -> Int64 {
        let parts = value.components
        guard parts.seconds >= 0,
              parts.attoseconds >= 0,
              parts.attoseconds % 1_000_000_000 == 0
        else { throw RouterRuleValidationError.invalidDuration }
        let (whole, overflow1) = parts.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let (answer, overflow2) = whole.addingReportingOverflow(
            parts.attoseconds / 1_000_000_000
        )
        guard !overflow1, !overflow2 else {
            throw RouterRuleValidationError.durationOverflow
        }
        return answer
    }
}

public enum RouterRuleInputState: String, Codable, Sendable {
    case present
    case absent
}

public enum RouterRuleComparison: String, Codable, Sendable {
    case below
    case above
}

public enum RouterRulePort: String, Codable, Sendable {
    case dc
    case usbc
}

public enum RouterRuleCondition: Equatable, Sendable {
    case inputPower(state: RouterRuleInputState)
    case batteryLevel(op: RouterRuleComparison, percent: Int)
    case portPower(port: RouterRulePort, op: RouterRuleComparison, watts: Double)
    case schedule(cron: String)
}

public enum RouterRuleAction: Equatable, Sendable {
    case dcOn
    case dcOff
    case usbcOn
    case usbcOff
    case bypassOn
    case bypassOff
    case restart
    case shutdown
    case webhook(URL)
}

public struct RouterRule: Codable, Equatable, Sendable {
    public let name: String
    public let enabled: Bool
    public let condition: RouterRuleCondition
    public let hold: RouterRuleDuration
    public let hysteresisMargin: Double
    public let repeatEvery: RouterRuleDuration?
    public let actions: [RouterRuleAction]
    public let confirmShutdown: Bool

    public init(
        name: String,
        enabled: Bool,
        condition: RouterRuleCondition,
        hold: RouterRuleDuration,
        hysteresisMargin: Double,
        repeatEvery: RouterRuleDuration? = nil,
        actions: [RouterRuleAction],
        confirmShutdown: Bool
    ) throws {
        guard !name.isEmpty,
              hysteresisMargin.isFinite,
              hysteresisMargin >= 0
        else { throw RouterRuleValidationError.invalidRule }
        _ = try hold.nanoseconds()
        let normalizedRepeat: RouterRuleDuration?
        if let repeatEvery {
            normalizedRepeat = try repeatEvery.nanoseconds() == 0 ? nil : repeatEvery
        } else {
            normalizedRepeat = nil
        }
        switch condition {
        case .inputPower:
            break
        case let .batteryLevel(_, percent):
            guard (0...100).contains(percent) else {
                throw RouterRuleValidationError.invalidRule
            }
        case let .portPower(_, _, watts):
            guard watts.isFinite, watts >= 0 else {
                throw RouterRuleValidationError.invalidRule
            }
        case let .schedule(cron):
            guard cron.split(whereSeparator: { $0.isWhitespace }).count == 5 else {
                throw RouterRuleValidationError.invalidRule
            }
        }
        for action in actions {
            if case let .webhook(url) = action {
                guard Self.isValidWebhook(url) else {
                    throw RouterRuleValidationError.invalidRule
                }
            }
        }
        guard !actions.contains(.shutdown) || confirmShutdown else {
            throw RouterRuleValidationError.invalidRule
        }

        self.name = name
        self.enabled = enabled
        self.condition = condition
        self.hold = hold
        self.hysteresisMargin = hysteresisMargin == 0 ? 5 : hysteresisMargin
        self.repeatEvery = normalizedRepeat
        self.actions = actions
        self.confirmShutdown = confirmShutdown
    }

    public init(from decoder: Decoder) throws {
        let document = try RouterRuleDocument(from: decoder)
        guard case let .known(rule) = document else {
            throw RouterRuleValidationError.unknownRuleCannotMutate
        }
        self = rule
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(name, forKey: .name)
        try values.encode(enabled, forKey: .enabled)
        switch condition {
        case let .inputPower(state):
            try values.encode("input_power", forKey: .condition)
            try values.encode(state, forKey: .state)
        case let .batteryLevel(op, percent):
            try values.encode("battery_level", forKey: .condition)
            try values.encode(op, forKey: .op)
            try values.encode(percent, forKey: .percent)
        case let .portPower(port, op, watts):
            try values.encode("port_power", forKey: .condition)
            try values.encode(port, forKey: .port)
            try values.encode(op, forKey: .op)
            try values.encode(watts, forKey: .watts)
        case let .schedule(cron):
            try values.encode("schedule", forKey: .condition)
            try values.encode(cron, forKey: .cron)
        }
        try values.encode(hold.nanoseconds(), forKey: .hold)
        try values.encode(hysteresisMargin, forKey: .hysteresisMargin)
        if let repeatEvery {
            try values.encode(repeatEvery.nanoseconds(), forKey: .repeatEvery)
        }
        try values.encode(actions.map(Self.actionString), forKey: .actions)
        try values.encode(confirmShutdown, forKey: .confirmShutdown)
    }

    private enum CodingKeys: String, CodingKey {
        case name, enabled, condition, state, op, percent, port, watts, cron, hold, actions
        case hysteresisMargin = "hysteresis_margin"
        case repeatEvery = "repeat_every"
        case confirmShutdown = "confirm_shutdown"
    }

    fileprivate static func actionString(_ action: RouterRuleAction) -> String {
        switch action {
        case .dcOn: "dc_on"
        case .dcOff: "dc_off"
        case .usbcOn: "usbc_on"
        case .usbcOff: "usbc_off"
        case .bypassOn: "bypass_on"
        case .bypassOff: "bypass_off"
        case .restart: "restart"
        case .shutdown: "shutdown"
        case let .webhook(url): "webhook:\(url.absoluteString)"
        }
    }

    fileprivate static func isValidWebhook(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty
        else { return false }
        return true
    }
}

public struct RawRouterRule: Equatable, Sendable {
    public let name: String?
    public let json: RouterJSONValue
    public let canonicalJSON: String

    public init(name: String?, json: RouterJSONValue, canonicalJSON: String) {
        self.name = name
        self.json = json
        self.canonicalJSON = canonicalJSON
    }
}

public enum RouterRuleDocument: Equatable, Sendable, Codable {
    case known(RouterRule)
    case unknown(RawRouterRule)

    public init(from decoder: Decoder) throws {
        let json = try RouterJSONValue(from: decoder)
        guard case let .object(object) = json else {
            throw RouterRuleValidationError.invalidRule
        }
        let raw = try Self.rawRule(json: json, object: object)
        guard let conditionName = object.string("condition") else {
            throw RouterRuleValidationError.invalidRule
        }

        let conditionKeys: Set<String>
        switch conditionName {
        case "input_power":
            conditionKeys = ["state"]
        case "battery_level":
            conditionKeys = ["op", "percent"]
        case "port_power":
            conditionKeys = ["port", "op", "watts"]
        case "schedule":
            conditionKeys = ["cron"]
        default:
            self = .unknown(raw)
            return
        }

        let requiredCommon: Set<String> = [
            "name", "enabled", "condition", "hold", "hysteresis_margin", "actions",
            "confirm_shutdown",
        ]
        let allowed = requiredCommon.union(conditionKeys).union(["repeat_every"])
        guard requiredCommon.isSubset(of: object.keys),
              conditionKeys.isSubset(of: object.keys)
        else { throw RouterRuleValidationError.invalidRule }
        guard Set(object.keys).isSubset(of: allowed) else {
            self = .unknown(raw)
            return
        }

        let condition: RouterRuleCondition
        switch conditionName {
        case "input_power":
            guard let rawState = object.string("state") else {
                throw RouterRuleValidationError.invalidRule
            }
            guard let state = RouterRuleInputState(rawValue: rawState) else {
                self = .unknown(raw)
                return
            }
            condition = .inputPower(state: state)
        case "battery_level":
            guard let rawOp = object.string("op") else {
                throw RouterRuleValidationError.invalidRule
            }
            guard let op = RouterRuleComparison(rawValue: rawOp) else {
                self = .unknown(raw)
                return
            }
            guard let percent = object.integer("percent") else {
                throw RouterRuleValidationError.invalidRule
            }
            condition = .batteryLevel(op: op, percent: percent)
        case "port_power":
            guard let rawPort = object.string("port"),
                  let rawOp = object.string("op")
            else { throw RouterRuleValidationError.invalidRule }
            guard let port = RouterRulePort(rawValue: rawPort),
                  let op = RouterRuleComparison(rawValue: rawOp)
            else {
                self = .unknown(raw)
                return
            }
            guard let watts = object.number("watts") else {
                throw RouterRuleValidationError.invalidRule
            }
            condition = .portPower(port: port, op: op, watts: watts)
        case "schedule":
            guard let cron = object.string("cron") else {
                throw RouterRuleValidationError.invalidRule
            }
            condition = .schedule(cron: cron)
        default:
            throw RouterRuleValidationError.invalidRule
        }
        guard let name = object.string("name"),
              let enabled = object.bool("enabled"),
              let holdNanoseconds = object.int64("hold"),
              let hysteresisMargin = object.number("hysteresis_margin"),
              case let .array(actionValues)? = object["actions"],
              let confirmShutdown = object.bool("confirm_shutdown")
        else { throw RouterRuleValidationError.invalidRule }

        var actions: [RouterRuleAction] = []
        actions.reserveCapacity(actionValues.count)
        for value in actionValues {
            guard case let .string(actionName) = value,
                  let action = Self.action(from: actionName)
            else {
                self = .unknown(raw)
                return
            }
            actions.append(action)
        }
        let repeatEvery: RouterRuleDuration?
        if object["repeat_every"] != nil {
            guard let nanoseconds = object.int64("repeat_every") else {
                throw RouterRuleValidationError.invalidRule
            }
            repeatEvery = try RouterRuleDuration(nanoseconds: nanoseconds)
        } else {
            repeatEvery = nil
        }
        self = .known(try RouterRule(
            name: name,
            enabled: enabled,
            condition: condition,
            hold: RouterRuleDuration(nanoseconds: holdNanoseconds),
            hysteresisMargin: hysteresisMargin,
            repeatEvery: repeatEvery,
            actions: actions,
            confirmShutdown: confirmShutdown
        ))
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .known(rule):
            try rule.encode(to: encoder)
        case .unknown:
            throw RouterRuleValidationError.unknownRuleCannotMutate
        }
    }

    private static func rawRule(
        json: RouterJSONValue,
        object: [String: RouterJSONValue]
    ) throws -> RawRouterRule {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let canonicalJSON = String(
            decoding: try encoder.encode(json),
            as: UTF8.self
        )
        return RawRouterRule(
            name: object.string("name"),
            json: json,
            canonicalJSON: canonicalJSON
        )
    }

    private static func action(from value: String) -> RouterRuleAction? {
        switch value {
        case "dc_on": return .dcOn
        case "dc_off": return .dcOff
        case "usbc_on": return .usbcOn
        case "usbc_off": return .usbcOff
        case "bypass_on": return .bypassOn
        case "bypass_off": return .bypassOff
        case "restart": return .restart
        case "shutdown": return .shutdown
        default:
            guard value.hasPrefix("webhook:") else { return nil }
            let suffix = String(value.dropFirst("webhook:".count))
            guard let url = URL(string: suffix), RouterRule.isValidWebhook(url) else {
                return nil
            }
            return .webhook(url)
        }
    }
}

private extension Dictionary where Key == String, Value == RouterJSONValue {
    func string(_ key: String) -> String? {
        guard case let .string(value)? = self[key] else { return nil }
        return value
    }

    func bool(_ key: String) -> Bool? {
        guard case let .bool(value)? = self[key] else { return nil }
        return value
    }

    func number(_ key: String) -> Double? {
        switch self[key] {
        case let .integer(value):
            let converted = Double(value)
            guard Int64(exactly: converted) == value else { return nil }
            return converted
        case let .decimal(value):
            return exactDouble(value)
        case let .number(value):
            return value.isFinite ? value : nil
        default:
            return nil
        }
    }

    func int64(_ key: String) -> Int64? {
        switch self[key] {
        case let .integer(value):
            return value
        case var .decimal(value):
            return Int64(NSDecimalString(&value, Locale(identifier: "en_US_POSIX")))
        case let .number(value):
            guard value.isFinite else { return nil }
            return Int64(exactly: value)
        default:
            return nil
        }
    }

    func integer(_ key: String) -> Int? {
        guard let value = int64(key) else { return nil }
        return Int(exactly: value)
    }
}

public struct RouterRuleMutationResult: Equatable, Sendable {
    public let stored: RouterRule?
    public let deletedName: String?
    public let rules: [RouterRuleDocument]

    public init(
        stored: RouterRule?,
        deletedName: String?,
        rules: [RouterRuleDocument]
    ) {
        self.stored = stored
        self.deletedName = deletedName
        self.rules = rules
    }
}

extension RouterAdministrationClient {
    public func rules() async throws -> [RouterRuleDocument] {
        let attachment = try attachmentLease()
        await acquirePrivilegedMutation()
        defer { releasePrivilegedMutation() }
        try Task.checkCancellation()
        return try await rulesUnserialized(attachment: attachment)
    }

    public func createRule(_ rule: RouterRule) async throws -> RouterRuleMutationResult {
        let attachment = try attachmentLease()
        let body = try Self.encodeRule(rule)
        await acquirePrivilegedMutation()
        defer { releasePrivilegedMutation() }
        try Task.checkCancellation()
        try validate(attachment: attachment)
        let (data, _) = try await sendDurableMutation(
            "POST",
            "/api/v1/rules",
            body: body,
            attachment: attachment
        )
        let stored = try Self.decodeStoredRule(data, expectedName: rule.name)
        let listed = try await rulesUnserialized(attachment: attachment)
        return RouterRuleMutationResult(
            stored: stored,
            deletedName: nil,
            rules: listed
        )
    }

    public func updateRule(
        named name: String,
        rule: RouterRule
    ) async throws -> RouterRuleMutationResult {
        guard !name.isEmpty else { throw RouterRuleValidationError.invalidRule }
        let updated = try RouterRule(
            name: name,
            enabled: rule.enabled,
            condition: rule.condition,
            hold: rule.hold,
            hysteresisMargin: rule.hysteresisMargin,
            repeatEvery: rule.repeatEvery,
            actions: rule.actions,
            confirmShutdown: rule.confirmShutdown
        )
        let attachment = try attachmentLease()
        let path = "/api/v1/rules/\(Self.percentEncodedRuleName(name))"
        let body = try Self.encodeRule(updated)
        await acquirePrivilegedMutation()
        defer { releasePrivilegedMutation() }
        try Task.checkCancellation()
        try validate(attachment: attachment)
        let (data, _) = try await sendDurableMutation(
            "PUT",
            path,
            body: body,
            attachment: attachment
        )
        let stored = try Self.decodeStoredRule(data, expectedName: name)
        let listed = try await rulesUnserialized(attachment: attachment)
        return RouterRuleMutationResult(
            stored: stored,
            deletedName: nil,
            rules: listed
        )
    }

    public func deleteRule(named name: String) async throws -> RouterRuleMutationResult {
        guard !name.isEmpty else { throw RouterRuleValidationError.invalidRule }
        let attachment = try attachmentLease()
        let path = "/api/v1/rules/\(Self.percentEncodedRuleName(name))"
        await acquirePrivilegedMutation()
        defer { releasePrivilegedMutation() }
        try Task.checkCancellation()
        try validate(attachment: attachment)
        let (data, _) = try await sendDurableMutation(
            "DELETE",
            path,
            attachment: attachment
        )
        let deletedName = try Self.decodeDeletedRule(data, expectedName: name)
        let listed = try await rulesUnserialized(attachment: attachment)
        return RouterRuleMutationResult(
            stored: nil,
            deletedName: deletedName,
            rules: listed
        )
    }

    private func rulesUnserialized(
        attachment: RouterAdministrationAttachmentLease
    ) async throws -> [RouterRuleDocument] {
        try Task.checkCancellation()
        try validate(attachment: attachment)
        let (data, _) = try await sendClient("GET", "/api/v1/rules")
        try validate(attachment: attachment)
        do {
            return try JSONDecoder().decode([RouterRuleDocument].self, from: data)
        } catch {
            throw RouterAdministrationError.invalidResponse
        }
    }

    private static func decodeStoredRule(
        _ data: Data,
        expectedName: String
    ) throws -> RouterRule {
        let document: RouterRuleDocument
        do {
            document = try JSONDecoder().decode(RouterRuleDocument.self, from: data)
        } catch {
            throw RouterAdministrationError.invalidResponse
        }
        guard case let .known(rule) = document else {
            throw RouterRuleValidationError.unknownRuleCannotMutate
        }
        guard rule.name == expectedName else {
            throw RouterAdministrationError.invalidResponse
        }
        return rule
    }

    private static func decodeDeletedRule(
        _ data: Data,
        expectedName: String
    ) throws -> String {
        guard let json = try? JSONDecoder().decode(RouterJSONValue.self, from: data),
              case let .object(object) = json,
              Set(object.keys) == ["deleted"],
              let deleted = object.string("deleted"),
              deleted == expectedName
        else { throw RouterAdministrationError.invalidResponse }
        return deleted
    }

    private static func percentEncodedRuleName(_ name: String) -> String {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return name.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static func encodeRule(_ rule: RouterRule) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(rule)
    }
}

public struct RouterPowerLossPreset: Equatable, Sendable {
    public static let reservedName = "no_input_shutdown"

    public let source: RouterRuleDocument?

    public init(document: RouterRuleDocument?) {
        source = document
    }

    public var isCompatible: Bool {
        Self.compatibleRule(in: source) != nil
    }

    public func updating(
        enabled: Bool,
        hold: RouterRuleDuration,
        confirmShutdown: Bool
    ) throws -> RouterRule {
        guard let source = Self.compatibleRule(in: source) else {
            throw RouterRuleValidationError.incompatiblePreset
        }
        return try RouterRule(
            name: source.name,
            enabled: enabled,
            condition: source.condition,
            hold: hold,
            hysteresisMargin: source.hysteresisMargin,
            repeatEvery: source.repeatEvery,
            actions: source.actions,
            confirmShutdown: confirmShutdown
        )
    }

    public func reset(
        enabled: Bool,
        hold: RouterRuleDuration,
        confirmed: Bool
    ) throws -> RouterRule {
        guard confirmed else {
            throw RouterRuleValidationError.resetConfirmationRequired
        }
        return try RouterRule(
            name: Self.reservedName,
            enabled: enabled,
            condition: .inputPower(state: .absent),
            hold: hold,
            hysteresisMargin: 5,
            repeatEvery: nil,
            actions: [.shutdown],
            confirmShutdown: true
        )
    }

    private static func compatibleRule(
        in document: RouterRuleDocument?
    ) -> RouterRule? {
        guard case let .known(rule)? = document,
              rule.name == reservedName,
              case let .inputPower(state) = rule.condition,
              state == .absent,
              rule.actions.contains(.shutdown)
        else { return nil }
        return rule
    }
}
