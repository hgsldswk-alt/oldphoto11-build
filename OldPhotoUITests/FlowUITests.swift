import XCTest

final class FlowUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testOpenDirectlyToFinderThenScanAndEditFrames() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo-album", "-demo-empty", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let shutter = app.buttons["finder-shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 8))
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: shutter)
        waitForExpectations(timeout: 6)
        shutter.tap()
        let tray = app.buttons["finder-library"]
        XCTAssertTrue(tray.exists)
        let status = app.staticTexts["finder-status"]
        let pattern = NSPredicate(format: "label == %@", "4 photos scanned")
        expectation(for: pattern, evaluatedWith: status)
        waitForExpectations(timeout: 12)
        tray.tap()
        let album = app.buttons["album-row"].firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 5))
        album.tap()
        let tile = app.buttons["photo-tile"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        tile.tap()
        XCTAssertTrue(app.buttons["edit-frame"].waitForExistence(timeout: 5))
        app.buttons["edit-frame"].tap()
        XCTAssertTrue(app.buttons["crop-done"].waitForExistence(timeout: 5))
        app.buttons["crop-done"].tap()
        XCTAssertTrue(app.buttons["share-comparison"].exists)
    }

    func testSuggestedYearNeedsConfirmation() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo-album", "-shot-detail"]
        app.launch()
        let suggestion = app.buttons["confirm-year"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 9))
        suggestion.tap()
        XCTAssertTrue(app.buttons["edit-date"].waitForExistence(timeout: 4))
        XCTAssertFalse(suggestion.exists)
    }

    func testRemoveSceneTagAndNameFaceInPeople() {
        let app = launchDetail("-recognition-fixture")
        let tag = app.descendants(matching: .any)["scene-tag"].firstMatch
        let remove = app.buttons["remove-scene-tag"]
        reveal(remove, in: app)
        XCTAssertTrue(tag.exists)
        remove.tap()
        waitUntilGone(tag)

        let face = app.buttons["name-face"].firstMatch
        reveal(face, in: app)
        face.tap()
        let dialog = app.alerts.firstMatch
        let name = dialog.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Ada")
        dialog.buttons["Save"].tap()
        expectation(for: NSPredicate(format: "label == %@", "Ada"), evaluatedWith: face)
        waitForExpectations(timeout: 5)

        app.navigationBars.buttons.firstMatch.tap()
        let library = app.buttons["finder-library"]
        XCTAssertTrue(library.waitForExistence(timeout: 8))
        library.tap()
        let people = app.buttons["people-view"]
        XCTAssertTrue(people.waitForExistence(timeout: 8))
        people.tap()
        let group = app.staticTexts["person-group"].firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        XCTAssertEqual(group.label, "Ada")
        XCTAssertEqual(app.buttons.matching(identifier: "person-photo").count, 1)
    }

    func testMissingColorModelKeepsOriginalAndExportAvailable() {
        let app = launchDetail("-missing-color-model")
        let colorize = app.buttons["select-colorize"]
        reveal(colorize, in: app)
        colorize.tap()
        XCTAssertTrue(app.staticTexts["colorize-disclaimer"].exists)
        XCTAssertTrue(app.staticTexts["colorize-unavailable"].exists)
        XCTAssertFalse(app.buttons["apply-enhancement"].isEnabled)
        let original = app.buttons["toggle-original"]
        reveal(original, in: app, down: false)
        original.tap()
        app.buttons["detail-actions"].tap()
        XCTAssertTrue(app.buttons["export-full"].waitForExistence(timeout: 5))
    }

    func testColorFixtureComparisonAndUndo() throws {
        let app = launchDetail("-color-fixture")
        let colorize = app.buttons["select-colorize"]
        reveal(colorize, in: app)
        colorize.tap()
        if app.staticTexts["colorize-unavailable"].exists {
            throw XCTSkip("Install the Debug-only DDColorFixture model to run this flow")
        }
        let apply = app.buttons["apply-enhancement"]
        reveal(apply, in: app)
        apply.tap()
        let undo = app.buttons["undo-enhancement"]
        XCTAssertTrue(undo.waitForExistence(timeout: 30))
        let original = app.buttons["toggle-original"]
        reveal(original, in: app, down: false)
        let before = original.label
        original.tap()
        XCTAssertNotEqual(original.label, before)
        original.tap()
        reveal(undo, in: app)
        undo.tap()
        waitUntilGone(undo)
    }

    func testExpiredTrialStillExposesFullResolutionExport() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo-album", "-shot-detail", "-expired"]
        app.launch()
        let actions = app.buttons["detail-actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 9))
        XCTAssertFalse(app.sliders["strength"].exists)
        actions.tap()
        XCTAssertTrue(app.buttons["export-full"].waitForExistence(timeout: 4))
    }

    func testDeniedCameraOffersImportWithoutReads() {
        let app = XCUIApplication()
        app.launchArguments = ["-camera-denied"]
        app.launch()
        XCTAssertTrue(app.buttons["denied-import"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["finder-library"].exists)
    }

    private func launchDetail(_ fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo-album", "-shot-detail", fixture, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["detail-actions"].waitForExistence(timeout: 10))
        return app
    }

    private func reveal(_ target: XCUIElement, in app: XCUIApplication, down: Bool = true) {
        for _ in 0..<5 {
            if target.exists && target.isHittable { return }
            let scroll = app.scrollViews.firstMatch
            if down { scroll.swipeUp() } else { scroll.swipeDown() }
        }
        XCTAssertTrue(target.exists && target.isHittable)
    }

    private func waitUntilGone(_ element: XCUIElement) {
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        waitForExpectations(timeout: 5)
    }
}
