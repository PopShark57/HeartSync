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

    /// The opposite direction: a pushed screen keeps its list offset after Back, so a row
    /// near the top can be out of view — and out of the accessibility tree — until the
    /// list scrolls back up to it.
    private func scrollUpToElement(
        _ candidate: XCUIElement,
        in application: XCUIApplication,
        attempts: Int = 6
    ) -> Bool {
        for _ in 0..<attempts {
            if candidate.exists && candidate.isHittable { return true }
            application.swipeDown()
        }
        return candidate.exists && candidate.isHittable
    }

    private func waitForLabel(of candidate: XCUIElement, containing text: String, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", text),
            object: candidate
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Keeps a screenshot in the `.xcresult`, so a pull request's CI artefact shows what
    /// the UI looked like (improvement 41).
    private func attachScreenshot(_ name: String, of application: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: application.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A chart can be hittable while most of it is still behind the tab bar. Bring the
    /// whole plot into view before selecting and capturing it for visual review.
    private func revealChart(_ identifier: String, in application: XCUIApplication) -> XCUIElement {
        let chart = element(identifier, in: application)
        XCTAssertTrue(scrollToElement(chart, in: application, attempts: 10))
        if chart.frame.maxY > application.frame.maxY - 120 {
            application.swipeUp()
        }
        return chart
    }

    override func tearDown() {
        // A test that rotated the device must not leave the next one in landscape.
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private func waitForDisappearance(of candidate: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: candidate
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
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

        // …and Back no longer resets detail to the range it was first opened with. The list
        // keeps its offset below the picker, so scroll back up before reading it.
        application.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(scrollUpToElement(detailRange, in: application))
        XCTAssertTrue(detailRange.buttons["7D"].isSelected)
        XCTAssertFalse(detailRange.buttons["24H"].isSelected)
    }

    /// Improvements 32 and 33: zoom reloads at a finer bucket and says which, and a period
    /// taken from the chart gets its own evidence and a Save as session… action.
    func testMetricDetailZoomNamesItsBucketAndOffersAPeriod() {
        let application = launchPairwiseDemo()
        application.buttons["Compare"].tap()
        openHeartRate(in: application)

        let bucket = element("metric.bucket", in: application)
        XCTAssertTrue(bucket.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForLabel(of: bucket, containing: "Showing 15-minute medians"), bucket.label)

        let zoomIn = element("metric.zoomIn", in: application)
        XCTAssertTrue(zoomIn.exists)
        zoomIn.tap()
        XCTAssertTrue(waitForLabel(of: bucket, containing: "Showing 5-minute medians"), bucket.label)
        zoomIn.tap()
        XCTAssertTrue(waitForLabel(of: bucket, containing: "Showing 1-minute medians"), bucket.label)
        XCTAssertFalse(zoomIn.isEnabled)
        XCTAssertTrue(element("metric.panEarlier", in: application).exists)

        // The span shown becomes the selected period, with its own evidence.
        element("metric.selectPeriod", in: application).tap()
        let useSpan = element("metric.useVisibleSpan", in: application)
        XCTAssertTrue(useSpan.waitForExistence(timeout: 5))
        useSpan.tap()
        let save = element("metric.savePeriod", in: application)
        XCTAssertTrue(scrollToElement(save, in: application))
        save.tap()
        XCTAssertTrue(application.navigationBars["Save session"].waitForExistence(timeout: 5))
        application.buttons["Cancel"].tap()

        // Zooming back out ends at the whole range, drawn at its own bucket.
        let zoomOut = element("metric.zoomOut", in: application)
        XCTAssertTrue(scrollUpToElement(zoomOut, in: application))
        zoomOut.tap()
        zoomOut.tap()
        XCTAssertTrue(waitForLabel(of: bucket, containing: "Showing 15-minute medians"), bucket.label)
        XCTAssertFalse(zoomOut.isEnabled)
    }

    /// Improvement 34: the pair's selection steps window by window without a drag, shows
    /// its details, and clears.
    func testPairSelectionStepsWithoutADragAndClears() {
        let application = launchPairwiseDemo()
        application.buttons["Compare"].tap()
        openHeartRate(in: application)
        let pair = element("metric.pair", in: application)
        XCTAssertTrue(scrollToElement(pair, in: application))
        pair.tap()

        let next = element("pairwise.next", in: application)
        XCTAssertTrue(scrollToElement(next, in: application))
        next.tap()
        let clear = element("pairwise.clearSelection", in: application)
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        let selected = element("pairwise.selected", in: application)
        XCTAssertTrue(scrollToElement(selected, in: application))

        XCTAssertTrue(scrollUpToElement(clear, in: application))
        clear.tap()
        XCTAssertTrue(waitForDisappearance(of: selected))
    }

    /// Improvement 35: the Oura tab draws a timed hypnogram, a timed movement chart, a
    /// selectable heart-rate chart, and fourteen-day trends from cached documents only.
    func testOuraChartsDrawStagesMovementHeartRateAndTrends() {
        let application = launch("ouraCharts")
        application.buttons.matching(identifier: "Oura").firstMatch.tap()

        for (identifier, title) in [
            ("oura.heartRate", "Oura heart-rate selection"),
            ("oura.hypnogram", "Oura sleep selection"),
            ("oura.movement", "Oura movement selection"),
        ] {
            let chart = revealChart(identifier, in: application)
            chart.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).press(forDuration: 1)
            attachScreenshot(title, of: application)
        }
        // Reset the scroll position before the existing section-content checks.
        application.terminate()
        application.launch()
        application.buttons.matching(identifier: "Oura").firstMatch.tap()
        let heartRate = application.staticTexts["Drag across the chart to read a sample's time and heart rate."]
        XCTAssertTrue(scrollToElement(heartRate, in: application))
        let hypnogram = application.staticTexts["Oura's stage classification, not HeartSync's. Drag across the chart to read a stage and its times."]
        XCTAssertTrue(scrollToElement(hypnogram, in: application))
        let movement = application.staticTexts["Oura's activity classes, not HeartSync's. Drag across the chart to read a class and its times."]
        XCTAssertTrue(scrollToElement(movement, in: application))

        // The score cards carry their fortnight, spoken as one sentence.
        XCTAssertTrue(scrollUpToElement(anyElement(containing: "Last 14 days", in: application), in: application, attempts: 10))
        attachScreenshot("Oura charts", of: application)
    }

    /// Improvement 36: with sources but none connected, Now shows cards and trends and no
    /// Sources header, and nothing claims to be live.
    func testNowWithoutConnectedSourcesHidesTheSourcesHeader() {
        let application = launchPairwiseDemo()
        XCTAssertTrue(application.buttons["Now"].waitForExistence(timeout: 5))
        application.buttons["Now"].tap()

        let trend = element("now.sparkline.heartRate", in: application)
        XCTAssertTrue(trend.waitForExistence(timeout: 5))
        XCTAssertTrue(trend.label.hasPrefix("Trend over the last hour."), trend.label)
        XCTAssertFalse(element("now.sources", in: application).exists)
        XCTAssertFalse(application.staticTexts["Live sources"].exists)
        XCTAssertFalse(anyElement(containing: ", live", in: application).exists)

        // The card's way into history meets the 44-point minimum.
        let history = application.buttons["History and agreement for Heart Rate"]
        XCTAssertTrue(history.exists)
        XCTAssertGreaterThanOrEqual(history.frame.height, 44)
        attachScreenshot("Now, no connected sources", of: application)
    }

    /// Improvement 41: screenshots of the main chart screens from a month of fixture data,
    /// in portrait and landscape. CI also runs this on an iPad simulator for the layouts
    /// of improvement 38.
    func testChartGalleryScreenshots() {
        let application = XCUIApplication()
        application.launchArguments = ["--chart-gallery"]
        application.launch()
        XCTAssertTrue(application.buttons.matching(identifier: "Now").firstMatch.waitForExistence(timeout: 10))
        application.buttons.matching(identifier: "Now").firstMatch.tap()
        XCTAssertTrue(element("now.sparkline.heartRate", in: application).waitForExistence(timeout: 10))
        attachScreenshot("Now", of: application)

        application.buttons.matching(identifier: "Compare").firstMatch.tap()
        openHeartRate(in: application)
        let range = element("metric.range", in: application)
        XCTAssertTrue(range.waitForExistence(timeout: 10))
        let chart = element("metric.chart", in: application)
        XCTAssertTrue(chart.waitForExistence(timeout: 10))
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
            .press(forDuration: 1, thenDragTo: chart.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)))
        let clear = element("metric.clearSelection", in: application)
        XCTAssertTrue(clear.waitForExistence(timeout: 5), "A scrub keeps its selection after the finger lifts")
        attachScreenshot("Heart rate, selected window", of: application)
        clear.tap()
        XCTAssertTrue(waitForDisappearance(of: clear))

        range.buttons["30D"].tap()
        XCTAssertTrue(chart.waitForExistence(timeout: 10))
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).press(forDuration: 1)
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        attachScreenshot("Metric detail, 30 days, selected window", of: application)

        let pair = element("metric.pair", in: application)
        XCTAssertTrue(scrollToElement(pair, in: application))
        pair.tap()
        XCTAssertTrue(element("pairwise.range", in: application).waitForExistence(timeout: 10))
        let next = element("pairwise.next", in: application)
        XCTAssertTrue(scrollToElement(next, in: application))
        // Starting from no selection picks the first window, exercising an edge callout.
        next.tap()
        XCTAssertTrue(element("pairwise.clearSelection", in: application).waitForExistence(timeout: 5))
        XCTAssertTrue(scrollUpToElement(element("pairwise.timeline", in: application), in: application))
        attachScreenshot("Pairwise timeline, selected window", of: application)
        _ = revealChart("pairwise.difference", in: application)
        attachScreenshot("Pairwise difference, selected window", of: application)

        XCUIDevice.shared.orientation = .landscapeLeft
        attachScreenshot("Pairwise, landscape", of: application)
        application.buttons.matching(identifier: "Now").firstMatch.tap()
        attachScreenshot("Now, landscape", of: application)

        // Sparse daily values exercise the other reported tooltip, including its
        // estimate and insufficient-comparison labels. Restart to reset navigation.
        XCUIDevice.shared.orientation = .portrait
        application.terminate()
        application.launch()
        application.buttons.matching(identifier: "Compare").firstMatch.tap()
        let compareRange = element("compare.range", in: application)
        XCTAssertTrue(compareRange.waitForExistence(timeout: 10))
        compareRange.buttons["7D"].tap()
        let vo2 = application.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "VO\u{2082} Max"
        )).firstMatch
        XCTAssertTrue(vo2.waitForExistence(timeout: 10))
        vo2.tap()
        let sparseChart = revealChart("metric.chart", in: application)
        sparseChart.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).press(forDuration: 1)
        XCTAssertTrue(element("metric.clearSelection", in: application).waitForExistence(timeout: 5))
        attachScreenshot("VO2 max, selected daily window", of: application)
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
