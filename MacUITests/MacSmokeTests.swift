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
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("HeartSync-ExportSmoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        app.activate()
        save.click()
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(destination.path)
        app.typeKey(.return, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        let filesSaved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil).count) == 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [filesSaved], timeout: 10), .completed)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "pairwise.export").firstMatch.waitForExistence(timeout: 5))
        // Save dismissed the export and its ordinary temporary-directory cleanup ran.
        // Both complete files must still exist in the selected destination afterwards.
        let saved = (try? FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)) ?? []
        XCTAssertEqual(Set(saved.map(\.pathExtension)), ["csv", "txt"])
        for file in saved { XCTAssertGreaterThan((try? Data(contentsOf: file).count) ?? 0, 0) }
    }

}
