import Foundation
import SwiftUI
import WattlineNetwork
import WattlineUI

enum RouterRuleConditionDraftKind: String, CaseIterable, Identifiable {
    case inputPower
    case batteryLevel
    case portPower
    case schedule

    var id: String { rawValue }

    var label: String {
        switch self {
        case .inputPower: "Input power"
        case .batteryLevel: "Battery level"
        case .portPower: "Port power"
        case .schedule: "Schedule"
        }
    }
}

enum RouterRuleActionDraftKind: String, CaseIterable, Identifiable {
    case dcOn
    case dcOff
    case usbcOn
    case usbcOff
    case bypassOn
    case bypassOff
    case restart
    case shutdown
    case webhook

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dcOn: "DC on"
        case .dcOff: "DC off"
        case .usbcOn: "USB-C on"
        case .usbcOff: "USB-C off"
        case .bypassOn: "Bypass on"
        case .bypassOff: "Bypass off"
        case .restart: "Restart"
        case .shutdown: "Shutdown"
        case .webhook: "Webhook"
        }
    }
}

struct RouterRuleActionDraft: Identifiable, Equatable {
    let id: UUID
    var kind: RouterRuleActionDraftKind
    var webhookURL: String

    init(
        id: UUID = UUID(),
        kind: RouterRuleActionDraftKind,
        webhookURL: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.webhookURL = webhookURL
    }

    init(action: RouterRuleAction) {
        switch action {
        case .dcOn: self.init(kind: .dcOn)
        case .dcOff: self.init(kind: .dcOff)
        case .usbcOn: self.init(kind: .usbcOn)
        case .usbcOff: self.init(kind: .usbcOff)
        case .bypassOn: self.init(kind: .bypassOn)
        case .bypassOff: self.init(kind: .bypassOff)
        case .restart: self.init(kind: .restart)
        case .shutdown: self.init(kind: .shutdown)
        case let .webhook(url):
            self.init(kind: .webhook, webhookURL: url.absoluteString)
        }
    }

    func validatedAction() throws -> RouterRuleAction {
        switch kind {
        case .dcOn: return .dcOn
        case .dcOff: return .dcOff
        case .usbcOn: return .usbcOn
        case .usbcOff: return .usbcOff
        case .bypassOn: return .bypassOn
        case .bypassOff: return .bypassOff
        case .restart: return .restart
        case .shutdown: return .shutdown
        case .webhook:
            guard let url = URL(string: webhookURL) else {
                throw RouterRuleDraftError.invalidField
            }
            return .webhook(url)
        }
    }
}

enum RouterRuleDraftError: Error {
    case invalidField
}

struct RouterRuleDraft: Equatable {
    var name = ""
    var enabled = true
    var conditionKind = RouterRuleConditionDraftKind.inputPower
    var inputState = RouterRuleInputState.present
    var comparison = RouterRuleComparison.below
    var percent = "20"
    var port = RouterRulePort.dc
    var watts = "0"
    var cron = "0 0 * * *"
    var hold = RouterRuleDurationDraft(value: "0", unit: .seconds)
    var hysteresisMargin = "5"
    var hasRepeatEvery = false
    var repeatEvery = RouterRuleDurationDraft(value: "0", unit: .seconds)
    var actions = [RouterRuleActionDraft(kind: .dcOff)]
    var confirmShutdown = false

    init() {}

    init(rule: RouterRule) {
        name = rule.name
        enabled = rule.enabled
        switch rule.condition {
        case let .inputPower(state):
            conditionKind = .inputPower
            inputState = state
        case let .batteryLevel(op, percent):
            conditionKind = .batteryLevel
            comparison = op
            self.percent = String(percent)
        case let .portPower(port, op, watts):
            conditionKind = .portPower
            self.port = port
            comparison = op
            self.watts = String(watts)
        case let .schedule(cron):
            conditionKind = .schedule
            self.cron = cron
        }
        hold = RouterRuleDurationDraft(
            nanoseconds: (try? rule.hold.nanoseconds()) ?? 0
        )
        hysteresisMargin = String(rule.hysteresisMargin)
        if let repeatEvery = rule.repeatEvery {
            hasRepeatEvery = true
            self.repeatEvery = RouterRuleDurationDraft(
                nanoseconds: (try? repeatEvery.nanoseconds()) ?? 0
            )
        }
        actions = rule.actions.map(RouterRuleActionDraft.init(action:))
        confirmShutdown = rule.confirmShutdown
    }

