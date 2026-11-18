import CoreImage
import XCTest
@testable import OldPhoto

final class CoreTests: XCTestCase {
    func testTrialExpiresAtThirtyDaysAndReceiptDoesNotRestartIt() {
        let firstOpen = Date(timeIntervalSince1970: 1_700_000_000)
        var access = Access(started: firstOpen)
        XCTAssertTrue(access.hasPro(at: firstOpen))
        XCTAssertTrue(access.hasPro(at: firstOpen.addingTimeInterval(30 * 86_400 - 1)))
        XCTAssertFalse(access.hasPro(at: firstOpen.addingTimeInterval(30 * 86_400)))
        access.credential = firstOpen.addingTimeInterval(4 * 86_400)
        XCTAssertEqual(access.trialStart, firstOpen)
        access.credential = firstOpen.addingTimeInterval(-12 * 86_400)
        XCTAssertEqual(access.days(at: firstOpen), 18)
        access.bought = true
        XCTAssertTrue(access.hasPro(at: .distantFuture))
    }

    func testAutoShutterStabilizesAndWaitsForNewPage() {
        let boxes = [Corners.centered]
        var auto = AutoShutter()
        let signature = Array(repeating: 0.4, count: 64)
        XCTAssertFalse(auto.update(boxes: boxes, signature: signature, now: 0))
        XCTAssertFalse(auto.update(boxes: boxes, signature: signature, now: 0.9))
        XCTAssertTrue(auto.update(boxes: boxes, signature: signature, now: 1.01))
        auto.captured(boxes, signature: signature)
        XCTAssertFalse(auto.update(boxes: boxes, signature: signature, now: 5))
        let next = Array(repeating: 0.57, count: 64)
        XCTAssertFalse(auto.update(boxes: boxes, signature: next, now: 5.1))
        XCTAssertTrue(auto.update(boxes: boxes, signature: next, now: 6.2))
        auto.captured(boxes, signature: next)
        _ = auto.update(boxes: [], signature: [], now: 7)
        _ = auto.update(boxes: [], signature: [], now: 7.6)
        _ = auto.update(boxes: boxes, signature: next, now: 8)
        XCTAssertTrue(auto.update(boxes: boxes, signature: next, now: 9.1))
    }

    func testPageOutlineAndNestedFramesAreFiltered() {
        let frames = Demo.boxes
        let nested = frames[0].inset(0.18)
        let outer = Corners(rect: CGRect(x: 0.025, y: 0.03, width: 0.95, height: 0.94))
        XCTAssertEqual(Corners.filter([outer, nested] + Array(frames.reversed())), frames)
        XCTAssertEqual(Corners.centered.moving(0, to: CGPoint(x: 0.93, y: 0.88)), .centered)
    }

    func testPrintedPageFindsFourPhotosAndKeepsGeometry() throws {
        let original = try Imaging.upright(Demo.jpeg)
        let found = Imaging.rectangles(original, contours: true)
        XCTAssertEqual(found.count, 4)
        for expected in Demo.boxes {
            XCTAssertTrue(found.contains { Corners.stable([expected], [$0], tolerance: 0.023) }, "\(expected) 没找到；实际识别：\(found)")
        }
        let expanded = original.transformed(by: CGAffineTransform(scaleX: 2, y: 2))
        let crop = Imaging.crop(expanded, corners: Demo.boxes[0], whiteBorder: true, rotation: 0)
        XCTAssertEqual(crop.extent.width, expanded.extent.width * Demo.boxes[0].bounds.width, accuracy: 3)
        let rotated = Imaging.crop(expanded, corners: Demo.boxes[0], whiteBorder: true, rotation: 1)
        XCTAssertEqual(crop.extent.width, rotated.extent.height, accuracy: 1)
    }

    func testPaperRefinementRepairsKnownVisionCandidateWithoutMovingAlignedPhotos() throws {
        let original = try Imaging.upright(Demo.jpeg)
        let expected = Demo.boxes
        let candidate = Corners(tl: CGPoint(x: 0.0454, y: 0.4810), tr: CGPoint(x: 0.4967, y: 0.4807),
                                br: CGPoint(x: 0.5202, y: 0.8094), bl: CGPoint(x: 0.0417, y: 0.8094))
        let nearFirst = Corners(rect: expected[0].bounds.insetBy(dx: -0.004, dy: -0.004))
        let nearSecond = Corners(rect: expected[1].bounds.offsetBy(dx: 0.010, dy: -0.010))
        let nearFourth = Corners(rect: expected[3].bounds.offsetBy(dx: -0.010, dy: 0.010))
        let input = [nearFirst, nearSecond, candidate, nearFourth]
        let shifted = original.transformed(by: CGAffineTransform(translationX: 23, y: -37))
        let refined = Imaging.refinePhotoEdges(input, in: shifted)

        guard refined.count == input.count else { return XCTFail("\(refined)") }
        for index in [0, 1, 3] {
            XCTAssertEqual(refined[index], input[index])
        }
        XCTAssertTrue(Corners.stable([expected[2]], [refined[2]], tolerance: 0.023), "\(refined[2])")
        XCTAssertLessThan(refined[2].area, candidate.area)
        XCTAssertEqual(Imaging.refinePhotoEdges(expected, in: original), expected)
    }

