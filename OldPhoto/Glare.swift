import CoreImage
import CoreVideo
import Foundation
import simd
import Vision

enum Glare {
    struct Result {
        var scan: Scan
        var blended: Bool
    }

    static func reduce(in archive: Archive, scan: Scan, supplemental: [URL]) throws -> Result {
        let reference = try Imaging.upright(Data(contentsOf: archive.original(scan), options: .mappedIfSafe))
        let thumb = Imaging.samples(reference, limit: 176)
        var candidates: [(CIImage, Double)] = []
        for url in supplemental {
            let candidate = autoreleasepool { () -> (CIImage, Double)? in
                guard let page = try? Imaging.upright(Data(contentsOf: url, options: .mappedIfSafe)) else { return nil }
                let boxes = Imaging.rectangles(page, contours: true)
                let box = boxes.min { distance($0, scan.corners) < distance($1, scan.corners) } ?? scan.corners
                guard distance(box, scan.corners) < 0.25 else { return nil }
                let image = Imaging.crop(page, corners: box, whiteBorder: scan.whiteBorder, rotation: scan.rotation)
                return align(image, to: reference, sample: thumb)
            }
            if let candidate { candidates.append(candidate) }
        }
        guard let best = candidates.min(by: { $0.1 < $1.1 }) else { throw ScanError.alignment }
        let dimensions = reference.extent
        let result = candidates.reduce(reference) { previous, candidate in
            blend(previous, candidate.0, extent: dimensions)
        }
        let improvement = highlightFraction(thumb) - highlightFraction(Imaging.samples(result, limit: 176))
        var draft = scan
        if improvement >= 0.004 {
            draft.reflected = Imaging.reflection(Imaging.samples(result))
            return Result(scan: try archive.render(draft, useStoredGlare: false, glare: result), blended: true)
        }
        let single = best.0.composited(over: reference).cropped(to: dimensions)
        guard highlightFraction(thumb) - highlightFraction(Imaging.samples(single, limit: 176)) >= 0.006
                && best.1 < 0.065 else { throw ScanError.alignment }
        draft.reflected = Imaging.reflection(Imaging.samples(single))
        return Result(scan: try archive.render(draft, useStoredGlare: false, glare: single), blended: false)
    }

    private static func distance(_ a: Corners, _ b: Corners) -> CGFloat {
        hypot(a.bounds.midX - b.bounds.midX, a.bounds.midY - b.bounds.midY)
            + abs(a.bounds.width - b.bounds.width) * 0.35
            + abs(a.bounds.height - b.bounds.height) * 0.35
    }

    private static func align(_ input: CIImage, to reference: CIImage, sample: Imaging.Samples) -> (CIImage, Double)? {
        let size = reference.extent.size
        guard input.extent.width > 0, input.extent.height > 0 else { return nil }
        let resized = input.transformed(by: CGAffineTransform(scaleX: size.width / input.extent.width,
                                                                y: size.height / input.extent.height))
        let small = Imaging.reduced(reference, limit: 480)
        let floating = Imaging.reduced(resized, limit: 480)
        let request = VNHomographicImageRegistrationRequest(targetedCIImage: small)
        try? VNImageRequestHandler(ciImage: floating).perform([request])
        var options = [resized]
        if let matrix = request.results?.first?.warpTransform {
            for transform in [matrix, simd_inverse(matrix)] {
                for normalized in [false, true] {
                    if let image = warp(resized, matrix: transform, registration: small.extent.size,
                                        normalized: normalized) { options.append(image) }
                }
            }
        }
        let bounds = CGRect(origin: .zero, size: size)
        let ranked = options.map { image -> (CIImage, Double) in
            let candidate = image.cropped(to: bounds)
            return (candidate, quality(sample, Imaging.samples(candidate, limit: 176)))
        }
        guard var best = ranked.min(by: { $0.1 < $1.1 }), best.1 < 0.16 else { return nil }
        if let flow = flowField(from: small, to: Imaging.reduced(best.0, limit: 480)) {
            for sign in [1.0, -1.0] {
                let image = adjustFlow(best.0, flow: flow, bounds: bounds, sign: sign)
                let score = quality(sample, Imaging.samples(image, limit: 176))
                if score + 0.002 < best.1 { best = (image, score); break }
            }
        }
        guard best.1 < 0.105 else { return nil }
        return (gainMatch(best.0, reference: sample), best.1)
    }