    func validatedRule() throws -> RouterRule {
        guard !name.isEmpty,
              name != RouterPowerLossPreset.reservedName,
              name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              let hysteresisMargin = Double(hysteresisMargin)
        else { throw RouterRuleDraftError.invalidField }

        let condition: RouterRuleCondition
        switch conditionKind {
        case .inputPower:
            condition = .inputPower(state: inputState)
        case .batteryLevel:
            guard let percent = Int(percent) else {
                throw RouterRuleDraftError.invalidField
            }
            condition = .batteryLevel(op: comparison, percent: percent)
        case .portPower:
            guard let watts = Double(watts) else {
                throw RouterRuleDraftError.invalidField
            }
            condition = .portPower(port: port, op: comparison, watts: watts)
        case .schedule:
            condition = .schedule(cron: cron)
        }

        let hold = try RouterRuleDuration(nanoseconds: hold.nanoseconds())
        let repeatDuration: RouterRuleDuration?
        if hasRepeatEvery {
            repeatDuration = try RouterRuleDuration(
                nanoseconds: repeatEvery.nanoseconds()
            )
        } else {
            repeatDuration = nil
        }
        return try RouterRule(
            name: name,
            enabled: enabled,
            condition: condition,
            hold: hold,
            hysteresisMargin: hysteresisMargin,
            repeatEvery: repeatDuration,
            actions: try actions.map { try $0.validatedAction() },
            confirmShutdown: confirmShutdown
        )
    }
}

struct RouterRulesView: View {
    let model: RouterAdministrationModel

    @State private var pendingDeletionName: String?

    private var automationDocuments: [RouterRuleDocument] {
        model.rules.filter { document in
            switch document {
            case let .known(rule):
                rule.name != RouterPowerLossPreset.reservedName
            case let .unknown(raw):
                raw.name != RouterPowerLossPreset.reservedName
            }
        }
    }

    private var powerLossDocument: RouterRuleDocument? {
        model.rules.first { document in
            switch document {
            case let .known(rule):
                rule.name == RouterPowerLossPreset.reservedName
            case let .unknown(raw):
                raw.name == RouterPowerLossPreset.reservedName
            }
        }
    }

