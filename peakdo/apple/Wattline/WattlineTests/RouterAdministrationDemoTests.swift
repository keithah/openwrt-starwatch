import Foundation
import WattlineNetwork
import XCTest
@testable import Wattline

@MainActor
final class RouterAdministrationDemoTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_721_260_800)

    func testDemoFixtureContainsEveryAdministrationSurface() throws {
        let demo = try RouterAdministrationDemo.fixture(now: now)

        XCTAssertEqual(demo.host.displayName, "Wattline Demo Router")
        XCTAssertEqual(demo.identity.id, "AABBCCDDEEFF")
        XCTAssertGreaterThanOrEqual(demo.history.count, 24)
        XCTAssertEqual(demo.history.last?.at, now)
        XCTAssertNotNil(demo.settings)
        XCTAssertEqual(demo.settings.blePIN, "")
        XCTAssertTrue(demo.pairingMode.open)
        XCTAssertNil(demo.pairingMode.pin)
        XCTAssertFalse(demo.tokens.isEmpty)
        XCTAssertFalse(demo.devicePairingStatus.devices.isEmpty)
        XCTAssertFalse(demo.advancedVisibility.surfaces.isEmpty)
        XCTAssertFalse(demo.rules.isEmpty)

        XCTAssertTrue(demo.rules.contains { document in
            guard case .known = document else { return false }
            return true
        })
        XCTAssertTrue(demo.rules.contains { document in
            guard case .unknown = document else { return false }
            return true
        })
        let powerLoss = demo.rules.first { document in
            switch document {
            case let .known(rule): rule.name == RouterPowerLossPreset.reservedName
            case let .unknown(raw): raw.name == RouterPowerLossPreset.reservedName
            }
        }
        XCTAssertTrue(RouterPowerLossPreset(document: powerLoss).isCompatible)
    }

    func testDemoFixtureIsDeterministicAndContainsNoPersistedSecrets() throws {
        let first = try RouterAdministrationDemo.fixture(now: now)
        let second = try RouterAdministrationDemo.fixture(now: now)

        XCTAssertEqual(first, second)
        XCTAssertNil(first.pairingMode.pin)
        XCTAssertEqual(first.settings.blePIN, "")
        XCTAssertFalse(first.description.localizedCaseInsensitiveContains("token"))
        XCTAssertFalse(first.description.localizedCaseInsensitiveContains("pin"))
    }

    func testDemoNeverTouchesCredentialOrHostPersistence() async throws {
        let credentials = RecordingDemoCredentialBackend()
        let hosts = RecordingDemoHostBackend()
        let model = RouterAdministrationModel.demo(
            credentials: credentials,
            hosts: hosts,
            now: now
        )

        let removableName = try XCTUnwrap(model.rules.compactMap { document -> String? in
            guard case let .known(rule) = document,
                  rule.name != RouterPowerLossPreset.reservedName
            else { return nil }
            return rule.name
        }.first)
        await model.deleteRule(named: removableName)

        XCTAssertFalse(model.rules.contains { document in
            guard case let .known(rule) = document else { return false }
            return rule.name == removableName
        })
        let credentialCalls = await credentials.recordedCalls()
        XCTAssertTrue(credentialCalls.isEmpty)
        XCTAssertTrue(hosts.recordedCalls().isEmpty)
    }

    func testLeavingDemoAdministrationPreservesNavigationAndInMemoryMutations() async throws {
        let model = RouterAdministrationModel.demo(now: now)
        let host = try XCTUnwrap(model.host)
        let removableName = try XCTUnwrap(model.rules.compactMap { document -> String? in
            guard case let .known(rule) = document,
                  rule.name != RouterPowerLossPreset.reservedName
            else { return nil }
            return rule.name
        }.first)

        await model.deleteRule(named: removableName)
        await model.end()

        XCTAssertEqual(model.host, host)
        XCTAssertFalse(model.rules.contains { document in
            guard case let .known(rule) = document else { return false }
            return rule.name == removableName
        })

        await model.open(host: host)
        XCTAssertEqual(model.host, host)
        XCTAssertFalse(model.rules.contains { document in
            guard case let .known(rule) = document else { return false }
            return rule.name == removableName
        })
    }

    func testDemoSettingsAcknowledgesBLEPINWithoutRetainingOrPersistingIt() async throws {
        let credentials = RecordingDemoCredentialBackend()
        let hosts = RecordingDemoHostBackend()
        let model = RouterAdministrationModel.demo(
            credentials: credentials,
            hosts: hosts,
            now: now
        )
        let secret = "739204"

        let outcome = await model.saveSettings(RouterSettingsPatch(blePIN: secret))

        XCTAssertEqual(outcome, .accepted)
        let settings = try XCTUnwrap(model.settings)
        XCTAssertEqual(settings.blePIN, "")
        XCTAssertFalse(String(describing: settings).contains(secret))
        XCTAssertFalse(String(reflecting: settings).contains(secret))
        let credentialCalls = await credentials.recordedCalls()
        XCTAssertTrue(credentialCalls.isEmpty)
        XCTAssertTrue(hosts.recordedCalls().isEmpty)
    }

    func testDemoUpdateDoesNotReplaceUnknownRawRuleWithKnownRule() async throws {
        let model = RouterAdministrationModel.demo(now: now)
        let original = try XCTUnwrap(model.rules.first { document in
            guard case let .unknown(raw) = document else { return false }
            return raw.name == "future_telemetry"
        })
        let attemptedReplacement = try RouterRule(
            name: "future_telemetry",
            enabled: false,
            condition: .inputPower(state: .absent),
            hold: RouterRuleDuration(.seconds(60)),
            hysteresisMargin: 5,
            actions: [.dcOff],
            confirmShutdown: false
        )

        await model.updateRule(
            named: "future_telemetry",
            rule: attemptedReplacement,
            confirmation: nil
        )

        XCTAssertEqual(
            model.rules.first { document in
                switch document {
                case let .known(rule): rule.name == "future_telemetry"
                case let .unknown(raw): raw.name == "future_telemetry"
                }
            },
            original
        )
    }

    func testDemoDeleteDoesNotRemoveUnknownRawRule() async throws {
        let model = RouterAdministrationModel.demo(now: now)
        let original = try XCTUnwrap(model.rules.first { document in
            guard case let .unknown(raw) = document else { return false }
            return raw.name == "future_telemetry"
        })

        await model.deleteRule(named: "future_telemetry")

        XCTAssertEqual(
            model.rules.first { document in
                guard case let .unknown(raw) = document else { return false }
                return raw.name == "future_telemetry"
            },
            original
        )
    }

    func testDemoPairingReloadRestoresRedactedStateAfterLifecycleClear() async throws {
        let model = RouterAdministrationModel.demo(now: now)
        let original = try XCTUnwrap(model.pairingStatus)

        model.pairingDidEnterBackground()
        XCTAssertNil(model.pairingStatus)

        await model.reloadPairingMode()

        let restored = try XCTUnwrap(model.pairingStatus)
        XCTAssertEqual(restored.open, original.open)
        XCTAssertEqual(restored.expiresAt, original.expiresAt)
        XCTAssertNil(restored.pin)
    }

    func testRequiredAccessibilityIdentifiersAreInSharedAndPlatformViews() throws {
        let sharedPaths = [
            "../WattlineShared/RouterAdministration/RouterAdvancedView.swift",
            "../WattlineShared/RouterAdministration/RouterDevicePairingView.swift",
            "../WattlineShared/RouterAdministration/RouterHistoryView.swift",
            "../WattlineShared/RouterAdministration/RouterPairingModeView.swift",
            "../WattlineShared/RouterAdministration/RouterRulesView.swift",
            "../WattlineShared/RouterAdministration/RouterSettingsView.swift",
            "../WattlineShared/RouterAdministration/RouterTokensView.swift",
        ]
        let platformPaths = [
            "Wattline/RootView.swift",
            "Wattline/Settings/SettingsView.swift",
            "Wattline/RouterAdministration/RouterAdministrationView.swift",
            "WattlineMac/MacMenuBarView.swift",
            "WattlineMac/MacRootView.swift",
            "WattlineMac/RouterAdministration/MacRouterAdministrationView.swift",
        ]
        let text = try (sharedPaths + platformPaths)
            .map { try source($0) }
            .joined(separator: "\n")

        for identifier in [
            "admin.secret", "history.chart", "rule.toggle", "action.destructive",
            "state.stale", "state.unavailable", "demo.badge", "connect.real-device",
        ] {
            XCTAssertTrue(text.contains(identifier), "missing \(identifier)")
        }
    }

    func testBothPlatformsNavigateEveryAdministrationSection() throws {
        for path in [
            "Wattline/RouterAdministration/RouterAdministrationView.swift",
            "WattlineMac/RouterAdministration/MacRouterAdministrationView.swift",
        ] {
            let text = try source(path)
            for label in [
                "History", "Client enrollment", "API clients", "Router Configuration",
                "Link-Power pairing", "Advanced device", "Automation Rules",
            ] {
                XCTAssertTrue(text.contains(label), "\(path) is missing \(label)")
            }
        }
    }

    func testAccessibilitySemanticsAreAttachedToConcreteControlsAndStates() throws {
        let settings = try source("../WattlineShared/RouterAdministration/RouterSettingsView.swift")
        assertSemanticBlock(
            settings,
            anchor: "Button(\"Confirm listener migration\", role: .destructive)",
            identifier: "action.destructive",
            label: "Confirm changing router listeners"
        )

        let advanced = try source("../WattlineShared/RouterAdministration/RouterAdvancedView.swift")
        assertSemanticBlock(
            advanced,
            anchor: "if let error = model.advancedError",
            identifier: "state.unavailable",
            label: "Advanced controls unavailable"
        )
        assertSemanticBlock(
            advanced,
            anchor: "Text(\"No advanced controls available.\")",
            identifier: "state.unavailable",
            label: "Advanced controls unavailable"
        )

        let rules = try source("../WattlineShared/RouterAdministration/RouterRulesView.swift")
        assertSemanticBlock(
            rules,
            anchor: "Text(\"No additional automation rules.\")",
            identifier: "state.unavailable",
            label: "No additional automation rules available"
        )
        assertSemanticBlock(
            rules,
            anchor: "if let message = model.rulesError",
            identifier: "state.unavailable",
            label: "Automation rules unavailable"
        )

        let tokens = try source("../WattlineShared/RouterAdministration/RouterTokensView.swift")
        assertSemanticBlock(
            tokens,
            anchor: "if model.tokens.isEmpty",
            identifier: "state.unavailable",
            label: "No API clients available"
        )
        assertSemanticBlock(
            tokens,
            anchor: "if let message = model.tokensError",
            identifier: "state.unavailable",
            label: "API clients unavailable"
        )
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: TestProjectFiles.url(relativePath), encoding: .utf8)
    }

    private func assertSemanticBlock(
        _ source: String,
        anchor: String,
        identifier: String,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let anchorRange = source.range(of: anchor) else {
            XCTFail("missing semantic anchor \(anchor)", file: file, line: line)
            return
        }
        let block = source[anchorRange.lowerBound...].prefix(600)
        XCTAssertTrue(block.contains(identifier), "\(anchor) is missing \(identifier)", file: file, line: line)
        XCTAssertTrue(block.contains(label), "\(anchor) is missing \(label)", file: file, line: line)
    }
}

private actor RecordingDemoCredentialBackend: RouterCredentialBackend {
    private var calls: [String] = []

    func read(account: String) async throws -> Data? {
        calls.append("read")
        return nil
    }

    func save(_ data: Data, account: String) async throws {
        calls.append("save")
    }

    func delete(account: String) async throws {
        calls.append("delete")
    }

    func recordedCalls() -> [String] { calls }
}

private final class RecordingDemoHostBackend: RouterHostKeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []

    func data(forKey key: String) -> Data? {
        lock.withLock { calls.append("read") }
        return nil
    }

    func set(_ data: Data, forKey key: String) throws {
        lock.withLock { calls.append("set") }
    }

    func removeValue(forKey key: String) throws {
        lock.withLock { calls.append("remove") }
    }

    func recordedCalls() -> [String] {
        lock.withLock { calls }
    }
}
