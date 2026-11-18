import XCTest

final class StoreShotsUITests: XCTestCase {
    private let languages = [("zh-Hans", "zh_CN"), ("en", "en_US"), ("zh-Hant", "zh_TW")]
    private let pages = [
        ("1-viewfinder", "", "finder-status"),
        ("2-albums", "-shot-library", "library-timeline"),
        ("3-comparison", "-shot-detail", "share-comparison"),
        ("4-share", "-shot-share", "share-card"),
        ("5-timeline", "-shot-timeline", "timeline"),
        ("6-paywall", "-paywall", "paywall-title")
    ]

    func testStoreScreenshots() throws {
        for (language, locale) in languages {
            for (name, flag, marker) in pages {
                let app = XCUIApplication()
                app.launchArguments = ["-demo-album", "-AppleLanguages", "(" + language + ")", "-AppleLocale", locale]
                if !flag.isEmpty { app.launchArguments.append(flag) }
                app.launch()
                let element = app.descendants(matching: .any).matching(identifier: marker).firstMatch
                XCTAssertTrue(element.waitForExistence(timeout: 8), "Missing state \(name), \(language)")
                try save(app.screenshot(), name: "store-\(language)-\(name)")
                app.terminate()
            }
        }
    }

    private func save(_ screenshot: XCUIScreenshot, name: String) throws {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let path = ProcessInfo.processInfo.environment["SHOTS_DIR"] ?? ProcessInfo.processInfo.environment["TEST_RUNNER_SHOTS_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try screenshot.pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        }
    }
}
