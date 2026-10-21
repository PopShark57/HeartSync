import XCTest

@MainActor
final class MacSmokeTests: XCTestCase {
    func testFirstRunAndKeyboardNavigation() {
        let app = XCUIApplication()
        app.launchArguments = ["--mirror-empty"]
        app.launch()
        let pair = app.buttons["mac.now.pair"]
        XCTAssertTrue(pair.waitForExistence(timeout: 10))
        app.activate()
        pair.click()
        XCTAssertTrue(app.buttons["Pair with iPhone…"].waitForExistence(timeout: 5))
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(pair.waitForExistence(timeout: 5))
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Devices"].firstMatch.waitForExistence(timeout: 5))
    }

    func testUnavailableStorage() {
        let app = XCUIApplication()
        app.launchArguments = ["--mirror-unavailable"]
        app.launch()
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Mirrored history unavailable"].exists)
    }

    func testGalleryNavigation() {
        let app = XCUIApplication()
        app.launchArguments = ["--mirror-demo"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Now"].firstMatch.waitForExistence(timeout: 10))
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Compare"].firstMatch.waitForExistence(timeout: 5))
        app.typeKey("4", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Pair with iPhone…"].waitForExistence(timeout: 5))
    }

    /// The export sheet and its native destination panel. The panel is drawn by the system's
    /// open/save service, outside HeartSync's accessibility tree. On CI, keys sent to HeartSync
    /// (a go-to-folder path, Return, Escape) never reached it, and XCUIApplication for the
    /// service either found no buttons in it or raised an exception, so the test neither saves
    /// through the panel nor cancels it. It checks what HeartSync shows: the sheet's Cancel,
    /// and Save presenting the panel (the sheet's actions wait while it is open). The next
    /// launch terminates the app with the panel still open. The saved files' contents are
    /// covered by the export unit tests.
    func testExportSheetCancelAndDestinationPanel() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mirror-demo"]
        app.launch()
        app.typeKey("2", modifierFlags: .command)
        let metric = app.descendants(matching: .any).matching(identifier: "compare.metric.heartRate").firstMatch
        XCTAssertTrue(metric.waitForExistence(timeout: 10))
        app.activate()
        metric.click()
        let pair = app.descendants(matching: .any).matching(identifier: "metric.pair").firstMatch
        XCTAssertTrue(pair.waitForExistence(timeout: 10))
        app.activate()
        pair.click()
        // The export button, and with it the shortcut, exists only once the pair analysis has
        // loaded its observations; a shortcut typed before then does nothing.
        let export = app.descendants(matching: .any).matching(identifier: "pairwise.export").firstMatch
        XCTAssertTrue(export.waitForExistence(timeout: 10))
        app.typeKey("e", modifierFlags: [.command, .shift])
        let sheet = app.sheets.firstMatch
        let save = sheet.buttons["Save…"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))

        app.activate()
        sheet.buttons["Cancel"].click()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed, "Cancel closes the export sheet")
        XCTAssertTrue(export.waitForExistence(timeout: 5))

        app.typeKey("e", modifierFlags: [.command, .shift])
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertTrue(save.isEnabled)
        app.activate()
        save.click()
        XCTAssertTrue(waitUntil(save, isEnabled: false, timeout: 10), "Save… presents the destination panel")
    }

    private func waitUntil(_ element: XCUIElement, isEnabled: Bool, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "isEnabled == %@", NSNumber(value: isEnabled))
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

}
