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
        // Collection and comparison are separate controls on purpose: hiding a device from
        // comparisons must never disconnect it. Both appear here, and only one of them is
        // about collecting, so the labels have to stay distinguishable.
        XCTAssertTrue(application.buttons["Hide from comparisons"].exists)
        application.buttons["Pause collecting"].tap()
        XCTAssertTrue(row.label.contains("Paused"))

        // Remove proposes; only the dialog's own button deletes. This fixture stores no
        // readings, so the button says so rather than claiming to delete history.
        row.swipeLeft()
        application.buttons["Remove"].tap()
        let confirm = application.buttons["Remove device"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertFalse(row.waitForExistence(timeout: 1))
    }

    /// Reads a combined element's spoken text, whichever of label and value carries it.
    private func spokenText(_ candidate: XCUIElement) -> String {
        "\(candidate.label) \((candidate.value as? String) ?? "")"
    }

    func testRemovalAsksFirstAndDeletesOnlyThatDevice() {
        let application = launch("removal")
        application.buttons["Settings"].tap()
        let stored = element("data.storedReadings", in: application)
        XCTAssertTrue(scrollToElement(stored, in: application))
        XCTAssertTrue(spokenText(stored).contains("24"))

        application.buttons["Devices"].tap()
        let strap = application.otherElements["source.22222222-2222-2222-2222-222222222222"]
        let finger = application.otherElements["source.33333333-3333-3333-3333-333333333333"]
        XCTAssertTrue(strap.waitForExistence(timeout: 3))
        XCTAssertTrue(finger.exists)

        // A drag across the whole row reveals the actions but must not perform one.
        let confirm = application.buttons["Remove and delete readings"]
        strap.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: strap.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)))
        XCTAssertTrue(strap.exists)
        XCTAssertFalse(confirm.exists)

        // Remove proposes, and the dialog states the consequence in numbers.
        if !application.buttons["Remove"].exists { strap.swipeLeft() }
        application.buttons["Remove"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        XCTAssertTrue(application.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "12 readings"
        )).firstMatch.exists)

        // Cancel leaves the device and every stored reading in place.
        application.buttons["Cancel"].tap()
        XCTAssertTrue(strap.waitForExistence(timeout: 2))
        application.buttons["Settings"].tap()
        XCTAssertTrue(scrollToElement(stored, in: application))
        XCTAssertTrue(spokenText(stored).contains("24"))

        // Confirming removes exactly that device's twelve readings and nothing else.
        application.buttons["Devices"].tap()
        XCTAssertTrue(strap.waitForExistence(timeout: 3))
        strap.swipeLeft()
        application.buttons["Remove"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertFalse(strap.waitForExistence(timeout: 2))
        XCTAssertTrue(finger.exists)
        application.buttons["Settings"].tap()
        XCTAssertTrue(scrollToElement(stored, in: application))
        XCTAssertTrue(spokenText(stored).contains("12"))
        XCTAssertFalse(spokenText(stored).contains("24"))
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

    private func launchPairwiseDemo() -> XCUIApplication {
        let application = XCUIApplication()
        application.launchArguments = ["--pairwise-demo"]
        application.launch()
        return application
    }

    private func anyElement(containing text: String, in application: XCUIApplication) -> XCUIElement {
        application.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func openHeartRate(in application: XCUIApplication) {
        let heartRate = application.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Heart Rate"
        )).firstMatch
        XCTAssertTrue(heartRate.waitForExistence(timeout: 5))
        heartRate.tap()
    }

    func testMetricDetailKeepsTheChosenRangeAfterBack() {
        let application = launchPairwiseDemo()
        application.buttons["Compare"].tap()
        openHeartRate(in: application)

        let detailRange = element("metric.range", in: application)
        XCTAssertTrue(detailRange.waitForExistence(timeout: 5))
        detailRange.buttons["7D"].tap()
        XCTAssertTrue(detailRange.buttons["7D"].isSelected)

        // The pair opens at the range chosen on detail…
        let pair = element("metric.pair", in: application)
        XCTAssertTrue(scrollToElement(pair, in: application))
        pair.tap()
        let pairRange = element("pairwise.range", in: application)
        XCTAssertTrue(pairRange.waitForExistence(timeout: 5))
        XCTAssertTrue(pairRange.buttons["7D"].isSelected)

        // …and Back no longer resets detail to the range it was first opened with.
        application.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(detailRange.waitForExistence(timeout: 5))
        XCTAssertTrue(detailRange.buttons["7D"].isSelected)
        XCTAssertFalse(detailRange.buttons["24H"].isSelected)
    }

    func testSavedSessionPeriodReachesDetailAndPair() {
        let application = launchPairwiseDemo()
        application.buttons["Compare"].tap()
        let sessions = element("compare.sessions", in: application)
        XCTAssertTrue(sessions.waitForExistence(timeout: 5))
        sessions.tap()
        application.buttons["Saved sessions\u{2026}"].tap()
        let demoWalk = application.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Demo walk")).firstMatch
        XCTAssertTrue(demoWalk.waitForExistence(timeout: 5))
        demoWalk.tap()
        XCTAssertTrue(element("compare.session", in: application).waitForExistence(timeout: 5))

        // Detail shows the session, not a rolling picker that would imply the last 24 hours.
        openHeartRate(in: application)
        XCTAssertTrue(element("metric.session", in: application).waitForExistence(timeout: 5))
        XCTAssertFalse(element("metric.range", in: application).exists)

        let pair = element("metric.pair", in: application)
        XCTAssertTrue(scrollToElement(pair, in: application))
        pair.tap()
        XCTAssertTrue(element("pairwise.session", in: application).waitForExistence(timeout: 5))
        XCTAssertFalse(element("pairwise.range", in: application).exists)
        // Five of the fixture's eight paired minutes fall inside the session; the rolling
        // range would report all eight.
        XCTAssertTrue(anyElement(containing: "5 paired of 5", in: application).waitForExistence(timeout: 5))
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
