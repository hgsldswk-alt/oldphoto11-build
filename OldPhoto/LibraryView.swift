import PhotosUI
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var model: Model
    @Binding var path: [Route]
    @State private var picker: PhotosPickerItem?
    @State private var share: SharePayload?
    @State private var milestone = 0
    @AppStorage("closed-scan-milestone") private var closedMilestone = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                summary
                Button(L.t("people"), systemImage: "person.2") { path.append(.people) }
                    .accessibilityIdentifier("people-view")
                if milestone > closedMilestone, !Launch.isolated { milestoneCard }
                HStack {
                    Text(L.t("albums")).font(.system(.title2, design: .serif))
                    Spacer()
                    PhotosPicker(selection: $picker, matching: .images) { Text(L.t("import_photo")).font(.subheadline) }
                }.padding(.top, 3)
                if model.scans.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        Image(systemName: "rectangle.stack").font(.title2)
                        Text(L.t("empty_library")).font(.subheadline)
                    }.foregroundStyle(Paper.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(20).modifier(PaperCard())
                }
                ForEach(model.albums) { album in
                    Button {
                        path.append(.album(album.id))
                    } label: {
                        albumRow(album)
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("album-row")
                }
            }.padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 20)
        }
        .background(Paper.background.ignoresSafeArea())
        .foregroundStyle(Paper.ink)
        .navigationTitle(L.t("library"))
        .accessibilityIdentifier("library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { path.append(.settings) } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel(L.t("settings")).accessibilityIdentifier("library-settings")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button(L.t("keep_scanning")) { path.removeAll() }.buttonStyle(ActionStyle())
                .frame(maxWidth: 280).padding(.horizontal, 20).padding(.vertical, 8)
                .frame(maxWidth: .infinity).background(Paper.background)
        }
        .sheet(item: $share) { SharePresentation(payload: $0) }
        .onChange(of: picker) { _, value in
            guard let value else { return }
            Task {
                defer { picker = nil }
                do {
                    guard let data = try await value.loadTransferable(type: Data.self) else { throw ScanError.image }
                    _ = await model.ingest(data, single: false)
                } catch { model.message = L.t("capture_issue") }
            }
        }
        .onChange(of: model.scans.count, initial: true) { _, count in
            milestone = [100, 500, 1000].last(where: { $0 <= count }) ?? 0
        }
    }

    private var summary: some View {
        Button { path.append(.timeline) } label: {
            VStack(alignment: .leading, spacing: 9) {
                Text(L.t("already_scanned")).font(.subheadline).foregroundStyle(Paper.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(model.scans.count, format: .number).font(.system(size: 43, weight: .bold)).monospacedDigit()
                    Text(L.f("library_totals", String(model.albums.count))).font(.subheadline).foregroundStyle(Paper.secondary)
                }
                TimelineStrip(scans: model.scans)
                HStack {
                    Text(L.t("timeline"))
                    Spacer()
                    Text(L.f("dates_missing", String(model.scans.filter(\.needsDate).count)))
                    Image(systemName: "chevron.right").font(.caption2)
                }.font(.caption).foregroundStyle(Paper.secondary)
            }.padding(17).modifier(PaperCard())
        }
        .buttonStyle(.plain).accessibilityIdentifier("library-timeline")
    }

    private func albumRow(_ album: Album) -> some View {
        let items = model.photos(in: album.id)
        let years = items.compactMap { $0.date?.year }.sorted()
        let count = L.f("photo_count", String(items.count))
        let range = years.first.flatMap { first in years.last.map { first == $0 ? String(first) : "\(first)–\($0)" } }
        let restored = items.filter { $0.strength > 0 || $0.glareReduced }.count
        return HStack(spacing: 12) {
            PhotoStack(urls: items.prefix(3).compactMap { model.archive?.thumbnail($0) })
            VStack(alignment: .leading, spacing: 5) {
                Text(album.title).font(.system(.title3, design: .serif)).lineLimit(2)
                Text([count, range].compactMap { $0 }.joined(separator: " · ")).font(.subheadline)
                    .foregroundStyle(Paper.secondary)
                if !items.isEmpty {
                    Text(L.f("restored_count", String(restored))).font(.caption.weight(.semibold))
                        .foregroundStyle(Paper.accent).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Paper.accent.opacity(0.12), in: Capsule())
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(Paper.secondary).font(.caption.bold())
        }.padding(11).padding(.trailing, 6).modifier(PaperCard())
    }

    private var milestoneCard: some View {
        HStack {
            Button(L.f("milestone_count", String(milestone))) {
                let photos = model.scans.suffix(9)
                let images = photos.compactMap { item in model.archive.flatMap { ArchiveImage.read($0.thumbnail(item), limit: 400) } }
                if let card = Cards.occasion(title: L.f("milestone_count", String(milestone)),
                                              subtitle: L.t("milestone_subtitle"), images: images) {
                    share = SharePayload(content: [card], card: card)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { closedMilestone = milestone } label: { Image(systemName: "xmark") }
                .accessibilityLabel(L.t("dismiss"))
        }.padding(12).modifier(PaperCard())
    }
}

struct TimelineStrip: View {
    let scans: [Scan]
    var body: some View {
        let groups = Dictionary(grouping: scans) { $0.date.map { $0.year / 10 * 10 } ?? 0 }
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(Array(groups.keys.sorted().enumerated()), id: \.element) { index, year in
                    Rectangle().fill(year == 0 ? Paper.line : Paper.accent.opacity(min(1, 0.30 + Double(index % 5) * 0.16)))
                        .frame(width: max(1, (proxy.size.width - CGFloat(max(0, groups.count - 1)) * 2)
                            * CGFloat(groups[year]?.count ?? 0) / CGFloat(max(scans.count, 1))))
                }
            }.frame(maxWidth: .infinity).background(Paper.line).clipShape(Capsule())
        }.frame(height: 8).accessibilityHidden(true)
    }
}

