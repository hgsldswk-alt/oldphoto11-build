#if DEBUG
import CoreImage
import UIKit

enum Demo {
    static let size = CGSize(width: 840, height: 1120)
    static let aspect = size.width / size.height
    static let boxes = [
        Corners(rect: CGRect(x: 0.065, y: 0.070, width: 0.415, height: 0.39)),
        Corners(rect: CGRect(x: 0.521, y: 0.10, width: 0.412, height: 0.38)),
        Corners(rect: CGRect(x: 0.068, y: 0.51, width: 0.445, height: 0.28)),
        Corners(rect: CGRect(x: 0.547, y: 0.53, width: 0.395, height: 0.39))
    ]

    static let preview = page(reflection: true)
    static let jpeg = preview.jpegData(compressionQuality: 0.98) ?? Data()
    static var backData: Data {
        render(size: CGSize(width: 1100, height: 660)) { _ in
            UIColor(hex: 0xEFE3CE).setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 1100, height: 660))
            ("July 1987\nFamily trip to the coast" as NSString).draw(at: CGPoint(x: 110, y: 160), withAttributes: [
                .font: UIFont(name: "Georgia", size: 55) ?? UIFont.systemFont(ofSize: 55),
                .foregroundColor: UIColor(hex: 0x514031)
            ])
        }.jpegData(compressionQuality: 0.95) ?? Data()
    }

    static func seed(_ archive: Archive) throws {
        let albums = ["demo_grandmas", "demo_house", "demo_portraits"].map { Album(name: L.t($0)) }
        try archive.writeAlbums(albums)
        let counts = [4, 3, 3]
        for (a, album) in albums.enumerated() {
            let pageID = UUID()
            let data: Data
            if a == 0 && (Launch.has("-color-fixture") || Launch.has("-missing-color-model")) {
                let gray = CIImage(color: CIColor(red: 0.48, green: 0.48, blue: 0.48))
                    .cropped(to: CGRect(origin: .zero, size: size))
                data = Imaging.context.jpegRepresentation(of: gray, colorSpace: Imaging.sRGB, options: [:]) ?? Data()
            } else {
                data = a == 0 ? jpeg : (page(reflection: false, offset: a).jpegData(compressionQuality: 0.98) ?? Data())
            }
            let image = try Imaging.upright(data)
            try data.write(to: archive.page(pageID), options: .atomic)
            for i in 0..<counts[a] {
                var scan = Scan(albumID: album.id, pageID: pageID, corners: boxes[i])
                scan.strength = a == 0 || i == 0 ? 0.70 : 0
                scan.reflected = a == 0 && i == 3
                if a == 0 && i == 0 {
                    scan.place = Place(name: L.t("demo_coast"))
                    scan.people = L.t("demo_family")
                    scan.backText = L.t("demo_back")
                    scan.suggestedDate = PhotoDate(year: 1987, month: 7, precision: .month)
                    scan.note = L.t("demo_note")
                    if Launch.has("-color-fixture") || Launch.has("-missing-color-model") { scan.colorizable = true }
                    if Launch.has("-recognition-fixture") {
                        scan.sceneTags = [.beach]
                        scan.faces = [PhotoFace(rect: CGRect(x: 0.32, y: 0.21, width: 0.23, height: 0.34))]
                    }
                } else if i != 1 {
                    scan.date = PhotoDate(year: [1962, 1983, 1991, 1987][i] + a * 2)
                }
                let created = try archive.render(scan, from: image)
                var saved = created
                saved.saved = a == 0
                try archive.commit(saved)
                if a == 0 && i == 0 { try backData.write(to: archive.back(saved), options: .atomic) }
            }
        }
    }

    static func page(reflection: Bool, offset: Int = 0) -> UIImage {
        render(size: size) { ctx in
            UIColor(hex: 0x211D1A).setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            for (i, item) in boxes.enumerated() {
                let b = item.bounds
                let rect = CGRect(x: b.minX * size.width, y: b.minY * size.height,
                                  width: b.width * size.width, height: b.height * size.height)
                UIColor(hex: 0xF2E9D8).setFill()
                UIRectFill(rect)
                let inset = rect.insetBy(dx: 13, dy: 13)
                ctx.saveGState()
                ctx.clip(to: inset)
                ctx.translateBy(x: inset.minX, y: inset.minY)
                ctx.scaleBy(x: inset.width / 320, y: inset.height / 420)
                scene((i + offset) % 4, in: ctx)
                ctx.restoreGState()
                if reflection && i == 3, let gradient = CGGradient(colorsSpace: Imaging.sRGB,
                    colors: [UIColor.white.cgColor, UIColor.white.withAlphaComponent(0).cgColor] as CFArray,
                    locations: [0.22, 1]) {
                    ctx.saveGState()
                    ctx.clip(to: inset)
                    let p = CGPoint(x: inset.midX + 34, y: inset.midY - 45)
                    ctx.drawRadialGradient(gradient, startCenter: p, startRadius: 0, endCenter: p, endRadius: 80, options: [])
                    ctx.restoreGState()
                }
            }
        }
    }

    private static func scene(_ index: Int, in ctx: CGContext) {
        func rect(_ hex: UInt32, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
            ctx.setFillColor(UIColor(hex: hex).cgColor)
            ctx.fill(CGRect(x: x, y: y, width: w, height: h))
        }
        func circle(_ hex: UInt32, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
            ctx.setFillColor(UIColor(hex: hex).cgColor)
            ctx.fillEllipse(in: CGRect(x: x, y: y, width: w, height: h))
        }
        func person(x: CGFloat, y: CGFloat, scale: CGFloat, outfit: UInt32, skin: UInt32 = 0xCAAA91) {
            circle(0x4E4035, x + 6 * scale, y - 6 * scale, 32 * scale, 32 * scale)
            circle(skin, x + 7 * scale, y, 30 * scale, 34 * scale)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x, y: y + 140 * scale))
            path.addQuadCurve(to: CGPoint(x: x + 45 * scale, y: y + 140 * scale),
                              control: CGPoint(x: x + 22 * scale, y: y + 142 * scale))
            path.addQuadCurve(to: CGPoint(x: x, y: y + 140 * scale),
                              control: CGPoint(x: x + 22 * scale, y: y - 65 * scale))
            ctx.setFillColor(UIColor(hex: outfit).cgColor)
            ctx.addPath(path)
            ctx.fillPath()
        }
        switch index {
        case 0:
            rect(0xD8CBC0, 0, 0, 320, 420)
            circle(0xF6E7C4, 220, 35, 42, 42)
            rect(0x708E93, 0, 194, 320, 72)
            rect(0x809AA0, 0, 201, 320, 11)
            rect(0xE5D1AC, 0, 266, 320, 154)
            person(x: 58, y: 184, scale: 1.35, outfit: 0x9E7469)
            person(x: 137, y: 218, scale: 1.07, outfit: 0xD8B67F)
            person(x: 209, y: 251, scale: 0.85, outfit: 0x6F7E68)
        case 1:
            rect(0x9A9486, 0, 0, 320, 420)
            circle(0xA59E8F, -28, -20, 380, 550)
            person(x: 52, y: 115, scale: 5, outfit: 0x4D4943, skin: 0xC7BCAA)
            circle(0x5D554A, 124, 170, 10, 7)
            circle(0x5D554A, 170, 170, 10, 7)
        case 2:
            rect(0xDED2B8, 0, 0, 320, 420)
            rect(0x8D9170, 0, 284, 320, 136)
            rect(0xEFE4CB, 74, 153, 182, 165)
            let roof = CGMutablePath()
            roof.addLines(between: [CGPoint(x: 56, y: 163), CGPoint(x: 165, y: 69), CGPoint(x: 273, y: 163)])
            roof.closeSubpath()
            ctx.setFillColor(UIColor(hex: 0x876960).cgColor); ctx.addPath(roof); ctx.fillPath()
            rect(0x8A8278, 103, 189, 33, 48); rect(0x8A8278, 191, 189, 33, 48)
            rect(0x706052, 151, 231, 31, 87)
            rect(0x66604A, 271, 236, 11, 83)
            circle(0x7D8461, 244, 154, 74, 100)
            circle(0x909471, 10, 175, 61, 92)
        default:
            rect(0xB2A18D, 0, 0, 320, 420)
            rect(0xC7B49D, 0, 210, 320, 102)
            rect(0x9E8D7B, 26, 16, 70, 164); rect(0x9E8D7B, 233, 21, 63, 154)
            for (i, tint) in [0x756E70, 0x9F7D72, 0x788372, 0xC0A083].enumerated() {
                person(x: 22 + CGFloat(i) * 72, y: 165 + CGFloat(i % 2) * 13, scale: 1.08, outfit: UInt32(tint))
            }
        }
        var rng: UInt32 = UInt32(index) + 71
        for _ in 0..<11000 {
            rng = 1664525 &* rng &+ 1013904223
            let x = CGFloat(rng % 320)
            rng = 1664525 &* rng &+ 1013904223
            let y = CGFloat(rng % 420)
            ctx.setFillColor(UIColor(white: rng & 128 == 0 ? 0 : 1, alpha: 0.055).cgColor)
            ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }

    private static func render(size: CGSize, draw: (CGContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { draw($0.cgContext) }
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255,
                  blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}
#endif
