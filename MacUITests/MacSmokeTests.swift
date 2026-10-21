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
        let save = app.buttons["Save…"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        app.activate()
        save.click()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        app.activate()
        app.typeKey(.escape, modifierFlags: []) // Cancel the native destination picker.
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        // The runner is sandboxed, so it can read only its own container, and HeartSync
        // moving files into that container is a cross-app write that macOS 14 and later guard
        // with an "access data from other apps" prompt nobody answers on CI. So the files go
        // to /Users/Shared, which belongs to no app and which the panel grants as the user's
        // choice, and the outcome is read from HeartSync itself: the sheet closes only when
        // the move succeeded and stays open with its error otherwise. The files' contents are
        // covered by the export unit tests. Names carry a UTC timestamp, so runs never collide;
        // a local run leaves its two small files in /Users/Shared.
        app.activate()
        save.click()
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText("/Users/Shared")
        app.typeKey(.return, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: save)
        let saveResult = XCTWaiter.wait(for: [closed], timeout: 10)
        if saveResult != .completed {
            // The whole screen, not just the app: a privacy alert from another process, a save
            // error in the sheet, and a panel still open each mean something different.
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "Export sheet still open after saving to /Users/Shared"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            // Also in the job log, which can be read without downloading the result bundle:
            // whether the panel is still open, where it is, and any error the sheet shows.
            print("Export sheet still open. Accessibility hierarchy:\n\(app.debugDescription)")
        }
        XCTAssertEqual(saveResult, .completed, "The export sheet closes only after a successful move")
        XCTAssertTrue(export.waitForExistence(timeout: 5))
    }

}
