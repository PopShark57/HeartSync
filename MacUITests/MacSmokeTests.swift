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
        let destination = try Self.exportDestination()
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
        let saveResult = XCTWaiter.wait(for: [filesSaved], timeout: 10)
        if saveResult != .completed {
            // The whole screen, not just the app: a privacy alert from another process, a save
            // error in the sheet, or a panel still open each explain a missing file differently.
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "Export did not reach \(destination.path)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertEqual(saveResult, .completed)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "pairwise.export").firstMatch.waitForExistence(timeout: 5))
        // Save dismissed the export and its ordinary temporary-directory cleanup ran.
        // Both complete files must still exist in the selected destination afterwards.
        let saved = (try? FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)) ?? []
        XCTAssertEqual(Set(saved.map(\.pathExtension)), ["csv", "txt"])
        for file in saved { XCTAssertGreaterThan((try? Data(contentsOf: file).count) ?? 0, 0) }
    }

    /// A fresh folder for the save panel to move the export into.
    ///
    /// Not this runner's temporary directory when avoidable: that sits inside the runner's
    /// container, and since macOS 14 another app writing there raises "would like to access
    /// data from other apps", which nobody answers on CI. `/Users/Shared` belongs to no app
    /// (Apple DTS's suggestion for this XCUITest case); the temporary directory remains the
    /// fallback for a runner that cannot create a folder there.
    private static func exportDestination() throws -> URL {
        let name = "HeartSync-ExportSmoke-\(UUID().uuidString)"
        let shared = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        if (try? FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)) != nil {
            return shared
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        return temporary
    }

}
