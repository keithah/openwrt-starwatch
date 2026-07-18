import XCTest

@MainActor
final class WattlineSettingsUITests: XCTestCase {
    func testConfirmationRepresentationSelectionSupportsAlert() {
        XCTAssertEqual(
            ConfirmationStrategy.selectRepresentation(
                ConfirmationCandidateState(
                    alertHasDestructiveAction: true,
                    sheetHasDestructiveAction: false,
                    popoverDismissRegionIsHittable: false
                )
            ),
            .alert
        )
    }

    func testConfirmationRepresentationSelectionSupportsPlainSheet() {
        XCTAssertEqual(
            ConfirmationStrategy.selectRepresentation(
                ConfirmationCandidateState(
                    alertHasDestructiveAction: false,
                    sheetHasDestructiveAction: true,
                    popoverDismissRegionIsHittable: false
                )
            ),
            .sheet
        )
    }

    func testConfirmationRepresentationSelectionSupportsPopoverBackedSheet() {
        XCTAssertEqual(
            ConfirmationStrategy.selectRepresentation(
                ConfirmationCandidateState(
                    alertHasDestructiveAction: false,
                    sheetHasDestructiveAction: true,
                    popoverDismissRegionIsHittable: true
                )
            ),
            .popoverBackedSheet
        )
    }

    func testConfirmationRepresentationRequiresContainedDestructiveAction() {
        XCTAssertNil(
            ConfirmationStrategy.selectRepresentation(
                ConfirmationCandidateState(
                    alertHasDestructiveAction: false,
                    sheetHasDestructiveAction: false,
                    popoverDismissRegionIsHittable: true
                )
            )
        )
    }

    func testConfirmationCancellationPrefersExplicitCancel() {
        XCTAssertEqual(
            ConfirmationStrategy.selectCancellation(
                representation: .popoverBackedSheet,
                explicitCancelIsHittable: true,
                popoverDismissRegionIsHittable: true
            ),
            .explicitCancel
        )
    }

    func testConfirmationCancellationUsesDismissRegionOnlyForPopoverBackedSheet() {
        XCTAssertEqual(
            ConfirmationStrategy.selectCancellation(
                representation: .popoverBackedSheet,
                explicitCancelIsHittable: false,
                popoverDismissRegionIsHittable: true
            ),
            .popoverDismissRegion
        )
        XCTAssertNil(
            ConfirmationStrategy.selectCancellation(
                representation: .sheet,
                explicitCancelIsHittable: false,
                popoverDismissRegionIsHittable: true
            )
        )
    }

    func testSettingsExposesRestartAndShutdownWithoutTimers() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetOnboarding"]
        app.launch()
        app.buttons["Try Demo Mode"].tap()
        app.tabBars.buttons["Settings"].tap()

        XCTAssertTrue(app.buttons["Restart"].scrollToExistence(in: app))
        XCTAssertTrue(app.buttons["Shut Down"].scrollToExistence(in: app))
        XCTAssertFalse(app.tabBars.buttons["Timers"].exists)
    }

    func testShutdownRequiresConfirmationAndCancelLeavesSettingsVisible() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetOnboarding"]
        app.launch()
        app.buttons["Try Demo Mode"].tap()
        app.tabBars.buttons["Settings"].tap()

        let shutdown = app.buttons["Shut Down"]
        XCTAssertTrue(shutdown.scrollToExistence(in: app))
        shutdown.tap()

        guard let confirmation = app.waitForShutdownConfirmation() else {
            XCTFail("Expected an alert, sheet, or popover-backed sheet containing the Shut Down action")
            return
        }
        XCTAssertTrue(confirmation.destructiveAction.isHittable)

        guard confirmation.cancel(in: app) else {
            XCTFail("Expected a hittable Cancel button or popover dismiss region")
            return
        }
        XCTAssertTrue(confirmation.waitForDismissalKeepingSettingsVisible(in: app))
    }
}

private enum ConfirmationRepresentation: Equatable {
    case alert
    case sheet
    case popoverBackedSheet
}

private enum ConfirmationCancellation: Equatable {
    case explicitCancel
    case popoverDismissRegion
}