struct TimelineView: View {
    @Binding var path: [Route]
    @EnvironmentObject private var model: Model
    private var groups: [Int: [Scan]] {
        Dictionary(grouping: model.scans) { $0.date.map { $0.year / 10 * 10 } ?? 0 }
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if model.scans.isEmpty { Text(L.t("empty_library")).foregroundStyle(Paper.secondary) }
                ForEach(groups.keys.filter { $0 != 0 }.sorted() + (groups[0] == nil ? [] : [0]), id: \.self) { year in
                    let items = groups[year] ?? []
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(year == 0 ? L.t("undated") : L.f("decade_format", String(year)))
                                .font(.system(.title2, design: .serif))
                            Spacer()
                            Text(L.f("photo_count", String(items.count))).font(.caption).foregroundStyle(Paper.secondary)
                        }
                        LazyVGrid(columns: photoColumns, spacing: 6) {
                            ForEach(items) { item in
                                Button { path.append(.detail(item.id)) } label: { tile(item, archive: model.archive) }
                                    .accessibilityLabel(item.date?.label ?? L.t("undated"))
                            }
                        }.buttonStyle(.plain)
                    }
                    .padding(13).modifier(PaperCard())
                }
            }.padding(18)
        }.foregroundStyle(Paper.ink).background(Paper.background.ignoresSafeArea())
        .navigationTitle(L.t("timeline")).navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("timeline")
    }
}

private let photoColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
private func tile(_ item: Scan, archive: Archive?) -> some View {
    ArchiveImage(url: archive?.thumbnail(item)).frame(height: 110).clipShape(RoundedRectangle(cornerRadius: 7))
}

