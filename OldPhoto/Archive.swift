import CoreImage
import CoreLocation
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers
import UIKit

struct Archive: Sendable {
    let root: URL
    private var scans: URL { root.appendingPathComponent("Albums", isDirectory: true) }
    private var pages: URL { root.appendingPathComponent("Pages", isDirectory: true) }
    private var albumsFile: URL { root.appendingPathComponent("albums.json") }

    static func open(demo: Bool) throws -> Archive {
        let parent = try FileManager.default.url(for: demo ? .cachesDirectory : .applicationSupportDirectory,
                                                  in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = demo ? "OldPhoto-Demo-\(UUID().uuidString)" : "OldPhoto"
        let archive = Archive(root: parent.appendingPathComponent(folder, isDirectory: true))
        for url in [archive.scans, archive.pages] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        var url = archive.root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return archive
    }

    func albums() throws -> [Album] {
        guard FileManager.default.fileExists(atPath: albumsFile.path) else {
            let initial = [Album()]
            try writeAlbums(initial)
            return initial
        }
        let list = try JSONDecoder().decode([Album].self, from: Data(contentsOf: albumsFile))
        guard !list.isEmpty else { throw ScanError.disk }
        return list
    }

    func writeAlbums(_ albums: [Album]) throws { try JSONEncoder().encode(albums).write(to: albumsFile, options: .atomic) }

    func records() throws -> (photos: [Scan], incomplete: Bool) {
        var incomplete = false
        let buckets = try FileManager.default.contentsOfDirectory(at: scans, includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: [.skipsHiddenFiles])
        let directories = try buckets.filter { UUID(uuidString: $0.lastPathComponent) != nil }.flatMap { bucket in
            try FileManager.default.contentsOfDirectory(at: bucket, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        }
        let items = directories.compactMap { directory -> Scan? in
            let url = directory.appendingPathComponent("meta.json")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            do { return try JSONDecoder().decode(Scan.self, from: Data(contentsOf: url)) }
            catch { incomplete = true; return nil }
        }
        return (items.sorted { $0.created < $1.created }, incomplete)
    }

    func page(_ id: UUID) -> URL { pages.appendingPathComponent(id.uuidString + ".capture") }
    private func directory(_ item: Scan) -> URL {
        scans.appendingPathComponent((item.storageAlbumID ?? item.albumID).uuidString, isDirectory: true)
            .appendingPathComponent(item.id.uuidString, isDirectory: true)
    }
    func back(_ item: Scan) -> URL { directory(item).appendingPathComponent("back.jpg") }
    func deglared(_ item: Scan) -> URL { revision(item).appendingPathComponent("fused.heic") }
    private func revision(_ item: Scan) -> URL {
        directory(item).appendingPathComponent(item.revision.uuidString, isDirectory: true)
    }
    func original(_ item: Scan) -> URL { revision(item).appendingPathComponent("original.heic") }
    func result(_ item: Scan) -> URL {
        if let enhancement = item.enhancement {
            let candidate = derived(item, id: enhancement.id, thumbnail: false)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return baseResult(item)
    }
    func baseResult(_ item: Scan) -> URL {
        if item.unenhanced == true { return original(item) }
        if item.strength > 0 { return revision(item).appendingPathComponent("restored.heic") }
        if item.glareReduced { return deglared(item) }
        return original(item)
    }
    func thumbnail(_ item: Scan) -> URL {
        if let enhancement = item.enhancement, result(item) != baseResult(item) {
            let candidate = derived(item, id: enhancement.id, thumbnail: true)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        if item.unenhanced == true { return original(item) }
        return revision(item).appendingPathComponent("thumbnail.jpg")
    }

    private func derived(_ item: Scan, id: UUID, thumbnail: Bool) -> URL {
        revision(item).appendingPathComponent(id.uuidString + (thumbnail ? ".jpg" : ".heic"))
    }

    func stageEnhancement(_ image: CIImage, item: Scan, edit: AppliedEnhancement) throws {
        let output = derived(item, id: edit.id, thumbnail: false)
        let thumbnail = derived(item, id: edit.id, thumbnail: true)
        let scratch = revision(item).appendingPathComponent(edit.id.uuidString + ".pending.heic")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try Imaging.write(image, to: scratch, tiled: image.extent.width * image.extent.height > 12_000_000)
        guard let preview = Imaging.context.jpegRepresentation(of: Imaging.reduced(image, limit: 440),
                                                               colorSpace: Imaging.sRGB, options: [:]) else { throw ScanError.image }
        try FileManager.default.moveItem(at: scratch, to: output)
        try preview.write(to: thumbnail, options: .atomic)
    }

    func discardEnhancement(_ item: Scan, id: UUID) {
        for thumbnail in [false, true] { try? FileManager.default.removeItem(at: derived(item, id: id, thumbnail: thumbnail)) }
    }

    func commit(_ item: Scan) throws {
        try JSONEncoder().encode(item).write(to: directory(item).appendingPathComponent("meta.json"), options: .atomic)
    }

    func render(_ draft: Scan, from source: CIImage? = nil, useStoredGlare: Bool = true,
                glare: CIImage? = nil) throws -> Scan {
        let previous = draft
        let source = try source ?? Imaging.upright(Data(contentsOf: page(draft.pageID), options: .mappedIfSafe))
        let original = Imaging.crop(source, corners: draft.corners, whiteBorder: draft.whiteBorder, rotation: draft.rotation)
        let storedGlare = useStoredGlare && draft.glareReduced ? CIImage(contentsOf: deglared(draft)) : nil
        let base = glare ?? storedGlare ?? original
        var item = draft
        item.storageAlbumID = draft.storageAlbumID ?? draft.albumID
        item.revision = UUID()
        item.enhancement = nil
        item.unenhanced = nil
        item.glareReduced = glare != nil || storedGlare != nil
        item.width = Int(original.extent.width.rounded())
        item.height = Int(original.extent.height.rounded())
        item.saved = false
        let url = revision(item)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        do {
            try Imaging.write(original, to: self.original(item))
            if item.glareReduced { try Imaging.write(base, to: deglared(item), tiled: true) }
            let editable = item.glareReduced ? CIImage(contentsOf: deglared(item)) ?? base : base
            let display = Imaging.restore(editable, strength: item.strength)
            if item.strength > 0 { try Imaging.write(display, to: result(item), tiled: item.glareReduced) }
            try Imaging.context.writeJPEGRepresentation(of: Imaging.reduced(display, limit: 440),
                to: thumbnail(item), colorSpace: Imaging.sRGB, options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.88])
            try commit(item)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        try? FileManager.default.removeItem(at: revision(previous))
        return item
    }

    func ingest(_ data: Data, album: UUID, single: Bool, strength: Double) throws -> (photos: [Scan], partial: Bool) {
        let image = try Imaging.upright(data)
        let pageID = UUID()
        try data.write(to: page(pageID), options: .atomic)
        let boxes = Imaging.rectangles(image, single: single, contours: true)
        let sample = Imaging.samples(image)
        var photos: [Scan] = []
        var partial = false
        for box in boxes.isEmpty ? [.full] : boxes {
            do {
                let item = try autoreleasepool {
                    var draft = Scan(albumID: album, pageID: pageID, corners: box)
                    draft.rotation = Imaging.orientation(Imaging.crop(image, corners: box, whiteBorder: true, rotation: 0))
                    draft.strength = strength
                    draft.reflected = Imaging.reflection(sample, in: box)
                    do { return try render(draft, from: image) }
                    catch where strength > 0 {
                        draft.strength = 0
                        partial = true
                        return try render(draft, from: image)
                    }
                }
                photos.append(item)
            } catch {
                partial = true
                if photos.isEmpty, (boxes.isEmpty || boxes.count == 1) {
                    throw error
                }
            }
        }
        guard !photos.isEmpty else { throw ScanError.disk }
        return (photos, partial)
    }

    func remove(_ item: Scan, keepPage: Bool) throws {
        try FileManager.default.removeItem(at: directory(item))
        if !keepPage { try? FileManager.default.removeItem(at: page(item.pageID)) }
    }

    func storeBack(_ data: Data, for item: Scan) throws -> Scan {
        let image = try Imaging.upright(data)
        let preview = Imaging.reduced(image, limit: 1600)
        guard let encoded = Imaging.context.jpegRepresentation(of: preview, colorSpace: Imaging.sRGB, options: [:]) else {
            throw ScanError.image
        }
        try encoded.write(to: back(item), options: .atomic)
        var item = item
        item.backText = ""
        item.suggestedDate = nil
        try commit(item)
        return item
    }

    func export(_ item: Scan, original: Bool) throws -> URL {
        let source = original ? self.original(item) : result(item)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OldPhotoExports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(L.t("file_scan") + "-\(UUID().uuidString.prefix(8)).heic")
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    func exportPage(_ item: Scan) throws -> URL {
        let source = page(item.pageID)
        guard let decoded = CGImageSourceCreateWithURL(source as CFURL, nil),
              let type = CGImageSourceGetType(decoded) else { throw ScanError.image }
        let ext = UTType(type as String)?.preferredFilenameExtension ?? "image"
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Original-\(UUID().uuidString).\(ext)")
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    func saveToPhotos(_ item: Scan, from source: URL) async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let granted = status == .notDetermined ? await PHPhotoLibrary.requestAuthorization(for: .addOnly) : status
        guard granted == .authorized || granted == .limited else { throw ScanError.photoAccess }
        let components = [item.people, item.note].filter { !$0.isEmpty }
        let caption = ([item.date?.label, item.place?.name].compactMap { $0 } + components).joined(separator: " · ")
        let copy = caption.isEmpty ? nil : Self.annotatedCopy(source, caption: caption)
        defer { if let copy { try? FileManager.default.removeItem(at: copy) } }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: copy ?? source, options: nil)
            request.creationDate = item.date?.date ?? item.created
            if let latitude = item.place?.latitude, let longitude = item.place?.longitude {
                request.location = CLLocation(latitude: latitude, longitude: longitude)
            }
        }
    }

    private static func annotatedCopy(_ file: URL, caption: String) -> URL? {
        let metadata = CGImageMetadataCreateMutable()
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyIPTCDictionary,
                                                           kCGImagePropertyIPTCCaptionAbstract, caption as CFString) else { return nil }
        let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".heic")
        guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, UTType.heic.identifier as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: true]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
            _ = error?.takeRetainedValue()
            try? FileManager.default.removeItem(at: destinationURL)
            return nil
        }
        return destinationURL
    }
}
