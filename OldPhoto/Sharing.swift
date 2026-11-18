import CoreImage.CIFilterBuiltins
import LinkPresentation
import SwiftUI
import UIKit

enum AppLinks {
    static let help = URL(string: "https://hgsldswk-alt.github.io/oldphoto-support/")!
    static let privacy = URL(string: "https://hgsldswk-alt.github.io/oldphoto-support/#privacy")!
    private static var appID: String? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "APP_STORE_ID") as? String,
              !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
        return id
    }
    static var listing: URL {
        if let appID, let url = URL(string: "https://apps.apple.com/app/id\(appID)") { return url }
        return URL(string: "https://hgsldswk-alt.github.io/oldphoto-support/#download")!
    }
    static var review: URL { appID == nil ? listing : listing.appending(queryItems: [URLQueryItem(name: "action", value: "write-review")]) }

    static func qr(_ url: URL) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage, let image = Imaging.context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}

struct SharePayload: Identifiable {
    let id = UUID()
    var content: [Any]
    var cleanup: [URL] = []
    var card: UIImage?
    var copied = false
}

struct Activities: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

final class CardActivityItem: NSObject, UIActivityItemSource {
    private let image: UIImage
    private let title: String

    init(image: UIImage, copied: Bool) {
        self.image = image
        title = L.t(copied ? "caption_copied" : "app_short")
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { image }
    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { image }
    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.imageProvider = NSItemProvider(object: image)
        return metadata
    }
}

struct SharePresentation: View {
    let payload: SharePayload
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Group {
            if Launch.has("-shot-share"), let card = payload.card {
                VStack(spacing: 12) {
                    HStack {
                        if payload.copied { Label(L.t("caption_copied"), systemImage: "checkmark").font(.footnote) }
                        Spacer()
                        Button(L.t("done")) { dismiss() }
                    }.padding(.horizontal, 18).padding(.top, 12)
                    Image(uiImage: card).resizable().scaledToFit().padding(.horizontal, 24)
                        .frame(maxHeight: 415)
                        .accessibilityIdentifier("share-card")
                    Activities(items: payload.content)
                        .frame(minHeight: 225)
                }.background(Paper.background)
            } else if let card = payload.card {
                let others = payload.content.dropFirst()
                Activities(items: [CardActivityItem(image: card, copied: payload.copied) as Any] + Array(others))
            } else { Activities(items: payload.content) }
        }
        .onDisappear { for file in payload.cleanup { try? FileManager.default.removeItem(at: file) } }
    }
}

enum Cards {
    private static let paper = Color(hex: 0xF7F4EE)
    private static let ink = Color(hex: 0x221E1A)
    private static let brown = Color(hex: 0x8C4A32)

