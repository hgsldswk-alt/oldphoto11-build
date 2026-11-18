import ImageIO
import SwiftUI

enum Paper {
    static let background = adaptive(0xF7F4EE, 0x1D1916)
    static let card = adaptive(0xFFFDF9, 0x27211D)
    static let ink = adaptive(0x221E1A, 0xF5ECE3)
    static let secondary = adaptive(0x716961, 0xC9BAAD)
    static let line = adaptive(0xE7E1D7, 0x423831)
    static let accent = adaptive(0x8C4A32, 0xE0A68B)
    static let button = Color(red: 0.55, green: 0.29, blue: 0.20)
    static let camera = Color(white: 0.07)
    static let marker = Color(red: 0.96, green: 0.63, blue: 0.50)

    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
}

struct PaperCard: ViewModifier {
    func body(content: Content) -> some View {
        content.background(Paper.card, in: RoundedRectangle(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(Paper.line, lineWidth: 1).allowsHitTesting(false) }
    }
}

struct ActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).padding(.horizontal, 16).padding(.vertical, 13)
            .frame(minHeight: 48).frame(maxWidth: .infinity)
            .foregroundStyle(.white)
            .background(Paper.button.opacity(configuration.isPressed ? 0.78 : 1), in: RoundedRectangle(cornerRadius: 15))
    }
}

struct ArchiveImage: View {
    var url: URL?
    var limit = 480
    var mode: ContentMode = .fill
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { frame in
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: mode)
                    .frame(width: frame.size.width, height: frame.size.height).clipped()
            } else {
                Paper.line.overlay { Image(systemName: "photo").foregroundStyle(Paper.secondary) }
            }
        }
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else { image = nil; return }
            let result = await Task.detached(priority: .userInitiated) { Self.read(url, limit: limit) }.value
            if !Task.isCancelled { image = result }
        }
    }

    static func read(_ url: URL, limit: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: limit
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

struct PhotoStack: View {
    var urls: [URL]
    var body: some View {
        ZStack {
            ForEach(0..<max(1, min(3, urls.count)), id: \.self) { index in
                ArchiveImage(url: index < urls.count ? urls[index] : nil)
                    .frame(width: 60, height: 65)
                    .padding(4)
                    .background(Color(hex: 0xF5EFE2))
                    .overlay { Rectangle().strokeBorder(Color(hex: 0xDDD4C4), lineWidth: 1) }
                    .rotationEffect(.degrees([8, -10, -1][index]))
                    .offset(x: [8, -7, 0][index], y: [-4, 4, 5][index])
            }
        }.frame(width: 96, height: 90)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
                  blue: Double(hex & 255) / 255)
    }
}

func aspectFit(_ aspect: CGFloat, in size: CGSize) -> CGRect {
    guard aspect > 0, size.width > 0, size.height > 0 else { return .zero }
    let height = min(size.height, size.width / aspect)
    let width = height * aspect
    return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
}

struct CornerOverlay: View {
    let boxes: [Corners]
    let rect: CGRect
    var body: some View {
        Canvas { canvas, _ in
            for (index, box) in boxes.enumerated() {
                let points = box.points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
                var path = Path()
                path.addLines(points)
                path.closeSubpath()
                canvas.stroke(path, with: .color(Paper.marker), lineWidth: 1.5)
                for point in points {
                    let dot = CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
                    canvas.fill(Path(ellipseIn: dot.insetBy(dx: -1.5, dy: -1.5)), with: .color(Paper.camera))
                    canvas.fill(Path(ellipseIn: dot), with: .color(Paper.marker))
                }
                let label = CGPoint(x: points[0].x + 15, y: points[0].y + 15)
                canvas.fill(Path(ellipseIn: CGRect(x: label.x - 8, y: label.y - 8, width: 16, height: 16)),
                            with: .color(Paper.marker))
                canvas.draw(Text(String(index + 1)).font(.system(size: 10, weight: .bold)).foregroundColor(Paper.camera), at: label)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