    func testPaperRefinementUsesTopLeftRowsWithFractionalReducedExtent() {
        let bounds = CGRect(x: 23, y: -37, width: 1301, height: 1793)
        let paperBounds = CGRect(x: bounds.minX + 235, y: bounds.maxY - 540, width: 690, height: 340)
        let background = CIImage(color: CIColor(red: 0.12, green: 0.12, blue: 0.12)).cropped(to: bounds)
        let paper = CIImage(color: CIColor(red: 0.92, green: 0.92, blue: 0.92)).cropped(to: paperBounds)
        let scene = CIImage(color: CIColor(red: 0.18, green: 0.18, blue: 0.18))
            .cropped(to: paperBounds.insetBy(dx: 20, dy: 20))
        let image = scene.composited(over: paper.composited(over: background))
        let expected = Corners(rect: CGRect(x: 235 / bounds.width, y: 200 / bounds.height,
                                            width: 690 / bounds.width, height: 340 / bounds.height))
        let oversized = Corners(rect: expected.bounds.insetBy(dx: -0.021, dy: -0.016))
        let refined = Imaging.refinePhotoEdges([oversized], in: image)

        XCTAssertTrue(Corners.stable([expected], refined, tolerance: 0.006), "\(refined)")
        XCTAssertEqual(Imaging.refinePhotoEdges([expected], in: image), [expected])
        XCTAssertEqual(Imaging.refinePhotoEdges([oversized], in: background), [oversized])
    }

    func testToneRestorationPreservesSizeAndMonochrome() {
        let bounds = CGRect(x: 0, y: 0, width: 128, height: 96)
        let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 128, y: 0),
            "inputColor0": CIColor(red: 0.23, green: 0.19, blue: 0.14),
            "inputColor1": CIColor(red: 0.70, green: 0.61, blue: 0.49)
        ])!.outputImage!.cropped(to: bounds)
        let profile = Imaging.tone(Imaging.samples(gradient))
        XCTAssertTrue(profile.monochrome)
        XCTAssertLessThan(profile.low[0], profile.high[0])
        XCTAssertEqual(Imaging.restore(gradient, strength: 0).extent, bounds)
        XCTAssertEqual(Imaging.restore(gradient, strength: 0.7).extent, bounds)
    }

    func testFusionReducesLocalHighlightWithoutChangingCleanPatch() {
        let extent = CGRect(x: 0, y: 0, width: 100, height: 80)
        let clean = CIImage(color: CIColor(red: 0.50, green: 0.48, blue: 0.43)).cropped(to: extent)
        let flare = CIImage(color: CIColor(red: 0.99, green: 0.98, blue: 0.97))
            .cropped(to: CGRect(x: 18, y: 20, width: 25, height: 20)).composited(over: clean)
        let shifted = CIImage(color: CIColor(red: 0.99, green: 0.98, blue: 0.97))
            .cropped(to: CGRect(x: 45, y: 40, width: 20, height: 20)).composited(over: clean)
        let result = Imaging.samples(Glare.blend(flare, shifted, extent: extent))
        XCTAssertLessThan(result.luma(30 * 100 + 30), 0.70)
        XCTAssertEqual(result.luma(5 * 100 + 5), Imaging.samples(clean).luma(5 * 100 + 5), accuracy: 0.01)
    }

    func testDateFormatsAndApproximation() {
        XCTAssertEqual(PhotoDate.parse("1987年")?.year, 1987)
        XCTAssertEqual(PhotoDate.parse("全家 １９８７年７月４日")?.day, 4)
        XCTAssertEqual(PhotoDate.parse("87.6")?.month, 6)
        XCTAssertEqual(PhotoDate.parse("June 1985")?.year, 1985)
        XCTAssertEqual(PhotoDate.parse("1980s")?.precision, .decade)
        XCTAssertEqual(PhotoDate.parse("1960年代")?.precision, .decade)
        XCTAssertNil(PhotoDate.parse("1985-02-30"))
        let approx = PhotoDate(year: 1985)
        XCTAssertEqual(PhotoDate.calendar.component(.month, from: approx.date!), 7)
    }

    func testFamilyCodeRoundTripAndRejectsCorruption() throws {
        let id = UUID()
        let code = FamilyCode(reply: true, entries: [
            FamilyCode.Entry(id: id, date: PhotoDate(year: 1987), place: "北戴河", people: "外婆")
        ])
        XCTAssertEqual(try FamilyCode.decode(code.encode()), code)
        XCTAssertThrowsError(try FamilyCode.decode(FamilyCode.prefix + "invalid!"))
        XCTAssertThrowsError(try FamilyCode.decode(FamilyCode(entries: [code.entries[0], code.entries[0]]).encode()))
    }

    func testArchiveKeepsOriginalCaptureAndExportsCurrentResolution() throws {
        let archive = try Archive.open(demo: true)
        defer { try? FileManager.default.removeItem(at: archive.root) }
        let album = try XCTUnwrap(archive.albums().first)
        let image = try Imaging.upright(Demo.jpeg)
        let scan = Scan(albumID: album.id, pageID: UUID(), corners: Demo.boxes[0], strength: 0.7)
        try Demo.jpeg.write(to: archive.page(scan.pageID))
        let rendered = try archive.render(scan, from: image)
        let original = try archive.export(rendered, original: true)
        let current = try archive.export(rendered, original: false)
        defer { for file in [original, current] { try? FileManager.default.removeItem(at: file) } }
        XCTAssertEqual(try Imaging.upright(Data(contentsOf: original)).extent.size,
                       try Imaging.upright(Data(contentsOf: current)).extent.size)
        XCTAssertEqual(try Data(contentsOf: archive.page(scan.pageID)), Demo.jpeg)
        XCTAssertEqual(try archive.records().photos, [rendered])
    }
}
