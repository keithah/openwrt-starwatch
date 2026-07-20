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
            validation: .verified(deviceID: "AA:BB:CC:DD:EE:FF"),
            validatedPatch: try! draft.patch(from: original)
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
            validation: .verified(deviceID: "dc045aeb722b"),
            validatedPatch: try! draft.patch(from: original)
        )
        let patch = try! draft.patch(from: original)
        let valid = RouterSettingsSavePolicy.evaluate(
            original: original,
            draft: draft,
            context: .init(
                currentScheme: "https",
                currentPort: 8378,
                expectedDeviceID: "DC:04:5A:EB:72:2B",
                replacement: matching,
                confirmationApproval: .init(
                    patch: patch,
                    confirmations: [.listenerMigration]
                )
            )
        )
        XCTAssertTrue(valid.canSave)
    }

    func testVerifiedReplacementMustSurviveAtItsExactPostEditPort() {
        let original = fixture()
        var draft = RouterSettingsDraft(original)
        draft.https.enabled = false
        draft.http.port = "9000"
        let candidate = RouterReplacementCandidate(
            scheme: "http",
            host: "router.local",
            port: 8377,
            validation: .verified(deviceID: "DC:04:5A:EB:72:2B"),
            validatedPatch: try! draft.patch(from: original)
        )

        let decision = RouterSettingsSavePolicy.evaluate(
            original: original,
            draft: draft,
            context: .init(
                currentScheme: "https",
                currentPort: 8378,
                expectedDeviceID: "DC:04:5A:EB:72:2B",
                replacement: candidate,
                confirmationApproval: .init(
                    patch: try! draft.patch(from: original),
                    confirmations: [.listenerMigration]
                )
            )
        )

        XCTAssertEqual(decision.blocker, .validatedReplacementRequired)
        XCTAssertFalse(decision.canSave)
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

        var pin = RouterSettingsDraft(fixture())
        pin.blePIN = "123456"
        XCTAssertEqual(RouterSettingsSavePolicy.evaluate(
            original: fixture(),
            draft: pin,
            context: .init(currentScheme: "https", currentPort: 8378)
        ).requiredConfirmations, [.blePINChange])
    }

    func testConfirmationApprovalIsBoundToExactPatchAndCannotBeReusedAfterEdit() throws {
        let original = fixture()
        var firstDraft = RouterSettingsDraft(original)
        firstDraft.blePIN = "123456"
        let firstPatch = try firstDraft.patch(from: original)
        let approval = RouterSettingsConfirmationApproval(
            patch: firstPatch,
            confirmations: [.blePINChange]
        )
        XCTAssertTrue(RouterSettingsSavePolicy.evaluate(
            original: original,
            draft: firstDraft,
            context: .init(
                currentScheme: "https",
                currentPort: 8378,
                confirmationApproval: approval
            )
        ).canSave)

        var editedDraft = firstDraft
        editedDraft.blePIN = "654321"
        let edited = RouterSettingsSavePolicy.evaluate(
            original: original,
            draft: editedDraft,
            context: .init(
                currentScheme: "https",
                currentPort: 8378,
                confirmationApproval: approval
            )
        )
        XCTAssertEqual(edited.requiredConfirmations, [.blePINChange])
        XCTAssertFalse(edited.canSave)
    }

    func testBindAddressChangeRequiresDifferentSchemeSavedCredentialedRoute() throws {
        let original = fixture()
        var draft = RouterSettingsDraft(original)
        draft.https.addr4 = "127.0.0.1"
        let patch = try draft.patch(from: original)
        let sameScheme = verifiedCandidate(
            scheme: "https",
            host: "alternate.local",
            port: 8378,
            pin: String(repeating: "ab", count: 32),
            patch: patch
        )
        XCTAssertEqual(RouterSettingsSavePolicy.evaluate(
            original: original,
            draft: draft,
            context: .init(
                currentScheme: "https",
                currentHost: "router.local",
                currentPort: 8378,
                expectedDeviceID: deviceID,
                replacement: sameScheme
            )
        ).blocker, .validatedReplacementRequired)

        let http = verifiedCandidate(
            scheme: "http",
            host: "192.0.2.10",
            port: 8377,
            patch: patch
        )
        let decision = RouterSettingsSavePolicy.evaluate(
            original: original,
            draft: draft,
            context: .init(
                currentScheme: "https",
                currentHost: "router.local",
                currentPort: 8378,
                expectedDeviceID: deviceID,
                replacement: http,
                confirmationApproval: .init(
                    patch: patch,
                    confirmations: [.listenerMigration]
                )
            )
        )
        XCTAssertTrue(decision.requiresValidatedReplacement)
        XCTAssertTrue(decision.canSave)
    }

    func testWANMDNSAndTLSChangesRequireIndependentlyReachableSavedReplacement() throws {
        let original = fixture()

        var wanDraft = RouterSettingsDraft(original)
        wanDraft.wanAccess = false
        let wanOriginal = RouterSettingsValue(
            http: original.http,
            https: original.https,
            tls: original.tls,
            tokenStore: original.tokenStore,
            pairingTTL: original.pairingTTL,
            pairingAlwaysOn: original.pairingAlwaysOn,
            advanced: original.advanced,
            mdns: original.mdns,
            wanAccess: true,
            blePIN: original.blePIN
        )
        XCTAssertEqual(RouterSettingsSavePolicy.evaluate(
            original: wanOriginal,
            draft: wanDraft,
            context: .init(
                currentScheme: "https",
                currentHost: "router.example.com",
                currentPort: 8378,
                currentReachability: .wan
            )
        ).blocker, .validatedReplacementRequired)

        var mdnsDraft = RouterSettingsDraft(original)
        mdnsDraft.mdns.interfaces = ["eth0"]
        XCTAssertEqual(RouterSettingsSavePolicy.evaluate(
            original: original,
            draft: mdnsDraft,
            context: .init(
                currentScheme: "https",
                currentHost: "router.local",
                currentPort: 8378
            )
        ).blocker, .validatedReplacementRequired)

        let tlsMutations: [(inout RouterSettingsDraft) -> Void] = [
            { (draft: inout RouterSettingsDraft) in draft.tls.cert = "/new.crt" },
            { (draft: inout RouterSettingsDraft) in draft.tls.key = "/new.key" },
        ]
        for mutateTLS in tlsMutations {
            var tlsDraft = RouterSettingsDraft(original)
            mutateTLS(&tlsDraft)
            let patch = try tlsDraft.patch(from: original)
            let pinnedHTTPS = verifiedCandidate(
                scheme: "https",
                host: "alternate.example.com",
                port: 8378,
                pin: String(repeating: "ab", count: 32),
                patch: patch
            )
            XCTAssertEqual(RouterSettingsSavePolicy.evaluate(
                original: original,
                draft: tlsDraft,
                context: .init(
                    currentScheme: "https",
                    currentHost: "router.local",
                    currentPort: 8378,
                    expectedDeviceID: deviceID,
                    replacement: pinnedHTTPS
                )
            ).blocker, .validatedReplacementRequired)
        }
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

    func testEveryBLEPINContainingPresentationTypeRedactsDescriptionsAndReflection() throws {
        let value = fixture()
        let draft = RouterSettingsDraft(value)
        var changedDraft = draft
        changedDraft.blePIN = "123456"
        let patch = try changedDraft.patch(from: value)

        assertDoesNotExposeBLEPIN(value, secrets: ["020555"])
        assertDoesNotExposeBLEPIN(draft, secrets: ["020555"])
        assertDoesNotExposeBLEPIN(patch, secrets: ["123456"])
        let approval = RouterSettingsConfirmationApproval(
            patch: patch,
            confirmations: [.blePINChange]
        )
        let replacement = verifiedCandidate(
            scheme: "http",
            host: "router.example.com",
            port: 8377,
            patch: patch
        )
        let context = RouterSettingsSaveContext(
            currentScheme: "https",
            currentPort: 8378,
            replacement: replacement,
            confirmationApproval: approval
        )
        let decision = RouterSettingsSavePolicy.evaluate(
            original: value,
            draft: changedDraft,
            context: context
        )
        for container in [
            AnyRedactionValue(approval),
            AnyRedactionValue(replacement),
            AnyRedactionValue(context),
            AnyRedactionValue(decision),
        ] {
            assertDoesNotExposeBLEPIN(container.value, secrets: ["123456"])
        }
    }

    private func assertDoesNotExposeBLEPIN<T>(_ value: T, secrets: [String]) {
        var dumped = ""
        dump(value, to: &dumped)
        let mirrorText = recursiveMirrorText(value)
        for secret in secrets {
            XCTAssertFalse(String(describing: value).contains(secret))
            XCTAssertFalse(String(reflecting: value).contains(secret))
            XCTAssertFalse(dumped.contains(secret))
            XCTAssertFalse(mirrorText.contains(secret))
        }
    }

    private func recursiveMirrorText(_ value: Any) -> String {
        let mirror = Mirror(reflecting: value)
        return mirror.children.map { child in
            String(describing: child.value) + recursiveMirrorText(child.value)
        }.joined(separator: " ")
    }
}

private struct AnyRedactionValue {
    let value: Any
    init(_ value: Any) { self.value = value }
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

private let deviceID = "DC:04:5A:EB:72:2B"

private func verifiedCandidate(
    scheme: String,
    host: String,
    port: Int,
    pin: String? = nil,
    patch: RouterSettingsDraftPatch
) -> RouterReplacementCandidate {
    RouterReplacementCandidate(
        scheme: scheme,
        host: host,
        port: port,
        certificateFingerprint: pin,
        reachability: .lan,
        isSaved: true,
        hasClientCredential: true,
        validation: .verified(deviceID: deviceID),
        validatedPatch: patch
    )
}
