import CoreImage
import Foundation
import Vision

enum EnhancementKind: String, Codable {
    case colorize, clarity, superResolution

    var title: String { L.t("enhance_" + rawValue) }
    var defaultStrength: Int { self == .colorize ? 35 : 30 }
}

struct AppliedEnhancement: Codable, Equatable {
    let id: UUID
    let kind: EnhancementKind
    let strength: Int
    let renderer: String

    init(kind: EnhancementKind, strength: Int, renderer: String) {
        id = UUID()
        self.kind = kind
        self.strength = min(100, max(0, strength))
        self.renderer = renderer
    }
}

protocol EnhancementRenderer {
    var identifier: String { get }
    func render(_ original: CIImage, strength: Double, checkpoint: () throws -> Void) throws -> CIImage
}

enum EnhancementFailure: Error { case paused, unavailable, unsupportedPhoto }

struct DetailRenderer: EnhancementRenderer {
    let identifier = "coreimage-noise-sharpen-v1"

    func render(_ original: CIImage, strength: Double, checkpoint: () throws -> Void) throws -> CIImage {
        try checkpoint()
        guard strength > 0 else { return original }
        return original.clampedToExtent().applyingFilter("CINoiseReduction", parameters: [
            "inputNoiseLevel": 0.016 * strength,
            "inputSharpness": 0.0
        ]).applyingFilter("CISharpenLuminance", parameters: [
            "inputSharpness": 0.22 * strength,
            "inputRadius": 1.15
        ]).cropped(to: original.extent)
    }
}

enum EnhancementRenderers {
    static func renderer(for kind: EnhancementKind) -> (any EnhancementRenderer)? {
        switch kind {
        case .colorize: return DDColorRenderer.shared
        case .clarity: return DetailRenderer()
        case .superResolution: return nil
        }
    }
}

final class EnhancementQueue: @unchecked Sendable {
    static let shared = EnhancementQueue()
    private let worker = DispatchQueue(label: "oldphoto.enhancement", qos: .userInitiated)
    private let lock = NSLock()
    private var cameras = Set<ObjectIdentifier>()
    private var generation: UInt64 = 0

    func camera(_ id: ObjectIdentifier, active: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if active {
            if cameras.insert(id).inserted { generation &+= 1 }
        } else { cameras.remove(id) }
    }

    private func ticket() throws -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        guard cameras.isEmpty else { throw EnhancementFailure.paused }
        return generation
    }

    func run<Value>(_ operation: @escaping (_ checkpoint: () throws -> Void) throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let admission = try ticket()
        let cancellation = WorkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                worker.async {
                    continuation.resume(with: Result {
                        try autoreleasepool {
                            func checkpoint() throws {
                                try cancellation.check()
                                guard try self.ticket() == admission else { throw EnhancementFailure.paused }
                            }
                            try checkpoint()
                            return try operation(checkpoint)
                        }
                    })
                }
            }
        } onCancel: { cancellation.cancel() }
    }
}

private final class WorkCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }
}

enum SceneTag: String, CaseIterable, Codable, Identifiable {
    case beach, mountains, snow, forest, flowers, indoors, city, wedding

    var id: String { rawValue }
    var title: String { L.t("scene_" + rawValue) }

    static func suggestions(_ observations: [(identifier: String, confidence: Float)]) -> [SceneTag] {
        let allowed: [String: SceneTag] = [
            "beach": .beach, "seashore": .beach, "coast": .beach,
            "mountain": .mountains, "mountainous": .mountains, "snow": .snow,
            "forest": .forest, "woodland": .forest, "flower": .flowers, "flower_garden": .flowers,
            "indoor": .indoors, "indoors": .indoors, "living_room": .indoors,
            "city": .city, "cityscape": .city, "street": .city, "wedding": .wedding
        ]
        var found: [SceneTag] = []
        for result in observations.sorted(by: { $0.confidence > $1.confidence }) where result.confidence >= 0.60 {
            if let tag = allowed[result.identifier], !found.contains(tag) { found.append(tag) }
            if found.count == 3 { break }
        }
        return found
    }
}

struct PhotoFace: Codable, Equatable, Identifiable {
    var id = UUID()
    let rect: CGRect
    var name = ""

    var group: String {
        name.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

struct PhotoRecognition {
    var date: PhotoDate?
    var tags: [SceneTag]?
    var faces: [PhotoFace]?
    var colorizable: Bool

    static func front(_ original: CIImage, item: Scan, checkpoint: () throws -> Void) throws -> Self {
        let image = Imaging.reduced(original, limit: 1600)
        let handler = VNImageRequestHandler(ciImage: image)
        var result = Self(colorizable: eligibleForColor(original))
        if item.date == nil && item.suggestedDate == nil {
            try checkpoint()
            result.date = (try? Imaging.text(image))?.1
        }
        if item.sceneTags == nil {
            try checkpoint()
            let request = VNClassifyImageRequest()
            if (try? handler.perform([request])) != nil {
                result.tags = SceneTag.suggestions((request.results ?? []).map { ($0.identifier, $0.confidence) })
            }
        }
        if item.faces == nil {
            try checkpoint()
            let request = VNDetectFaceRectanglesRequest()
            if (try? handler.perform([request])) != nil {
                let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
                let rectangles = (request.results ?? []).filter { $0.confidence >= 0.55 }.map { $0.boundingBox.intersection(unit) }
                result.faces = rectangles.filter { !$0.isEmpty }.sorted { $0.minX < $1.minX }.prefix(24).map {
                    PhotoFace(rect: CGRect(x: $0.minX, y: 1 - $0.maxY, width: $0.width, height: $0.height))
                }
            }
        }
        try checkpoint()
        return result
    }

    static func eligibleForColor(_ image: CIImage) -> Bool {
        let bytes = Imaging.samples(image, limit: 96).bytes
        var usable = 0, neutral = 0, sepia = 0
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let red = Int(bytes[offset]), green = Int(bytes[offset + 1]), blue = Int(bytes[offset + 2])
            guard bytes[offset + 3] > 200, max(red, green, blue) > 20, min(red, green, blue) < 239 else { continue }
            usable += 1
            let spread = max(red, green, blue) - min(red, green, blue)
            if spread <= 10 { neutral += 1 }
            else if spread <= 65, red >= green, green >= blue, abs((red - green) - (green - blue)) <= 25 { sepia += 1 }
        }
        return usable >= 24 && (Double(neutral) / Double(usable) >= 0.97 ||
                                (sepia >= usable / 5 && Double(neutral + sepia) / Double(usable) >= 0.985))
    }
}
