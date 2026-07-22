@testable import WattlineNetwork
import XCTest
@testable import Wattline

@MainActor
final class GoodCloudSettingsPresentationTests: XCTestCase {
    func testErrorPresentationUsesFixedCopyForExpiredAndGenericFailures() {
        XCTAssertEqual(
            GoodCloudSettingsPresentation(.requiresLogin).message,
            "Your GoodCloud session ended. Sign in again."
        )
        XCTAssertEqual(
            GoodCloudSettingsPresentation(.failed("server detail that must stay hidden")).message,
            "Remote access is unavailable. Please try again."
        )
    }

    func testLoginPresentationDisablesSubmitForEmptyFieldsOrLoading() {
        XCTAssertFalse(GoodCloudLoginPresentation(email: "owner@example.com", password: "secret", isLoading: false).isSubmitDisabled)
        XCTAssertTrue(GoodCloudLoginPresentation(email: "", password: "secret", isLoading: false).isSubmitDisabled)
        XCTAssertTrue(GoodCloudLoginPresentation(email: "owner@example.com", password: "", isLoading: false).isSubmitDisabled)
        XCTAssertTrue(GoodCloudLoginPresentation(email: "owner@example.com", password: "secret", isLoading: true).isSubmitDisabled)
    }

    func testLoginSubmissionSnapshotsTrimmedEmailAndUnmodifiedPassword() {
        let presentation = GoodCloudLoginPresentation(
            email: "  owner@example.com  ",
            password: " secret with spaces ",
            isLoading: false
        )

        XCTAssertEqual(
            presentation.credentialsForSubmission,
            .init(email: "owner@example.com", password: " secret with spaces ")
        )
    }

    func testCredentialBearingValuesRedactEveryReflectionSurface() {
        let secret = "secret-password"
        let presentation = GoodCloudLoginPresentation(
            email: "owner@example.com",
            password: secret,
            isLoading: false
        )
        let credentials = presentation.credentialsForSubmission

        for value in [
            String(describing: presentation),
            String(reflecting: presentation),
            presentation.debugDescription,
            String(describing: presentation.customMirror),
            String(describing: Mirror(reflecting: presentation).children.map(\.value)),
            String(describing: credentials),
            String(reflecting: credentials),
            credentials.debugDescription,
            String(describing: credentials.customMirror),
            String(describing: Mirror(reflecting: credentials).children.map(\.value)),
        ] {
            XCTAssertFalse(value.contains(secret), "reflection surface leaked the password: \(value)")
        }
    }

    func testDevicePresentationShowsMetadataSuggestionAndOfflineSelectionState() {
        let device = GoodCloudDeviceSummary(
            id: "42",
            name: "Wattline X3000",
            mac: "dc-04-5a-eb-72-2b",
            ddns: "wattline.glddns.com",
            model: "GL-X3000",
            isOnline: false
        )

        let presentation = GoodCloudDevicePresentation(device: device, isSuggested: true)

        XCTAssertEqual(presentation.name, "Wattline X3000")
        XCTAssertEqual(presentation.model, "GL-X3000")
        XCTAssertEqual(presentation.mac, "DC:04:5A:EB:72:2B")
        XCTAssertEqual(presentation.ddns, "wattline.glddns.com")
        XCTAssertEqual(presentation.status, "Offline")
        XCTAssertEqual(presentation.badge, "Suggested")
        XCTAssertFalse(presentation.isSelectable)
    }

    func testAssociationPresentationNeverIncludesAccountFailureDetail() {
        let presentation = GoodCloudSettingsPresentation(.failed("secret-password"))

        XCTAssertFalse(String(describing: presentation).contains("secret-password"))
        XCTAssertEqual(presentation.title, "GoodCloud unavailable")
    }
}
