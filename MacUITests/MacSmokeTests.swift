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
    /// open/save service, outside HeartSync's accessibility tree, and keystrokes synthesized
    /// for HeartSync did not complete it on CI, so the test does not save through it. It checks
    /// what HeartSync shows: its buttons wait while the panel is open, and the sheet survives
    /// the panel's cancellation. The saved files' contents are covered by the export unit tests.
    func testExportSavePanelAndCancel() throws {
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
        XCTAssertTrue(save.isEnabled)
        app.activate()
        save.click()
        XCTAssertTrue(waitUntil(save, isEnabled: false, timeout: 10), "Save… presents the destination panel")

        app.typeKey(.escape, modifierFlags: [])
        if !waitUntil(save, isEnabled: true, timeout: 5) {
            // Escape reaches the panel only if HeartSync forwards it; otherwise click the
            // panel's Cancel in the service that draws it, when XCTest can see that process.
            let panel = XCUIApplication(bundleIdentifier: "com.apple.appkit.xpc.openAndSavePanelService")
            print("Destination panel still open after Escape; panel service state \(panel.state.rawValue)")
            if panel.state != .notRunning && panel.state != .unknown {
                let cancel = panel.buttons["Cancel"].firstMatch
                if cancel.waitForExistence(timeout: 5) { cancel.click() }
            }
        }
        if !waitUntil(save, isEnabled: true, timeout: 5) {
            // In the job log, readable without downloading the result bundle.
            print("Destination panel did not close. Accessibility hierarchy:\n\(app.debugDescription)")
            XCTFail("Cancelling the destination panel returns to the export sheet")
            return
        }
        XCTAssertTrue(save.exists, "Cancelling the destination panel keeps the export sheet open")

        sheet.buttons["Cancel"].click()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed, "Cancel closes the export sheet")
        XCTAssertTrue(export.waitForExistence(timeout: 5))
    }

    private func waitUntil(_ element: XCUIElement, isEnabled: Bool, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "isEnabled == %@", NSNumber(value: isEnabled))
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

}