    @MainActor
    static func comparison(item: Scan, before: UIImage, after: UIImage, branded: Bool) -> UIImage? {
        let subtitle = [item.place?.name, item.note.isEmpty ? nil : item.note].compactMap { $0 }.joined(separator: " · ")
        let content = VStack(spacing: 8) {
            panel(before, label: "original")
            panel(after, label: item.enhancement.map { "enhance_" + $0.kind.rawValue } ?? "restored")
            if item.enhancement?.kind == .colorize {
                Text(L.t("colorize_disclaimer")).font(.caption2).foregroundStyle(brown)
            }
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.date?.label ?? item.suggestedDate?.label ?? L.t("comparison"))
                        .font(.system(size: 21, design: .serif)).lineLimit(1)
                    if !subtitle.isEmpty { Text(subtitle).font(.caption).lineLimit(2) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if branded { brand }
            }.frame(height: 56)
        }.padding(18).frame(width: 360, height: item.enhancement?.kind == .colorize ? 490 : 450)
            .background(paper).foregroundStyle(ink)
        return render(content)
    }

    @MainActor
    static func occasion(title: String, subtitle: String, images: [UIImage]) -> UIImage? {
        let content = VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 27, weight: .semibold, design: .serif)).lineLimit(2)
            Text(subtitle).font(.callout).foregroundStyle(brown).lineLimit(2)
            let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(images.prefix(9).enumerated()), id: \.offset) { i, image in
                    Image(uiImage: image).resizable().scaledToFill().frame(width: 102, height: 70)
                        .clipped().overlay(alignment: .topLeading) {
                            Text(String(i + 1)).font(.caption2.bold()).padding(4).background(paper, in: Capsule()).padding(4)
                        }
                }
            }
            Spacer(minLength: 2)
            HStack { Spacer(); brand }
        }.padding(18).frame(width: 360, height: 450).background(paper).foregroundStyle(ink)
        return render(content)
    }

    private static func panel(_ image: UIImage, label: String) -> some View {
        Image(uiImage: image).resizable().scaledToFit().frame(width: 324, height: 170)
            .background(Color(hex: 0xEEE7DB))
            .clipped().overlay(alignment: .topLeading) {
                Text(L.t(label)).font(.caption.bold()).padding(.vertical, 4).padding(.horizontal, 7)
                    .foregroundStyle(.white).background(.black.opacity(0.48), in: Capsule()).padding(8)
            }
    }

    private static var brand: some View {
        VStack(spacing: 3) {
            if let qr = AppLinks.qr(AppLinks.listing) {
                Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                    .padding(3).frame(width: 37, height: 37).background(.white)
            }
            Text(L.t("app_short")).font(.system(size: 8)).foregroundStyle(brown).lineLimit(1)
        }
    }

    @MainActor
    private static func render<V: View>(_ content: V) -> UIImage? {
        let renderer = ImageRenderer(content: content.environment(\.colorScheme, .light))
        renderer.scale = 3
        renderer.proposedSize = ProposedViewSize(width: 360, height: 450)
        return renderer.uiImage
    }
}

enum AlbumPDF {
    static func write(_ items: [Scan], title: String, archive: Archive, branded: Bool) throws -> URL {
        let size = Locale.current.region?.identifier == "US" || Locale.current.region?.identifier == "CA"
            ? CGSize(width: 612, height: 792) : CGSize(width: 595.28, height: 841.89)
        let box = CGRect(origin: .zero, size: size)
        let folder = FileManager.default.temporaryDirectory
        let url = folder.appendingPathComponent("OldPhoto-\(UUID().uuidString).pdf")
        let layout = UIGraphicsPDFRenderer(bounds: box)
        try layout.writePDF(to: url) { context in
            let heading = UIFont(name: "Georgia", size: 32) ?? UIFont.systemFont(ofSize: 32)
            let body = UIFont.systemFont(ofSize: 15)
            let bodyAttributes: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: UIColor.darkGray]
            context.beginPage()
            (title as NSString).draw(in: CGRect(x: 54, y: 120, width: size.width - 108, height: 100),
                                       withAttributes: [.font: heading])
            let dates = items.compactMap { $0.date?.year }.sorted()
            let range = dates.first.flatMap { first in dates.last.map { "\(first)–\($0)" } } ?? ""
            ([L.f("photo_count", String(items.count)), range].filter { !$0.isEmpty }.joined(separator: " · ") as NSString)
                .draw(at: CGPoint(x: 54, y: 225), withAttributes: bodyAttributes)
            for item in items {
                autoreleasepool {
                    guard let image = ArchiveImage.read(archive.result(item), limit: 2200) else { return }
                    context.beginPage()
                    let inset = CGRect(x: 42, y: 52, width: size.width - 84, height: size.height - 190)
                    let fitted = aspectFit(image.size.width / image.size.height, in: inset.size)
                    image.draw(in: fitted.offsetBy(dx: inset.minX, dy: inset.minY))
                    let caption = [item.date?.label ?? "", item.place?.name ?? "", item.people, item.note]
                        .filter { !$0.isEmpty }.joined(separator: " · ")
                    (caption as NSString).draw(in: CGRect(x: 42, y: inset.maxY + 16, width: size.width - 84, height: 72),
                                              withAttributes: bodyAttributes)
                }
            }
            if branded {
                context.beginPage()
                (L.t("pdf_credit") as NSString).draw(at: CGPoint(x: 54, y: 126), withAttributes: bodyAttributes)
                AppLinks.qr(AppLinks.listing)?.draw(in: CGRect(x: 54, y: 160, width: 110, height: 110))
            }
        }
        return url
    }
}
