import XCTest

@MainActor
final class HeartSyncCheckerUITests: XCTestCase {
    private func element(_ identifier: String, in application: XCUIApplication) -> XCUIElement {
        application.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func scrollToElement(
        _ candidate: XCUIElement,
        in application: XCUIApplication,
        attempts: Int = 6
    ) -> Bool {
        for _ in 0..<attempts {
            if candidate.exists && candidate.isHittable { return true }
            application.swipeUp()
        }
        return candidate.exists && candidate.isHittable
    }

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
        XCTAssertTrue(element("startup.loading", in: application).waitForExistence(timeout: 5))
        application.terminate()

        application = launch("startupUnavailable")
        XCTAssertTrue(element("startup.unavailable", in: application).waitForExistence(timeout: 5))
        XCTAssertTrue(application.buttons["startup.retry"].exists)
        XCTAssertTrue(application.staticTexts["Health history temporarily unavailable"].exists)
        application.buttons["startup.retry"].tap()
        XCTAssertTrue(application.buttons["Now"].waitForExistence(timeout: 5))
    }

    func testSourceArchiveFailureAndCorruptRecoveryAreDistinguishable() {
        var application = launch("sourcesUnavailable")
        XCTAssertTrue(element("startup.unavailable", in: application).waitForExistence(timeout: 5))
        XCTAssertTrue(application.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", "sources"
        )).firstMatch.exists)
        application.terminate()

        application = launch("corruptRecovery")
        XCTAssertTrue(element("startup.notice", in: application).waitForExistence(timeout: 5))
        XCTAssertTrue(application.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", "preserving unreadable health data"
        )).firstMatch.exists)
    }

    func testEmptyStateAndSettingsFailureRemainActionable() {
        var application = launch("empty")
        XCTAssertTrue(application.staticTexts["No devices yet"].waitForExistence(timeout: 5))
        application.terminate()

        application = launch("settingsUnavailable")
        XCTAssertTrue(element("startup.notice", in: application).waitForExistence(timeout: 5))
        XCTAssertTrue(application.buttons["settings.retry"].exists)
        application.buttons["Settings"].tap()
        XCTAssertTrue(element("settings.unavailable", in: application).waitForExistence(timeout: 5))
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
        let retentionPicker = application.buttons["Keep readings for, 30 days"]
        XCTAssertTrue(scrollToElement(retentionPicker, in: application))
        retentionPicker.tap()
        application.buttons["7 days"].tap()
        XCTAssertTrue(element("retention.confirmation", in: application).waitForExistence(timeout: 5))
        XCTAssertTrue(application.staticTexts["Readings deleted"].exists)
        XCTAssertTrue(application.buttons["retention.export"].exists)
        application.buttons["Cancel"].tap()
        XCTAssertFalse(element("retention.confirmation", in: application).exists)
    }

    func testComparisonEvidenceAndOuraPartialFailure() {
        let comparison = XCUIApplication()
        comparison.launchArguments = ["--pairwise-demo"]
        comparison.launch()
        comparison.buttons["Compare"].tap()
        let comparisonEvidence = element("compare.root", in: comparison)
        XCTAssertTrue(comparisonEvidence.waitForExistence(timeout: 5))
        comparison.terminate()

        let oura = launch("ouraPartial")
        oura.buttons["Oura"].tap()
        let endpointIssues = element("oura.endpointIssues", in: oura)
        XCTAssertTrue(scrollToElement(endpointIssues, in: oura))
        XCTAssertTrue(oura.staticTexts["Some data needs attention"].exists)
    }

    func testPseudoLocalizationKeepsAllPrimaryTabsReachable() {
        let application = launch("empty", pseudoLocalized: true)
        let tabTitles = ["Now", "Oura", "Compare", "Devices", "Settings"]
        for title in tabTitles {
            let button = application.buttons.matching(NSPredicate(
                format: "label CONTAINS[c] %@", title
            )).firstMatch
            XCTAssertTrue(button.exists)
            XCTAssertTrue(button.isHittable)
        }
    }
}