    private static func warp(_ input: CIImage, matrix: simd_float3x3, registration: CGSize,
                             normalized: Bool) -> CIImage? {
        let width = input.extent.width, height = input.extent.height
        let basis = normalized ? CGSize(width: 1, height: 1) : registration
        func transformed(_ x: CGFloat, _ y: CGFloat) -> CIVector? {
            let p = matrix * SIMD3<Float>(Float(x * basis.width), Float(y * basis.height), 1)
            let horizontal = CGFloat(p.x / p.z) / basis.width
            let vertical = CGFloat(p.y / p.z) / basis.height
            guard horizontal.isFinite, vertical.isFinite,
                  abs(horizontal - x) < 0.36, abs(vertical - y) < 0.36 else { return nil }
            return CIVector(x: horizontal * width, y: vertical * height)
        }
        guard let tl = transformed(0, 1), let tr = transformed(1, 1),
              let br = transformed(1, 0), let bl = transformed(0, 0) else { return nil }
        return input.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": tl, "inputTopRight": tr, "inputBottomRight": br, "inputBottomLeft": bl
        ])
    }

    private static func quality(_ a: Imaging.Samples, _ b: Imaging.Samples) -> Double {
        guard a.width == b.width && a.height == b.height, a.width > 12, a.height > 12 else { return 1 }
        var gradients = 0.0
        var levels = [Double]()
        var missing = 0
        let count = (a.height - 12) * (a.width - 12)
        for y in 6..<(a.height - 6) {
            for x in 6..<(a.width - 6) {
                let i = y * a.width + x
                guard b.bytes[i * 4 + 3] > 240 else { missing += 1; continue }
                let x1 = a.luma(i), x2 = b.luma(i)
                guard max(x1, x2) < 0.94 else { continue }
                let ax = a.luma(i + 1) - a.luma(i - 1), bx = b.luma(i + 1) - b.luma(i - 1)
                let ay = a.luma(i + a.width) - a.luma(i - a.width)
                let by = b.luma(i + b.width) - b.luma(i - b.width)
                gradients += abs(ax - bx) + abs(ay - by)
                levels.append(x1 - x2)
            }
        }
        guard levels.count > count / 2, missing < count / 6 else { return 1 }
        levels.sort()
        let median = levels[levels.count / 2]
        let residual = levels.reduce(0.0) { $0 + min(0.20, abs($1 - median)) } / Double(levels.count)
        return residual + gradients / Double(levels.count) * 0.55 + Double(missing) / Double(count) * 0.20
    }

    private static func highlightFraction(_ image: Imaging.Samples) -> Double {
        let area = image.width * image.height
        let clipped = (0..<area).filter { image.luma($0) > 0.91 }.count
        return Double(clipped) / Double(area)
    }

    private static func gainMatch(_ input: CIImage, reference: Imaging.Samples) -> CIImage {
        let sample = Imaging.samples(input, limit: 176)
        guard reference.width == sample.width && reference.height == sample.height else { return input }
        let deltas = (0..<(sample.width * sample.height)).compactMap { i -> Double? in
            let a = reference.luma(i), b = sample.luma(i)
            return a > 0.16 && a < 0.72 && b > 0.12 && b < 0.79 && sample.bytes[i * 4 + 3] > 240 ? log2(a / b) : nil
        }.sorted()
        guard !deltas.isEmpty else { return input }
        return input.applyingFilter("CIExposureAdjust", parameters: ["inputEV": max(-0.30, min(0.30, deltas[deltas.count / 2]))])
    }

    private static func flowField(from a: CIImage, to b: CIImage) -> CIImage? {
        let request = VNGenerateOpticalFlowRequest(targetedCIImage: b.clampedToExtent().cropped(to: b.extent))
        request.computationAccuracy = .medium
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
        try? VNImageRequestHandler(ciImage: a).perform([request])
        guard let buffer = request.results?.first?.pixelBuffer,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_TwoComponent32Float else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        var pixels = [Float](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let vectors = base.advanced(by: y * stride).assumingMemoryBound(to: Float.self)
            for x in 0..<w {
                let offset = ((h - 1 - y) * w + x) * 4
                let dx = vectors[x * 2], dy = vectors[x * 2 + 1]
                pixels[offset] = dx.isFinite ? 0.5 + max(-12, min(12, dx)) / 24 : 0.5
                pixels[offset + 1] = dy.isFinite ? 0.5 - max(-12, min(12, dy)) / 24 : 0.5
                pixels[offset + 3] = 1
            }
        }
        let bytes = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: bytes, bytesPerRow: w * 4 * MemoryLayout<Float>.size,
                       size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: nil)
    }

    private static let flowKernel = CIKernel(source: """
    kernel vec4 shiftWithField(sampler source, sampler field, vec2 ratio, float direction) {
        vec2 p = destCoord();
        vec2 v = (sample(field, samplerTransform(field, p * ratio)).rg - vec2(0.5)) * 24.0;
        return sample(source, samplerTransform(source, p + direction * v / ratio));
    }
    """)

    private static func adjustFlow(_ input: CIImage, flow: CIImage, bounds: CGRect, sign: Double) -> CIImage {
        let rx = flow.extent.width / bounds.width, ry = flow.extent.height / bounds.height
        return flowKernel?.apply(extent: bounds, roiCallback: { index, rect in
            index == 0 ? rect.insetBy(dx: -13 / rx, dy: -13 / ry)
                : rect.applying(CGAffineTransform(scaleX: rx, y: ry)).insetBy(dx: -2, dy: -2)
        }, arguments: [input, flow.clampedToExtent(), CIVector(x: rx, y: ry), sign]) ?? input
    }

    private static let fusionKernel = CIColorKernel(source: """
    kernel vec4 softenedMinimum(__sample a, __sample b) {
        float la = dot(a.rgb, vec3(0.2126, 0.7152, 0.0722));
        float lb = dot(b.rgb, vec3(0.2126, 0.7152, 0.0722));
        float hot = smoothstep(0.50, 0.89, la);
        float better = smoothstep(0.035, 0.24, la - lb);
        return vec4(mix(a.rgb, b.rgb, hot * better * step(0.98, b.a)), a.a);
    }
    """)

    static func blend(_ reference: CIImage, _ alternate: CIImage, extent: CGRect) -> CIImage {
        fusionKernel?.apply(extent: extent, arguments: [reference, alternate]) ?? reference
    }
}