    var body: some View {
        Group {
            powerLossSection

            Section("Automation Rules") {
                if model.access == .unlocked {
                    NavigationLink {
                        Form { RouterRuleEditor(model: model, mode: .create) }
                            .navigationTitle("Create rule")
                    } label: {
                        Label("Create rule", systemImage: "plus")
                    }
                }
                if automationDocuments.isEmpty, model.rulesLoadState == .loaded {
                    Text("No additional automation rules.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(automationDocuments.enumerated()), id: \.offset) { _, document in
                    switch document {
                    case let .known(rule):
                        knownRuleRow(rule)
                    case let .unknown(raw):
                        unknownRuleRow(raw)
                    }
                }
                if model.rulesLoadState == .initialLoading {
                    ProgressView("Loading automation rules…")
                } else if model.rulesLoadState == .refreshing {
                    ProgressView("Refreshing automation rules…")
                }
                Button("Refresh rules") { Task { await model.reloadRules() } }
            }

            if model.rulesLoadState == .stale {
                Section {
                    Text("These rules may be out of date.")
                        .foregroundStyle(.orange)
                }
            }
            if let message = model.rulesError {
                Section { Text(message).foregroundStyle(.orange) }
            }
        }
        .task(id: model.host?.endpoint.peripheralID) {
            guard model.host != nil else { return }
            await model.reloadRules()
        }
        .onChange(of: model.access) { _, access in
            if access != .unlocked { pendingDeletionName = nil }
        }
        .confirmationDialog(
            "Delete this automation rule?",
            isPresented: Binding(
                get: { pendingDeletionName != nil },
                set: { if !$0 { pendingDeletionName = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete rule", role: .destructive) {
                guard let name = pendingDeletionName else { return }
                pendingDeletionName = nil
                Task { await model.deleteRule(named: name) }
            }
            Button("Cancel", role: .cancel) { pendingDeletionName = nil }
        } message: {
            Text("Deleting a rule stops that automation immediately.")
        }
    }

    @ViewBuilder
    private var powerLossSection: some View {
        let preset = RouterPowerLossPreset(document: powerLossDocument)
        let presentation: RouterPowerLossPresentation = preset.isCompatible
            ? .compatible
            : .incompatible
        Section("Power-loss shutdown") {
            switch presentation.editorMode {
            case .editablePreservingFields:
                if case let .known(rule)? = powerLossDocument,
                   model.access == .unlocked
                {
                    RouterPowerLossEditor(model: model, rule: rule)
                } else {
                    powerLossSummary
                }
            case .readOnlyUntilReset:
                powerLossSummary
                if model.access == .unlocked {
                    RouterPowerLossReset(model: model)
                }
            }
        }
    }

    @ViewBuilder
    private var powerLossSummary: some View {
        if let powerLossDocument {
            switch powerLossDocument {
            case let .known(rule):
                Text(RouterRuleCopy.summary(rule))
                    .foregroundStyle(.secondary)
            case let .unknown(raw):
                unknownRuleRow(raw)
            }
        } else if model.rulesLoadState == .initialLoading {
            ProgressView()
        } else {
            Text("The reserved preset is not configured.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func unknownRuleRow(_ raw: RawRouterRule) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(raw.name ?? "Unknown rule")
                .font(.headline)
            Text("This rule uses fields this version of Wattline does not understand.")
                .foregroundStyle(.secondary)
            Text(raw.canonicalJSON)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func knownRuleRow(_ rule: RouterRule) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(rule.name).font(.headline)
                Spacer()
                Text(rule.enabled ? "Enabled" : "Disabled")
                    .foregroundStyle(.secondary)
            }
            Text(RouterRuleCopy.summary(rule))
                .foregroundStyle(.secondary)
            if model.access == .unlocked {
                NavigationLink("Edit rule") {
                    Form { RouterRuleEditor(model: model, mode: .update(rule)) }
                        .navigationTitle(rule.name)
                }
                Button("Delete \(rule.name)", role: .destructive) {
                    pendingDeletionName = rule.name
                }
            }
        }
    }
}

enum RouterRuleEditorMode {
    case create
    case update(RouterRule)
}

struct RouterRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    let model: RouterAdministrationModel

    private let mode: RouterRuleEditorMode
    @State private var draft: RouterRuleDraft
    @State private var confirmsShutdownSave = false

    init(model: RouterAdministrationModel, mode: RouterRuleEditorMode) {
        self.model = model
        self.mode = mode
        switch mode {
        case .create:
            _draft = State(initialValue: RouterRuleDraft())
        case let .update(rule):
            _draft = State(initialValue: RouterRuleDraft(rule: rule))
        }
    }

    private var hasWebhook: Bool {
        draft.actions.contains { $0.kind == .webhook }
    }

    private var hasShutdown: Bool {
        draft.actions.contains { $0.kind == .shutdown }
    }

    var body: some View {
        Section("Rule") {
            switch mode {
            case .create:
                TextField("Rule name", text: $draft.name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            case let .update(rule):
                LabeledContent("Rule name", value: rule.name)
            }
            Toggle("Enabled", isOn: $draft.enabled)
        }

        Section("Condition") {
            Picker("Condition", selection: $draft.conditionKind) {
                ForEach(RouterRuleConditionDraftKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            switch draft.conditionKind {
            case .inputPower:
                Picker("Input state", selection: $draft.inputState) {
                    Text("Present").tag(RouterRuleInputState.present)
                    Text("Absent").tag(RouterRuleInputState.absent)
                }
            case .batteryLevel:
                comparisonPicker
                TextField("Percent", text: $draft.percent)
                    .keyboardType(.numberPad)
            case .portPower:
                Picker("Port", selection: $draft.port) {
                    Text("DC").tag(RouterRulePort.dc)
                    Text("USB-C").tag(RouterRulePort.usbc)
                }
                comparisonPicker
                TextField("Watts", text: $draft.watts)
                    .keyboardType(.decimalPad)
            case .schedule:
                TextField("Cron", text: $draft.cron)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }

        Section("Timing") {
            TextField("Hold", text: $draft.hold.value)
                .keyboardType(.decimalPad)
                .monospacedDigit()
            Picker("Hold unit", selection: $draft.hold.unit) {
                durationUnitChoices
            }
            TextField("Hysteresis margin", text: $draft.hysteresisMargin)
                .keyboardType(.decimalPad)
            Toggle("Repeat", isOn: $draft.hasRepeatEvery)
            if draft.hasRepeatEvery {
                TextField("Repeat every", text: $draft.repeatEvery.value)
                    .keyboardType(.decimalPad)
                    .monospacedDigit()
                Picker("Repeat unit", selection: $draft.repeatEvery.unit) {
                    durationUnitChoices
                }
            }
        }

        Section("Actions") {
            ForEach($draft.actions) { $action in
                Picker("Action", selection: $action.kind) {
                    ForEach(RouterRuleActionDraftKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                if action.kind == .webhook {
                    TextField("Webhook URL", text: $action.webhookURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .onDelete { draft.actions.remove(atOffsets: $0) }
            Menu("Add action") {
                ForEach(RouterRuleActionDraftKind.allCases) { kind in
                    Button(kind.label) {
                        draft.actions.append(RouterRuleActionDraft(kind: kind))
                    }
                }
            }
            Toggle("Confirm shutdown", isOn: $draft.confirmShutdown)
        }

        if hasWebhook {
            Section("Webhook") {
                Text(RouterRulesPresentation.webhookWarning)
                    .foregroundStyle(.orange)
            }
        }
        Section("Save") {
            if hasShutdown {
                Button("Save shutdown rule", role: .destructive) {
                    confirmsShutdownSave = true
                }
                .disabled(validatedRule == nil || !canSave)
            } else {
                Button("Save rule") { save(confirmation: nil) }
                    .disabled(validatedRule == nil || !canSave)
            }
        }
        .onChange(of: model.access) { _, access in
            if access != .unlocked { dismiss() }
        }
        .confirmationDialog(
            "Save a shutdown automation?",
            isPresented: $confirmsShutdownSave,
            titleVisibility: .visible
        ) {
            Button("Save shutdown rule", role: .destructive) {
                save(confirmation: .shutdown)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A matching rule can shut down the connected power bank. Reconnect input power or use the hardware button to wake it.")
        }
    }

    private var canSave: Bool {
        model.access == .unlocked
            && RouterRulesPresentation.canSave(
                hasWebhook: hasWebhook,
                adminVerified: model.access == .unlocked
            )
    }

    @ViewBuilder
    private var comparisonPicker: some View {
        Picker("Comparison", selection: $draft.comparison) {
            Text("Below").tag(RouterRuleComparison.below)
            Text("Above").tag(RouterRuleComparison.above)
        }
    }

    @ViewBuilder
    private var durationUnitChoices: some View {
        ForEach(RouterRuleDurationUnit.allCases, id: \.rawValue) { unit in
            Text(unit.rawValue.capitalized).tag(unit)
        }
    }

    private var validatedRule: RouterRule? {
        guard let rule = try? draft.validatedRule() else { return nil }
        let conflictingName = model.rules.contains { document in
            let name: String?
            switch document {
            case let .known(existing): name = existing.name
            case let .unknown(raw): name = raw.name
            }
            guard name == rule.name else { return false }
            if case let .update(original) = mode {
                return name != original.name
            }
            return true
        }
        return conflictingName ? nil : rule
    }

    private func save(confirmation: RouterRuleConfirmation?) {
        guard let validatedRule else { return }
        Task {
            switch mode {
            case .create:
                await model.createRule(validatedRule, confirmation: confirmation)
            case let .update(original):
                await model.updateRule(
                    named: original.name,
                    rule: validatedRule,
                    confirmation: confirmation
                )
            }
            if model.rulesError == nil { dismiss() }
        }
    }
}

private struct RouterPowerLossEditor: View {
    let model: RouterAdministrationModel
    let rule: RouterRule

    @State private var enabled: Bool
    @State private var hold: RouterRuleDurationDraft
    @State private var confirmShutdown: Bool
    @State private var confirmsSave = false

    init(model: RouterAdministrationModel, rule: RouterRule) {
        self.model = model
        self.rule = rule
        _enabled = State(initialValue: rule.enabled)
        _hold = State(
            initialValue: RouterRuleDurationDraft(
                nanoseconds: (try? rule.hold.nanoseconds()) ?? 600_000_000_000
            )
        )
        _confirmShutdown = State(initialValue: rule.confirmShutdown)
    }

    var body: some View {
        Toggle("Enabled", isOn: $enabled)
        TextField("Hold", text: $hold.value)
            .keyboardType(.decimalPad)
            .monospacedDigit()
        Picker("Hold unit", selection: $hold.unit) {
            ForEach(RouterRuleDurationUnit.allCases, id: \.rawValue) { unit in
                Text(unit.rawValue.capitalized).tag(unit)
            }
        }
        Toggle("Confirm shutdown", isOn: $confirmShutdown)
        if rule.actions.contains(where: {
            if case .webhook = $0 { return true }
            return false
        }) {
            Text(RouterRulesPresentation.webhookWarning)
                .foregroundStyle(.orange)
        }
        Button("Review shutdown change", role: .destructive) {
            confirmsSave = true
        }
        .disabled(validatedHold == nil || !confirmShutdown || model.access != .unlocked)
        .confirmationDialog(
            "Save the power-loss shutdown preset?",
            isPresented: $confirmsSave,
            titleVisibility: .visible
        ) {
            Button("Save shutdown rule", role: .destructive) {
                guard let hold = validatedHold else { return }
                Task {
                    await model.savePowerLossPreset(
                        enabled: enabled,
                        hold: hold,
                        confirmShutdown: confirmShutdown,
                        confirmation: .shutdown
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("When input power remains absent for the hold duration, the router can shut down the connected power bank.")
        }
    }

    private var validatedHold: RouterRuleDuration? {
        guard let nanoseconds = try? hold.nanoseconds() else { return nil }
        return try? RouterRuleDuration(nanoseconds: nanoseconds)
    }
}

private struct RouterPowerLossReset: View {
    let model: RouterAdministrationModel
    @State private var confirmsReset = false

    var body: some View {
        Text("This preset is read-only until it is reset to the supported input-loss shutdown shape.")
            .foregroundStyle(.secondary)
        Button("Reset power-loss preset", role: .destructive) {
            confirmsReset = true
        }
        .confirmationDialog(
            "Reset the power-loss shutdown preset?",
            isPresented: $confirmsReset,
            titleVisibility: .visible
        ) {
            Button("Reset power-loss preset", role: .destructive) {
                Task {
                    await model.savePowerLossPreset(
                        enabled: true,
                        hold: RouterRuleDuration(.seconds(600)),
                        confirmShutdown: true,
                        confirmation: .resetPowerLossPreset
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Reset replaces every field and action in the reserved preset with a ten-minute input-loss shutdown rule.")
        }
    }
}

private enum RouterRuleCopy {
    static func summary(_ rule: RouterRule) -> String {
        "\(condition(rule.condition)); \(actions(rule.actions))"
    }

    static func condition(_ condition: RouterRuleCondition) -> String {
        switch condition {
        case let .inputPower(state):
            "Input power \(state.rawValue)"
        case let .batteryLevel(op, percent):
            "Battery \(op.rawValue) \(percent)%"
        case let .portPower(port, op, watts):
            "\(port.rawValue.uppercased()) power \(op.rawValue) \(watts.formatted()) W"
        case let .schedule(cron):
            "Schedule \(cron)"
        }
    }

    static func actions(_ actions: [RouterRuleAction]) -> String {
        actions.map { action in
            switch action {
            case .dcOn: "DC on"
            case .dcOff: "DC off"
            case .usbcOn: "USB-C on"
            case .usbcOff: "USB-C off"
            case .bypassOn: "Bypass on"
            case .bypassOff: "Bypass off"
            case .restart: "Restart"
            case .shutdown: "Shutdown"
            case let .webhook(url): "Webhook \(url.absoluteString)"
            }
        }.joined(separator: ", ")
    }
}
