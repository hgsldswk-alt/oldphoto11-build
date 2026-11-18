import CoreImage
import CryptoKit
import XCTest
@testable import OldPhoto

final class EnhancementTests: XCTestCase {
    func testChineseAndExplicitRepublicYears() {
        XCTAssertEqual(PhotoDate.parse("一九八七年 夏")?.year, 1987)
        XCTAssertEqual(PhotoDate.parse("二〇〇四年")?.year, 2004)
        XCTAssertEqual(PhotoDate.parse("民國七十六年")?.year, 1987)
        XCTAssertEqual(PhotoDate.parse("民国７６年")?.year, 1987)
        XCTAssertEqual(PhotoDate.parse("民國元年")?.year, 1912)
        XCTAssertEqual(PhotoDate.parse("民國一百零四年")?.year, 2015)
        XCTAssertNil(PhotoDate.parse("七十六年"))
        XCTAssertNil(PhotoDate.parse("民国0年"))
        XCTAssertNil(PhotoDate.parse("民國 1987 年"))
    }

    func testSceneWhitelistAndThreshold() {
        XCTAssertEqual(SceneTag.suggestions([("forest", 0.92), ("unknown", 0.99), ("woodland", 0.88),
                                            ("wedding", 0.59), ("beach", 0.76)]), [.forest, .beach])
    }

    func testOCRDoesNotSuggestConflictingYears() {
        XCTAssertEqual(PhotoDate.ocrSuggestion(["July 1987", "Summer holiday"])?.month, 7)
        XCTAssertNil(PhotoDate.ocrSuggestion(["1985–1987"]))
        XCTAssertNil(PhotoDate.ocrSuggestion(["民國七十六年，回顧一九八五年"]))
        XCTAssertNil(PhotoDate.ocrSuggestion(["一九八五年", "１９８７年"]))
    }

    func testOldMetadataDecodesWithoutRecognitionOrEnhancement() throws {
        let item = Scan(albumID: UUID(), pageID: UUID(), corners: .full)
        let oldData = try JSONEncoder().encode(item)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: oldData) as? [String: Any])
        XCTAssertNil(keys["enhancement"])
        XCTAssertNil(keys["faces"])
        XCTAssertEqual(try JSONDecoder().decode(Scan.self, from: oldData), item)
    }

    func testCameraActivityRejectsEnhancementAdmission() async throws {
        let queue = EnhancementQueue()
        let camera = ObjectIdentifier(self)
        queue.camera(camera, active: true)
        do {
            _ = try await queue.run { _ in XCTFail("Active camera allowed new work") }
            XCTFail("Expected the camera to pause enhancement")
        } catch EnhancementFailure.paused {}
        queue.camera(camera, active: false)
        let result = try await queue.run { checkpoint in try checkpoint(); return 17 }
        XCTAssertEqual(result, 17)
    }

    func testGrayAndSepiaEligibilityRejectsColor() {
        XCTAssertTrue(PhotoRecognition.eligibleForColor(sample(0.45, 0.45, 0.45)))
        XCTAssertTrue(PhotoRecognition.eligibleForColor(sample(0.60, 0.51, 0.43)))
        XCTAssertFalse(PhotoRecognition.eligibleForColor(sample(0.15, 0.42, 0.58)))
    }

    func testAtomicDerivedMetadataAndOriginalRemainIntact() throws {
        let archive = try Archive.open(demo: true)
        defer { try? FileManager.default.removeItem(at: archive.root) }
        let album = try XCTUnwrap(try archive.albums().first)
        let item = try archive.render(Scan(albumID: album.id, pageID: UUID(), corners: .full), from: sample(0.45, 0.45, 0.45))
        let signature = try SHA256.hash(data: Data(contentsOf: archive.original(item)))
        let base = try XCTUnwrap(CIImage(contentsOf: archive.original(item)))
        XCTAssertEqual(try DetailRenderer().render(base, strength: 0, checkpoint: {}).extent, base.extent)
        let edit = AppliedEnhancement(kind: .clarity, strength: 120, renderer: DetailRenderer().identifier)
        XCTAssertEqual(edit.strength, 100)
        let result = try DetailRenderer().render(base, strength: 0.3, checkpoint: {})
        XCTAssertEqual(result.extent, base.extent)
        try archive.stageEnhancement(result, item: item, edit: edit)
        XCTAssertEqual(try archive.records().photos.first, item)
        var enhanced = item
        enhanced.enhancement = edit
        try archive.commit(enhanced)
        XCTAssertNotEqual(archive.original(enhanced), archive.result(enhanced))
        XCTAssertEqual(try archive.records().photos.first?.enhancement, edit)
        archive.discardEnhancement(enhanced, id: edit.id)
        XCTAssertEqual(archive.result(enhanced), archive.baseResult(enhanced))
        enhanced.enhancement = nil
        enhanced.unenhanced = true
        try archive.commit(enhanced)
        XCTAssertEqual(archive.result(enhanced), archive.original(enhanced))
        XCTAssertEqual(try SHA256.hash(data: Data(contentsOf: archive.original(enhanced))), signature)
    }

    func testDDColorSimulatorCPUPredictionAndWrite() async throws {
        #if targetEnvironment(simulator)
        if !DDColorRenderer.isBundled {
            if ProcessInfo.processInfo.environment["OLDPHOTO_REQUIRE_DDCOLOR_CPU"] == "true" {
                XCTFail("Real DDColor.mlmodelc is missing from the app bundle")
                return
            }
            throw XCTSkip("Real DDColor must be installed for CPU verification")
        }
        let grayscale = sample(0.52, 0.52, 0.52)
        let matches = try await EnhancementQueue.shared.run { checkpoint in
            let result = try DDColorRenderer.shared.render(grayscale, strength: 0.35, checkpoint: checkpoint)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".heic")
            defer { try? FileManager.default.removeItem(at: url) }
            try Imaging.write(result, to: url)
            return CIImage(contentsOf: url)?.extent == grayscale.extent
        }
        XCTAssertTrue(matches)
        #else
        throw XCTSkip("This test explicitly verifies simulator CPU execution")
        #endif
    }

    private func sample(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: red, green: green, blue: blue)).cropped(to: CGRect(x: 0, y: 0, width: 96, height: 96))
    }
}
