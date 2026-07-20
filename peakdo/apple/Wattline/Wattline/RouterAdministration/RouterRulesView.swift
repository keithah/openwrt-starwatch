import SwiftUI
import WattlineNetwork
import WattlineUI

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
                    Form { RouterKnownRuleEditor(model: model, rule: rule) }
                        .navigationTitle(rule.name)
                }
                Button("Delete \(rule.name)", role: .destructive) {
                    pendingDeletionName = rule.name
                }
            }
        }
    }
}

private struct RouterKnownRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    let model: RouterAdministrationModel
    let rule: RouterRule

    @State private var enabled: Bool
    @State private var holdNanoseconds: String
    @State private var confirmShutdown: Bool
    @State private var confirmsShutdownSave = false

    init(model: RouterAdministrationModel, rule: RouterRule) {
        self.model = model
        self.rule = rule
        _enabled = State(initialValue: rule.enabled)
        _holdNanoseconds = State(
            initialValue: (try? rule.hold.nanoseconds()).map(String.init) ?? ""
        )
        _confirmShutdown = State(initialValue: rule.confirmShutdown)
    }

    private var hasWebhook: Bool {
        rule.actions.contains { action in
            if case .webhook = action { return true }
            return false
        }
    }

    private var hasShutdown: Bool { rule.actions.contains(.shutdown) }

    var body: some View {
        Section("Rule") {
            Toggle("Enabled", isOn: $enabled)
            TextField("Hold (nanoseconds)", text: $holdNanoseconds)
                .keyboardType(.numberPad)
                .monospacedDigit()
            if hasShutdown {
                Toggle("Confirm shutdown", isOn: $confirmShutdown)
            }
            LabeledContent("Condition", value: RouterRuleCopy.condition(rule.condition))
            LabeledContent("Actions", value: RouterRuleCopy.actions(rule.actions))
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
                .disabled(updatedRule == nil || !canSave)
            } else {
                Button("Save rule") { save(confirmation: nil) }
                    .disabled(updatedRule == nil || !canSave)
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

    private var updatedRule: RouterRule? {
        guard let nanoseconds = Int64(holdNanoseconds), nanoseconds >= 0 else { return nil }
        return try? RouterRule(
            name: rule.name,
            enabled: enabled,
            condition: rule.condition,
            hold: RouterRuleDuration(nanoseconds: nanoseconds),
            hysteresisMargin: rule.hysteresisMargin,
            repeatEvery: rule.repeatEvery,
            actions: rule.actions,
            confirmShutdown: confirmShutdown
        )
    }

    private func save(confirmation: RouterRuleConfirmation?) {
        guard let updatedRule else { return }
        Task {
            await model.updateRule(
                named: rule.name,
                rule: updatedRule,
                confirmation: confirmation
            )
            if model.rulesError == nil { dismiss() }
        }
    }
}

private struct RouterPowerLossEditor: View {
    let model: RouterAdministrationModel
    let rule: RouterRule

    @State private var enabled: Bool
    @State private var holdNanoseconds: String
    @State private var confirmShutdown: Bool
    @State private var confirmsSave = false

    init(model: RouterAdministrationModel, rule: RouterRule) {
        self.model = model
        self.rule = rule
        _enabled = State(initialValue: rule.enabled)
        _holdNanoseconds = State(
            initialValue: (try? rule.hold.nanoseconds()).map(String.init) ?? "600000000000"
        )
        _confirmShutdown = State(initialValue: rule.confirmShutdown)
    }

    var body: some View {
        Toggle("Enabled", isOn: $enabled)
        TextField("Hold (nanoseconds)", text: $holdNanoseconds)
            .keyboardType(.numberPad)
            .monospacedDigit()
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
        .disabled(hold == nil || !confirmShutdown || model.access != .unlocked)
        .confirmationDialog(
            "Save the power-loss shutdown preset?",
            isPresented: $confirmsSave,
            titleVisibility: .visible
        ) {
            Button("Save shutdown rule", role: .destructive) {
                guard let hold else { return }
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

    private var hold: RouterRuleDuration? {
        guard let value = Int64(holdNanoseconds), value >= 0 else { return nil }
        return try? RouterRuleDuration(nanoseconds: value)
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
