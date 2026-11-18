import CoreImage
import CoreML
import Foundation

final class DDColorRenderer: EnhancementRenderer {
    static let shared = DDColorRenderer()

    static var assetName: String {
        if Launch.has("-missing-color-model") { return "MissingDDColor" }
        return Launch.has("-color-fixture") ? "DDColorFixture" : "DDColor"
    }

    static var isBundled: Bool { modelURL != nil }
    private static var modelURL: URL? { Bundle.main.url(forResource: assetName, withExtension: "mlmodelc") }
    private var cachedModel: MLModel?
    private var size: Int { Launch.has("-color-fixture") ? 16 : 512 }
    var identifier: String {
        cachedModel?.modelDescription.metadata[.versionString] as? String ?? "ddcolor-paper-tiny-lab-v1"
    }

    func render(_ original: CIImage, strength: Double, checkpoint: () throws -> Void) throws -> CIImage {
        if strength <= 0 { return original }
        guard let url = Self.modelURL else { throw EnhancementFailure.unavailable }
        guard PhotoRecognition.eligibleForColor(original) else { throw EnhancementFailure.unsupportedPhoto }
        try checkpoint()
        let model: MLModel
        if let cachedModel { model = cachedModel }
        else {
            let configuration = MLModelConfiguration()
            #if targetEnvironment(simulator)
            configuration.computeUnits = .cpuOnly
            #endif
            model = try MLModel(contentsOf: url, configuration: configuration)
            cachedModel = model
        }
        let edge = size
        let shape = [NSNumber(value: 1), NSNumber(value: 3), NSNumber(value: edge), NSNumber(value: edge)]
        let input = try MLMultiArray(shape: shape, dataType: .float32)
        let bounds = CGRect(x: 0, y: 0, width: edge, height: edge)
        let scaled = Imaging.zero(original).transformed(by: CGAffineTransform(
            scaleX: CGFloat(edge) / original.extent.width, y: CGFloat(edge) / original.extent.height))
        var rgba = [UInt8](repeating: 0, count: edge * edge * 4)
        rgba.withUnsafeMutableBytes { buffer in
            guard let start = buffer.baseAddress else { return }
            Imaging.context.render(scaled, toBitmap: start, rowBytes: edge * 4,
                                   bounds: bounds, format: .RGBA8, colorSpace: Imaging.sRGB)
        }
        let strides = input.strides.map(\.intValue)
        let values = input.dataPointer.assumingMemoryBound(to: Float.self)
        let linear = (0...255).map { component -> Double in
            let unit = Double(component) / 255
            return unit <= 0.04045 ? unit / 12.92 : pow((unit + 0.055) / 1.055, 2.4)
        }
        for row in 0..<edge {
            for column in 0..<edge {
                let offset = ((edge - 1 - row) * edge + column) * 4
                let luminance = 0.2126729 * linear[Int(rgba[offset])] + 0.7151522 * linear[Int(rgba[offset + 1])]
                              + 0.0721750 * linear[Int(rgba[offset + 2])]
                let gray = Float(luminance <= 0.0031308 ? 12.92 * luminance : 1.055 * pow(luminance, 1 / 2.4) - 0.055)
                for channel in 0..<3 { values[channel * strides[1] + row * strides[2] + column * strides[3]] = gray }
            }
        }
        try checkpoint()
        let features = try MLDictionaryFeatureProvider(dictionary: ["gray_rgb": MLFeatureValue(multiArray: input)])
        let prediction = try model.prediction(from: features)
        try checkpoint()
        guard let ab = prediction.featureValue(for: "lab_ab")?.multiArrayValue,
              ab.dataType == .float32, ab.shape.map(\.intValue) == [1, 2, edge, edge] else { throw ScanError.image }
        let abStrides = ab.strides.map(\.intValue)
        let output = ab.dataPointer.assumingMemoryBound(to: Float.self)
        var pixels = [Float](repeating: 0, count: edge * edge * 4)
        for row in 0..<edge {
            for column in 0..<edge {
                let source = row * abStrides[2] + column * abStrides[3]
                let target = ((edge - 1 - row) * edge + column) * 4
                let a = output[source], b = output[source + abStrides[1]]
                guard a.isFinite && b.isFinite else { throw ScanError.image }
                pixels[target] = (min(127, max(-128, a)) + 128) / 255
                pixels[target + 1] = (min(127, max(-128, b)) + 128) / 255
                pixels[target + 3] = 1
            }
        }
        let chroma = CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: edge * 16,
                             size: bounds.size, format: .RGBAf, colorSpace: nil)
            .clampedToExtent().transformed(by: CGAffineTransform(scaleX: original.extent.width / CGFloat(edge),
                                                                y: original.extent.height / CGFloat(edge)))
            .transformed(by: CGAffineTransform(translationX: original.extent.minX, y: original.extent.minY))
            .cropped(to: original.extent)
        let kernel = try Self.combine.get()
        guard let result = kernel.apply(extent: original.extent, arguments: [original, chroma, NSNumber(value: strength)]) else {
            throw ScanError.image
        }
        return result
    }

    private static let combine = Result<CIColorKernel, Error> {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "default.metallib"])
        }
        return try CIColorKernel(functionName: "oldPhotoColorize", fromMetalLibraryData: Data(contentsOf: url))
    }
}