private struct ConfirmationCandidateState {
    let alertHasDestructiveAction: Bool
    let sheetHasDestructiveAction: Bool
    let popoverDismissRegionIsHittable: Bool
}

private enum ConfirmationStrategy {
    static func selectRepresentation(_ state: ConfirmationCandidateState) -> ConfirmationRepresentation? {
        if state.alertHasDestructiveAction {
            return .alert
        }
        guard state.sheetHasDestructiveAction else {
            return nil
        }
        return state.popoverDismissRegionIsHittable ? .popoverBackedSheet : .sheet
    }

    static func selectCancellation(
        representation: ConfirmationRepresentation,
        explicitCancelIsHittable: Bool,
        popoverDismissRegionIsHittable: Bool
    ) -> ConfirmationCancellation? {
        if explicitCancelIsHittable {
            return .explicitCancel
        }
        guard representation == .popoverBackedSheet, popoverDismissRegionIsHittable else {
            return nil
        }
        return .popoverDismissRegion
    }
}

private struct ConfirmationPresentation {
    let representation: ConfirmationRepresentation
    let container: XCUIElement
    let destructiveAction: XCUIElement

    func cancel(in app: XCUIApplication) -> Bool {
        let explicitCancel = container.buttons["Cancel"]
        let popoverDismissRegion = app.otherElements["dismiss popup"]
        let cancellation = ConfirmationStrategy.selectCancellation(
            representation: representation,
            explicitCancelIsHittable: explicitCancel.exists && explicitCancel.isHittable,
            popoverDismissRegionIsHittable: popoverDismissRegion.exists && popoverDismissRegion.isHittable
        )

        switch cancellation {
        case .explicitCancel:
            explicitCancel.tap()
        case .popoverDismissRegion:
            popoverDismissRegion.tap()
        case nil:
            return false
        }
        return true
    }

    func waitForDismissalKeepingSettingsVisible(
        in app: XCUIApplication,
        timeout: TimeInterval = 2
    ) -> Bool {
        let didDismiss = container.waitForNonExistence(timeout: timeout)
        let settingsNavigation = app.navigationBars["Settings"]
        let settingsIsVisible = settingsNavigation.exists || settingsNavigation.waitForExistence(timeout: timeout)
        return didDismiss && settingsIsVisible
    }
}

private extension XCUIApplication {
    func waitForShutdownConfirmation(
        maxAttempts: Int = 8,
        pollInterval: TimeInterval = 0.25
    ) -> ConfirmationPresentation? {
        let alert = alerts.firstMatch
        let sheet = sheets.firstMatch
        let popoverDismissRegion = otherElements["dismiss popup"]

        func currentPresentation() -> ConfirmationPresentation? {
            let alertAction = alert.buttons["Shut Down"]
            let sheetAction = sheet.buttons["Shut Down"]
            let representation = ConfirmationStrategy.selectRepresentation(
                ConfirmationCandidateState(
                    alertHasDestructiveAction: alert.exists && alertAction.exists,
                    sheetHasDestructiveAction: sheet.exists && sheetAction.exists,
                    popoverDismissRegionIsHittable: popoverDismissRegion.exists
                        && popoverDismissRegion.isHittable
                )
            )

            switch representation {
            case .alert:
                return ConfirmationPresentation(
                    representation: .alert,
                    container: alert,
                    destructiveAction: alertAction
                )
            case .sheet:
                return ConfirmationPresentation(
                    representation: .sheet,
                    container: sheet,
                    destructiveAction: sheetAction
                )
            case .popoverBackedSheet:
                return ConfirmationPresentation(
                    representation: .popoverBackedSheet,
                    container: sheet,
                    destructiveAction: sheetAction
                )
            case nil:
                return nil
            }
        }

        for _ in 0..<maxAttempts {
            if let presentation = currentPresentation() {
                return presentation
            }
            _ = alert.waitForExistence(timeout: pollInterval)
        }
        return currentPresentation()
    }
}

extension XCUIElement {
    func scrollToExistence(in app: XCUIApplication, maxSwipes: Int = 8) -> Bool {
        if exists && isHittable { return true }
        for _ in 0..<maxSwipes {
            app.swipeUp()
            if exists && isHittable { return true }
        }
        return false
    }
}
