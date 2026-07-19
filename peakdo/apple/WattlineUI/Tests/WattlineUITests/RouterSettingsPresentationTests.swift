import XCTest
@testable import WattlineUI

final class RouterSettingsPresentationTests: XCTestCase {
    func testUnchangedDraftProducesNoPatch() throws {
        let original = fixture()
        XCTAssertEqual(try RouterSettingsDraft(original).patch(from: original), .init())
    }

    func testNestedChangesAreSparseAndEmptyInterfacesAreExplicit() throws {
        let original = fixture()
        var draft = RouterSettingsDraft(original)
        draft.http.port = "9000"
        draft.mdns.interfaces = []
        let patch = try draft.patch(from: original)
        XCTAssertEqual(patch.http, .init(port: 9000))
        XCTAssertEqual(patch.mdns, .init(interfaces: []))
        XCTAssertNil(patch.https)
        XCTAssertNil(patch.tls)
    }

    func testBLEPINRequiresExactlySixASCIIDigitsAndPortsUseOneThrough65535() {
        for invalid in ["20555", "0205557", "02A555", "０２０５５５"] {
            var draft = RouterSettingsDraft(fixture())
            draft.blePIN = invalid
            XCTAssertThrowsError(try draft.patch(from: fixture()))
        }
        for invalid in ["0", "65536", "8.0", ""] {
            var draft = RouterSettingsDraft(fixture())
            draft.http.port = invalid
            XCTAssertThrowsError(try draft.patch(from: fixture()))
        }
    }

    func testZeroEnabledPostRestartListenersIsStructurallyInvalid() {
        let original = fixture()
        var draft = RouterSettingsDraft(original)
        draft.http.enabled = false
        draft.https.enabled = false
        let decision = RouterSettingsSavePolicy.evaluate(
            original: original,
            draft: draft,
            context: .init(currentScheme: "https", currentPort: 8378)
        )
        XCTAssertEqual(decision.blocker, .noEnabledListener)
        XCTAssertFalse(decision.canSave)
    }

    func testRemovingCurrentListenerRequiresValidatedCorrelatedReplacement() {
        let original = fixture()
        var draft = RouterSettingsDraft(original)
        draft.https.enabled = false
        let missing = RouterSettingsSavePolicy.evaluate(
            original: original,
            draft: draft,
            context: .init(currentScheme: "https", currentPort: 8378)
        )
        XCTAssertEqual(missing.blocker, .validatedReplacementRequired)

        let wrongDevice = RouterReplacementCandidate(
            scheme: "http",
            host: "router.local",
            port: 8377,
            validation: .verified(deviceID: "AA:BB:CC:DD:EE:FF")
        )
        XCTAssertFalse(RouterSettingsSavePolicy.evaluate(
            original: original,
            draft: draft,
            context: .init(
                currentScheme: "https",
                currentPort: 8378,
                expectedDeviceID: "DC:04:5A:EB:72:2B",
                replacement: wrongDevice
            )
        ).canSave)

        let matching = RouterReplacementCandidate(
            scheme: "http",
            host: "router.local",
            port: 8377,
            validation: .verified(deviceID: "dc045aeb722b")
        )
        let valid = RouterSettingsSavePolicy.evaluate(
            original: original,
            draft: draft,
            context: .init(
                currentScheme: "https",
                currentPort: 8378,
                expectedDeviceID: "DC:04:5A:EB:72:2B",
                replacement: matching,
                confirmations: [.listenerMigration]
            )
        )
        XCTAssertTrue(valid.canSave)
    }

    func testRiskyChangesRequirePurposeSpecificConfirmations() {
        var insecure = RouterSettingsDraft(fixture())
        insecure.wanAccess = true
        let decision = RouterSettingsSavePolicy.evaluate(
            original: fixture(),
            draft: insecure,
            context: .init(currentScheme: "https", currentPort: 8378)
        )
        XCTAssertEqual(decision.requiredConfirmations, [.insecureWANHTTP])

        var listener = RouterSettingsDraft(fixture())
        listener.http.port = "9000"
        XCTAssertEqual(RouterSettingsSavePolicy.evaluate(
            original: fixture(),
            draft: listener,
            context: .init(currentScheme: "https", currentPort: 8378)
        ).requiredConfirmations, [.listenerMigration])

        var store = RouterSettingsDraft(fixture())
        store.tokenStore = "/mnt/new/tokens.json"
        XCTAssertEqual(RouterSettingsSavePolicy.evaluate(
            original: fixture(),
            draft: store,
            context: .init(currentScheme: "https", currentPort: 8378)
        ).requiredConfirmations, [.tokenStoreCutover])
    }

    func testRestartAndTokenStoreCopyIsHonest() {
        XCTAssertEqual(
            RouterSettingsCopy.restartRequired,
            "wattlined or the router must restart before these changes take effect."
        )
        XCTAssertTrue(RouterSettingsCopy.tokenStoreCutover.contains(
            "closes existing managed live-update streams"
        ))
        XCTAssertFalse(RouterSettingsCopy.restartRequired.contains("Link-Power"))
    }
}

private func fixture() -> RouterSettingsValue {
    RouterSettingsValue(
        http: .init(enabled: true, addr4: "0.0.0.0", addr6: "::", port: 8377),
        https: .init(enabled: true, addr4: "0.0.0.0", addr6: "::", port: 8378),
        tls: .init(cert: "/etc/wattline/tls.crt", key: "/etc/wattline/tls.key", sha256: "ABCD"),
        tokenStore: "/var/lib/wattline/tokens.json",
        pairingTTL: "5m",
        pairingAlwaysOn: false,
        advanced: false,
        mdns: .init(enabled: true, interfaces: ["br-lan"]),
        wanAccess: false,
        blePIN: "020555"
    )
}
