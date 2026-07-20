import XCTest
@testable import WattlineUI

final class RouterRulesPresentationTests: XCTestCase {
    func testHumanDurationConvertsTenMinutesWithoutRounding() throws {
        let draft = RouterRuleDurationDraft(value: "10", unit: .minutes)

        XCTAssertEqual(try draft.nanoseconds(), 600_000_000_000)
        XCTAssertEqual(
            RouterRuleDurationDraft(nanoseconds: 600_000_000_000),
            draft
        )
    }

    func testHumanDurationRejectsOverflowAndSubNanosecondRounding() {
        XCTAssertThrowsError(
            try RouterRuleDurationDraft(
                value: String(Int64.max),
                unit: .hours
            ).nanoseconds()
        )
        XCTAssertThrowsError(
            try RouterRuleDurationDraft(
                value: "0.0000000001",
                unit: .seconds
            ).nanoseconds()
        )
    }

    func testUnknownRuleIsStructurallyReadOnlyAndShowsCanonicalJSON() {
        let value = RouterRulePresentationValue(
            name: "future",
            summary: #"{"future":true}"#,
            isKnown: false,
            hasWebhook: false,
            hasShutdown: false
        )

        let row = RouterRulesPresentation.row(for: value, adminVerified: true)

        XCTAssertTrue(row.isReadOnly)
        XCTAssertFalse(row.showsEditAction)
        XCTAssertEqual(row.jsonSummary, #"{"future":true}"#)
    }

    func testWebhookCopyNamesRouterAsOutboundRequesterAndRequiresAdmin() {
        XCTAssertEqual(
            RouterRulesPresentation.webhookWarning,
            "The router—not the Wattline app—makes this outbound request."
        )
        XCTAssertFalse(
            RouterRulesPresentation.canSave(hasWebhook: true, adminVerified: false)
        )
        XCTAssertTrue(
            RouterRulesPresentation.canSave(hasWebhook: true, adminVerified: true)
        )
    }

    func testShutdownAndResetRequireDistinctDestructiveConfirmations() {
        XCTAssertEqual(
            RouterRulesPresentation.confirmation(hasShutdown: true, resetsPreset: false),
            .shutdown
        )
        XCTAssertEqual(
            RouterRulesPresentation.confirmation(hasShutdown: true, resetsPreset: true),
            .resetPowerLossPreset
        )
    }

    func testPowerLossPresentationSeparatesCompatibleAndIncompatibleStates() {
        XCTAssertEqual(
            RouterPowerLossPresentation.compatible.editorMode,
            .editablePreservingFields
        )
        XCTAssertEqual(
            RouterPowerLossPresentation.incompatible.editorMode,
            .readOnlyUntilReset
        )
    }
}
