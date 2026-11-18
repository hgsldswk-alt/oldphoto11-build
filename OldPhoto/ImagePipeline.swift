import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision
import simd

enum Imaging {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    static let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: sRGB])

    static func upright(_ data: Data) throws -> CIImage {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]),
              !image.extent.isEmpty, !image.extent.isInfinite else { throw ScanError.image }
        return zero(image)
    }

    static func zero(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    static func reduced(_ image: CIImage, limit: CGFloat) -> CIImage {
        let ratio = min(1, limit / max(image.extent.width, image.extent.height))
        return zero(image).transformed(by: CGAffineTransform(scaleX: ratio, y: ratio))
    }

    static func rectangles(_ input: CIImage, single: Bool = false, contours: Bool) -> [Corners] {
        let image = reduced(input, limit: 1152)
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 0
        request.minimumSize = 0.08
        request.minimumConfidence = 0.55
        request.minimumAspectRatio = 0.32
        request.quadratureTolerance = 35
        let handler = VNImageRequestHandler(ciImage: image)
        try? handler.perform([request])
        func topLeft(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: 1 - point.y) }
        let boxes = (request.results ?? []).map {
            Corners(tl: topLeft($0.topLeft), tr: topLeft($0.topRight),
                    br: topLeft($0.bottomRight), bl: topLeft($0.bottomLeft))
        }
        let found = Corners.filter(boxes, single: single)
        guard contours else { return found }
        if found.isEmpty || found == [.full] {
            let fallback = contourBoxes(handler, single: single)
            return fallback.isEmpty ? found : fallback
        }
        return refinePhotoEdges(found, in: image)
    }

    private static func contourBoxes(_ handler: VNImageRequestHandler, single: Bool) -> [Corners] {
        let outline = VNDetectContoursRequest()
        outline.maximumImageDimension = 768
        outline.detectsDarkOnLight = false
        try? handler.perform([outline])
        let alternatives = (outline.results?.first?.topLevelContours ?? []).compactMap { contour -> Corners? in
            guard let polygon = try? contour.polygonApproximation(epsilon: 0.018),
                  polygon.normalizedPoints.count == 4 else { return nil }
            let points = polygon.normalizedPoints.map { CGPoint(x: CGFloat($0.x), y: 1 - CGFloat($0.y)) }
            let halves = points.sorted { $0.y < $1.y }
            let top = halves.prefix(2).sorted { $0.x < $1.x }
            let bottom = halves.suffix(2).sorted { $0.x < $1.x }
            let box = Corners(tl: top[0], tr: top[1], br: bottom[1], bl: bottom[0])
            return box.area >= 0.035 ? box : nil
        }
        return Corners.filter(alternatives, single: single)
    }

    static func refinePhotoEdges(_ candidates: [Corners], in image: CIImage) -> [Corners] {
        let image = reduced(image, limit: 896)
        let bounds = image.extent.integral
        let padding = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: bounds)
        let padded = bounds == image.extent ? image : image.composited(over: padding)
        guard let raster = context.createCGImage(padded, from: bounds, format: .RGBA8, colorSpace: sRGB),
              raster.width == Int(bounds.width), raster.height == Int(bounds.height)
        else { return candidates }
        let width = raster.width, height = raster.height
        var sample = Samples(bytes: [UInt8](repeating: 0, count: width * height * 4), width: width, height: height)
        let drawn = sample.bytes.withUnsafeMutableBytes { buffer in
            let rgba = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            guard let bitmap = CGContext(data: buffer.baseAddress, width: width, height: height,
                                         bitsPerComponent: 8, bytesPerRow: width * 4, space: sRGB, bitmapInfo: rgba)
            else { return false }
            bitmap.draw(raster, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return candidates }
        let size = SIMD2(Double(image.extent.width), Double(image.extent.height))
        let topPadding = Double(bounds.maxY - image.extent.maxY)
        return candidates.map { $0 == .full ? $0 : shrinkToPaper($0, in: sample, size: size, topPadding: topPadding) }
    }

    private static func shrinkToPaper(_ box: Corners, in sample: Samples, size: SIMD2<Double>,
                                      topPadding: Double) -> Corners {
        let points = box.points.map { SIMD2(Double($0.x), Double($0.y)) * size }
        let directions = points.indices.map { points[($0 + 1) % points.count] - points[$0] }
        let lengths = directions.map { simd_length($0) }
        guard let shortSide = lengths.min(), shortSide > 0 else { return box }
        let minimum = max(6, Int(shortSide * 0.025))
        let radius = min(48, Int(shortSide * 0.14))
        guard radius >= minimum else { return box }
        let normals = zip(directions, lengths).map { SIMD2(-$0.0.y, $0.0.x) / $0.1 }

        func luma(at point: SIMD2<Double>) -> Double? {
            let row = point.y + topPadding
            guard point.x >= 0, point.x < Double(sample.width), row >= 0, row < Double(sample.height)
            else { return nil }
            let index = Int(row) * sample.width + Int(point.x)
            return sample.bytes[index * 4 + 3] >= 250 ? sample.luma(index) : nil
        }

        func firstPaper(from start: SIMD2<Double>, along inward: SIMD2<Double>) -> Int? {
            for offset in -3...radius {
                let position = start + inward * Double(offset)
                guard let level = luma(at: position) else { return nil }
                if level <= 0.35 { continue }
                guard offset >= minimum,
                      let near = luma(at: position + inward * 2), near >= 0.65,
                      let far = luma(at: position + inward * 4), far >= 0.65 else { return nil }
                return offset
            }
            return nil
        }

        let shifts = points.indices.map { index -> Int in
            let offsets = (0..<19).compactMap { sampleIndex in
                let start = points[index] + directions[index] * (0.14 + 0.04 * Double(sampleIndex))
                return firstPaper(from: start, along: normals[index])
            }.sorted()
            guard offsets.count >= 15 else { return 0 }
            let median = offsets[offsets.count / 2]
            return offsets.filter { abs($0 - median) <= 3 }.count >= 15 ? median : 0
        }
        guard shifts.filter({ $0 > 0 }).count >= 3 else { return box }
        let shifted = points.indices.map { points[$0] + normals[$0] * Double(shifts[$0]) }

        func cross(_ left: SIMD2<Double>, _ right: SIMD2<Double>) -> Double {
            left.x * right.y - left.y * right.x
        }
        var corners: [CGPoint] = []
        for index in points.indices {
            let previous = (index + points.count - 1) % points.count
            let before = directions[previous], after = directions[index]
            let divisor = cross(before, after)
            guard abs(divisor) > 0.12 * lengths[previous] * lengths[index] else { return box }
            let intersection = shifted[previous] + before * (cross(shifted[index] - shifted[previous], after) / divisor)
            guard simd_length(intersection - points[index]) <= Double(radius) * 1.6,
                  points.indices.allSatisfy({ simd_dot(intersection - points[$0], normals[$0]) >= -0.001 })
            else { return box }
            let point = intersection / size
            corners.append(CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)))
        }
        let refined = Corners(tl: corners[0], tr: corners[1], br: corners[2], bl: corners[3])
        guard refined.valid, (0.70...1).contains(refined.area / box.area) else { return box }
        return refined
    }

    static func crop(_ image: CIImage, corners: Corners, whiteBorder: Bool, rotation: Int) -> CIImage {
        let image = zero(image)
        let box = whiteBorder ? corners : corners.inset(0.07)
        let extent = image.extent
        func vector(_ p: CGPoint) -> CIVector {
            CIVector(x: p.x * extent.width, y: (1 - p.y) * extent.height)
        }
        let corrected = box == .full ? image : image.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": vector(box.tl), "inputTopRight": vector(box.tr),
            "inputBottomLeft": vector(box.bl), "inputBottomRight": vector(box.br)
        ])
        let orientation = [CGImagePropertyOrientation.up, .right, .down, .left][(rotation % 4 + 4) % 4]
        return zero(corrected.oriented(orientation))
    }

    static func orientation(_ image: CIImage) -> Int {
        let preview = reduced(image, limit: 400)
        let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
        var best = (turns: 0, score: 0.0)
        for (turns, orientation) in orientations.enumerated() {
            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(ciImage: preview, orientation: orientation, options: [.ciContext: context])
            try? handler.perform([request])
            let score = (request.results ?? []).reduce(0.0) { total, face in
                total + Double(face.confidence) * sqrt(Double(face.boundingBox.width * face.boundingBox.height))
            }
            if score > best.score * (turns == 0 ? 1 : 1.33) { best = (turns, score) }
        }
        return best.turns
    }

    struct Samples {
        var bytes: [UInt8]
        var width: Int
        var height: Int
        func luma(_ index: Int) -> Double {
            let offset = index * 4
            return (0.2126 * Double(bytes[offset]) + 0.7152 * Double(bytes[offset + 1])
                    + 0.0722 * Double(bytes[offset + 2])) / 255
        }
        var signature: [Double] {
            (0..<64).map { i in
                let x = min(width - 1, (i % 8 * 2 + 1) * width / 16)
                let y = min(height - 1, (i / 8 * 2 + 1) * height / 16)
                return luma(y * width + x)
            }
        }
    }

    static func samples(_ image: CIImage, limit: CGFloat = 144) -> Samples {
        let image = reduced(image, limit: limit)
        let width = max(1, Int(image.extent.width))
        let height = max(1, Int(image.extent.height))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            context.render(image, toBitmap: base, rowBytes: width * 4,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBA8, colorSpace: sRGB)
        }
        return Samples(bytes: bytes, width: width, height: height)
    }

    static func reflection(_ sample: Samples, in box: Corners = .full) -> Bool {
        let rect = box.inset(0.23).bounds
        let left = max(0, Int(rect.minX * CGFloat(sample.width)))
        let right = min(sample.width, Int(rect.maxX * CGFloat(sample.width)))
        let bottom = max(0, Int((1 - rect.maxY) * CGFloat(sample.height)))
        let top = min(sample.height, Int((1 - rect.minY) * CGFloat(sample.height)))
        guard right - left >= 4, top - bottom >= 4 else { return false }
        let total = (right - left) * (top - bottom)
        var clipped = 0
        var cluster = 0
        func white(_ i: Int) -> Bool {
            let rgb = sample.bytes[i * 4 ..< i * 4 + 3]
            return (rgb.min() ?? 0) >= 246
        }
        for y in bottom..<(top - 1) {
            for x in left..<(right - 1) {
                let i = y * sample.width + x
                if white(i) {
                    clipped += 1
                    if white(i + 1) && white(i + sample.width) && white(i + sample.width + 1) { cluster += 1 }
                }
            }
        }
        return Double(clipped) / Double(total) < 0.34 && Double(cluster) / Double(total) > 0.019
    }

    struct Tone {
        var low: [Double]
        var high: [Double]
        var monochrome: Bool
    }

    static func tone(_ sample: Samples) -> Tone {
        var channels = Array(repeating: [Int](repeating: 0, count: 256), count: 3)
        var chroma = [Double](repeating: 0, count: 2)
        var squared = chroma
        let total = sample.width * sample.height
        for offset in stride(from: 0, to: total * 4, by: 4) {
            let r = Int(sample.bytes[offset]), g = Int(sample.bytes[offset + 1]), b = Int(sample.bytes[offset + 2])
            channels[0][r] += 1
            channels[1][g] += 1
            channels[2][b] += 1
            for (i, value) in [Double(r - g), Double(b - g)].enumerated() {
                chroma[i] += value
                squared[i] += value * value
            }
        }
        func percentile(_ histogram: [Int], fraction: Double) -> Double {
            let target = max(1, Int(Double(total) * fraction))
            var count = 0
            for (i, value) in histogram.enumerated() {
                count += value
                if count >= target { return Double(i) / 255 }
            }
            return 1
        }
        let monochrome = chroma.indices.allSatisfy {
            squared[$0] / Double(total) - pow(chroma[$0] / Double(total), 2) < 125
        }
        return Tone(low: channels.map { percentile($0, fraction: 0.025) },
                    high: channels.map { percentile($0, fraction: 0.975) }, monochrome: monochrome)
    }

    static func restore(_ image: CIImage, strength: Double) -> CIImage {
        let strength = min(1, max(0, strength))
        guard strength > 0 else { return image }
        let tone = tone(samples(image))
        let pivot = 0.48
        let lows = tone.monochrome ? [Double](repeating: tone.low[1], count: 3) : tone.low
        let highs = tone.monochrome ? [Double](repeating: tone.high[1], count: 3) : tone.high
        let gains = lows.indices.map { min(1.6, max(1, 0.88 / max(0.12, highs[$0] - lows[$0]))) }
        let bias = lows.indices.map { i -> Double in
            if tone.monochrome { return (1 - gains[i]) * pivot }
            return max(-0.16, min(0.14, 0.055 - lows[i] * gains[i]))
        }
        var result = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1 + (gains[0] - 1) * strength, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1 + (gains[1] - 1) * strength, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1 + (gains[2] - 1) * strength, w: 0),
            "inputBiasVector": CIVector(x: bias[0] * strength, y: bias[1] * strength, z: bias[2] * strength, w: 0)
        ])
        if !tone.monochrome {
            result = result.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputShadowAmount": 0.15 * strength, "inputHighlightAmount": 1 - 0.08 * strength
            ]).applyingFilter("CIVibrance", parameters: ["inputAmount": 0.17 * strength])
        }
        return result.applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": 0.19 * strength])
            .cropped(to: image.extent)
    }

    static func write(_ image: CIImage, to url: URL, tiled: Bool = false) throws {
        if tiled { try writeTiles(zero(image), to: url); return }
        try context.writeHEIFRepresentation(of: zero(image), to: url, format: .RGBA8, colorSpace: sRGB,
                                            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 1.0])
    }

    private static func writeTiles(_ image: CIImage, to url: URL) throws {
        let bounds = image.extent.integral
        let width = Int(bounds.width), height = Int(bounds.height)
        guard (1...16_000).contains(width), (1...16_000).contains(height) else { throw ScanError.image }
        let bytesPerRow = width * 4
        let bytes = bytesPerRow * height
        let scratch = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".rgba")
        guard FileManager.default.createFile(atPath: scratch.path, contents: nil) else { throw ScanError.disk }
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try FileHandle(forUpdating: scratch)
        defer { try? file.close() }
        try file.truncate(atOffset: UInt64(bytes))
        guard let pixels = mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, file.fileDescriptor, 0),
              pixels != MAP_FAILED else { throw ScanError.disk }
        defer { munmap(pixels, bytes) }
        guard let bitmap = CGContext(data: pixels, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: bytesPerRow, space: sRGB,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScanError.image }
        bitmap.interpolationQuality = .none
        for row in stride(from: 0, to: height, by: 256) {
            try autoreleasepool {
                let rect = CGRect(x: 0, y: row, width: width, height: min(256, height - row))
                guard let tile = context.createCGImage(image, from: rect, format: .RGBA8, colorSpace: sRGB) else {
                    throw ScanError.image
                }
                bitmap.draw(tile, in: rect)
            }
        }
        guard let output = bitmap.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil)
        else { throw ScanError.image }
        CGImageDestinationAddImage(destination, output,
                                   [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ScanError.image }
    }

    static func text(_ image: CIImage) throws -> (String, PhotoDate?) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = try request.supportedRecognitionLanguages()
        let preferred = ["zh-Hans", "zh-Hant", "en-US"].filter { supported.contains($0) }
        if !preferred.isEmpty { request.recognitionLanguages = preferred }
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(ciImage: reduced(image, limit: 2400)).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first }
        let text = lines.map(\.string).joined(separator: "\n")
        return (text, PhotoDate.ocrSuggestion(lines.filter { $0.confidence >= 0.45 }.map(\.string)))
    }
}