struct AlbumView: View {
    let id: UUID
    @Binding var path: [Route]
    let upgrade: () -> Void
    @EnvironmentObject private var model: Model
    @EnvironmentObject private var purchases: Purchases
    @State private var byYear = false
    @State private var selecting = false
    @State private var selected = Set<UUID>()
    @State private var share: SharePayload?
    @State private var showDate = false
    @State private var cleanPDF = false
    @State private var hideMilestone = false
    @State private var sceneFilter: SceneTag?
    @State private var showColorBatch = false

    private var availableTags: [SceneTag] {
        SceneTag.allCases.filter { tag in model.photos(in: id).contains { $0.sceneTags?.contains(tag) == true } }
    }

    private var items: [Scan] {
        let photos = model.photos(in: id).filter { photo in
            sceneFilter.map { photo.sceneTags?.contains($0) == true } ?? true
        }
        return byYear ? photos.sorted {
            let aDate = $0.date?.date ?? .distantFuture, bDate = $1.date?.date ?? .distantFuture
            return aDate == bDate ? $0.created < $1.created : aDate < bDate
        } : photos
    }
    private var targets: [Scan] { selected.isEmpty ? items : items.filter { selected.contains($0.id) } }
    private var title: String { model.album(id)?.title ?? L.t("albums") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                albumSummary
                if model.colorBatch {
                    HStack {
                        ProgressView()
                        Button(L.t("cancel")) { model.cancelColorBatch() }.accessibilityIdentifier("cancel-color-batch")
                    }
                }
                if !availableTags.isEmpty || sceneFilter != nil {
                    Menu {
                        Button(L.t("all_scene_tags")) { sceneFilter = nil; selected.removeAll() }
                        ForEach(availableTags) { tag in
                            Button(tag.title) { sceneFilter = tag; selected.removeAll() }
                        }
                    } label: { Label(sceneFilter?.title ?? L.t("all_scene_tags"), systemImage: "line.3.horizontal.decrease.circle") }
                        .accessibilityIdentifier("filter-scene-tags")
                }
                if !items.isEmpty, items.allSatisfy({ !$0.needsDate }), !hideMilestone { finishedCard }
                if items.isEmpty { Text(L.t("empty_album")).foregroundStyle(Paper.secondary).padding(.vertical, 20) }
                LazyVGrid(columns: photoColumns, spacing: 6) {
                    ForEach(items) { item in
                        Button {
                            if selecting {
                                if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
                            } else { path.append(.detail(item.id)) }
                        } label: {
                            tile(item, archive: model.archive).overlay(alignment: .bottomTrailing) {
                                if selecting {
                                    Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.title3).foregroundStyle(.white).padding(8).shadow(radius: 3)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.date?.label ?? L.t("undated"))
                        .accessibilityIdentifier("photo-tile")
                    }
                }
            }.padding(18)
        }
        .background(Paper.background.ignoresSafeArea()).foregroundStyle(Paper.ink)
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(L.t(byYear ? "sort_scan" : "sort_year"), systemImage: "arrow.up.arrow.down") { byYear.toggle() }
                    Button(L.t(selecting ? "done" : "select_photos"), systemImage: "checkmark.circle") {
                        selecting.toggle(); selected.removeAll()
                    }.disabled(items.isEmpty)
                    Button(L.t("family_title"), systemImage: "person.2") { path.append(.family(id)) }
                    Button(L.t("restore_all"), systemImage: "wand.and.stars") {
                        premium { Task { await model.batchRestore(targets.map(\.id)) } }
                    }.disabled(items.isEmpty || model.busy)
                    if DDColorRenderer.isBundled {
                        Button(L.t("colorize_batch_action"), systemImage: "paintpalette") {
                            premium { showColorBatch = true }
                        }.disabled(items.isEmpty || model.busy || model.enhancing || model.colorBatch)
                    }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel(L.t("album_actions"))
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                if selecting { Text(L.f("photo_count", String(selected.count))).font(.caption) }
                Spacer()
                batchMenu
            }.padding(.horizontal, 18).padding(.vertical, 12).background(Paper.background)
        }
        .sheet(item: $share) { SharePresentation(payload: $0) }
        .confirmationDialog(L.t("colorize_batch"), isPresented: $showColorBatch, titleVisibility: .visible) {
            Button(L.t("colorize_batch_action")) { model.startColorBatch(targets.map(\.id)) }
        } message: { Text(L.t("colorize_disclaimer")) }
        .onDisappear { model.cancelColorBatch() }
        .sheet(isPresented: $showDate) {
            DateEditor(initial: nil) { date in
                guard purchases.hasPro else { return }
                for item in targets { model.update(item.id) { $0.date = date; $0.suggestedDate = nil } }
            }
        }
    }

    private var albumSummary: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L.f("photo_count", String(items.count))).font(.system(.title, design: .serif))
            Text(L.f("album_progress", String(items.filter { $0.strength > 0 || $0.glareReduced }.count),
                     String(items.filter(\.saved).count))).font(.footnote).foregroundStyle(Paper.secondary)
            TimelineStrip(scans: items)
        }.padding(15).modifier(PaperCard())
    }

    private var finishedCard: some View {
        HStack {
            Button(L.t("album_finished")) {
                let images = items.prefix(9).compactMap { item in model.archive.flatMap { ArchiveImage.read($0.thumbnail(item), limit: 400) } }
                if let card = Cards.occasion(title: title, subtitle: L.t("album_finished"), images: images) {
                    share = SharePayload(content: [card], card: card)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { hideMilestone = true } label: { Image(systemName: "xmark").padding(6) }
                .accessibilityLabel(L.t("dismiss"))
        }.padding(10).modifier(PaperCard())
    }

    private var batchMenu: some View {
        Menu {
            Button(L.t("export_full"), systemImage: "square.and.arrow.up") { shareFiles() }
            Button(L.t("save_photos"), systemImage: "arrow.down.to.line") { model.enqueueSave(targets) }
            Button(L.t("export_pdf"), systemImage: "doc.richtext") { exportPDF(branded: true) }
            if !Launch.freePeriod {
                Button(L.t("export_clean_pdf"), systemImage: "doc") { premium { exportPDF(branded: false) } }
            } else {
                Button(L.t("export_clean_pdf"), systemImage: "doc") { exportPDF(branded: false) }
            }
            Button(L.t("batch_date"), systemImage: "calendar") { premium { showDate = true } }
            let others = model.albums.filter { $0.id != id }
            if !others.isEmpty {
                Menu(L.t("move_album"), systemImage: "folder") {
                    ForEach(others) { album in
                        Button(album.title) { premium { for item in targets { model.update(item.id) { $0.albumID = album.id } }; selected.removeAll() } }
                    }
                }
            }
        } label: {
            Label(L.t("album_actions"), systemImage: "ellipsis").font(.subheadline.weight(.semibold)).frame(minHeight: 32)
        }.disabled(targets.isEmpty || model.busy)
    }

    private func premium(_ action: () -> Void) { if purchases.hasPro { action() } else { upgrade() } }

    private func shareFiles() {
        guard let archive = model.archive else { return }
        let photos = targets
        Task {
            do {
                let files = try await model.work {
                    var output: [URL] = []
                    do { for item in photos { output.append(try archive.export(item, original: false)) } }
                    catch { for file in output { try? FileManager.default.removeItem(at: file) }; throw error }
                    return output
                }
                share = SharePayload(content: files, cleanup: files)
            } catch { model.message = L.t("export_error") }
        }
    }

    private func exportPDF(branded: Bool) {
        guard let archive = model.archive else { return }
        let photos = targets, name = title
        Task {
            do {
                let url = try await model.work { try AlbumPDF.write(photos, title: name, archive: archive, branded: branded) }
                share = SharePayload(content: [url], cleanup: [url])
            } catch { model.message = L.t("export_error") }
        }
    }
}
