import XCTest

@MainActor
final class HeartSyncCheckerUITests: XCTestCase {
    @discardableResult
    private func launch(_ scenario: String, pseudoLocalized: Bool = false) -> XCUIApplication {
        let application = XCUIApplication()
        application.launchArguments = ["--ui-test-\(scenario)"]
        if pseudoLocalized {
            application.launchArguments += ["-NSDoubleLocalizedStrings", "YES"]
        }
        application.launch()
        return application
    }

    func testStartupLoadingAndUnavailableRecoveryStates() {
        var application = launch("loading")
        XCTAssertTrue(application.otherElements["startup.loading"].waitForExistence(timeout: 3))
        application.terminate()

        application = launch("startupUnavailable")
        XCTAssertTrue(application.otherElements["startup.unavailable"].waitForExistence(timeout: 3))
        XCTAssertTrue(application.buttons["startup.retry"].exists)
        XCTAssertTrue(application.staticTexts["Health history temporarily unavailable"].exists)
        application.buttons["startup.retry"].tap()
        XCTAssertTrue(application.buttons["Now"].waitForExistence(timeout: 3))
    }

    func testSourceArchiveFailureAndCorruptRecoveryAreDistinguishable() {
        var application = launch("sourcesUnavailable")
        XCTAssertTrue(application.otherElements["startup.unavailable"].waitForExistence(timeout: 3))
        XCTAssertTrue(application.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", "sources"
        )).firstMatch.exists)
        application.terminate()

        application = launch("corruptRecovery")
        XCTAssertTrue(application.otherElements["startup.notice"].waitForExistence(timeout: 3))
        XCTAssertTrue(application.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", "preserving unreadable health data"
        )).firstMatch.exists)
    }

    func testEmptyStateAndSettingsFailureRemainActionable() {
        var application = launch("empty")
        XCTAssertTrue(application.staticTexts["Add your first device"].waitForExistence(timeout: 3))
        application.terminate()

        application = launch("settingsUnavailable")
        XCTAssertTrue(application.otherElements["startup.notice"].waitForExistence(timeout: 3))
        XCTAssertTrue(application.buttons["settings.retry"].exists)
        application.buttons["Settings"].tap()
        XCTAssertTrue(application.otherElements["settings.unavailable"].waitForExistence(timeout: 3))
    }

    func testSourcePauseAndDeleteActions() {
        let application = launch("devices")
        application.buttons["Devices"].tap()
        let row = application.otherElements["source.11111111-1111-1111-1111-111111111111"]
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        XCTAssertTrue(row.label.contains("wrist"))
        XCTAssertTrue(row.label.contains("Optical"))

        row.press(forDuration: 1)
        application.buttons["Pause"].tap()
        XCTAssertTrue(row.label.contains("Paused"))

        row.swipeLeft()
        application.buttons["Remove"].tap()
        XCTAssertFalse(row.waitForExistence(timeout: 1))
    }

    func testRetentionShorteningRequiresConfirmationAndCanCancel() {
        let application = launch("retention")
        application.buttons["Settings"].tap()
        application.buttons["Keep readings for, 30 days"].tap()
        application.buttons["7 days"].tap()
        XCTAssertTrue(application.otherElements["retention.confirmation"].waitForExistence(timeout: 3))
        XCTAssertTrue(application.staticTexts["Readings deleted"].exists)
        XCTAssertTrue(application.buttons["retention.export"].exists)
        application.buttons["Cancel"].tap()
        XCTAssertFalse(application.otherElements["retention.confirmation"].exists)
    }

    func testComparisonEvidenceAndOuraPartialFailure() {
        let comparison = XCUIApplication()
        comparison.launchArguments = ["--pairwise-demo"]
        comparison.launch()
        comparison.buttons["Compare"].tap()
        XCTAssertTrue(comparison.otherElements["compare.root"].waitForExistence(timeout: 3))
        XCTAssertTrue(comparison.staticTexts["Evidence overview"].exists)
        comparison.terminate()

        let oura = launch("ouraPartial")
        oura.buttons["Oura"].tap()
        XCTAssertTrue(oura.otherElements["oura.endpointIssues"].waitForExistence(timeout: 3))
        XCTAssertTrue(oura.staticTexts["Some data needs attention"].exists)
    }

    func testPseudoLocalizationKeepsAllPrimaryTabsReachable() {
        let application = launch("empty", pseudoLocalized: true)
        for tab in ["Now", "Oura", "Compare", "Devices", "Settings"] {
            let button = application.buttons[tab]
            XCTAssertTrue(button.exists)
            XCTAssertTrue(button.isHittable)
        }
    }
}
