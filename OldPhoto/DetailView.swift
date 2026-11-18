import AVFoundation
import PhotosUI
import SwiftUI

struct DetailView: View {
    let id: UUID
    let upgrade: () -> Void
    @EnvironmentObject private var model: Model
    @EnvironmentObject private var purchases: Purchases
    @Environment(\.dismiss) private var dismiss
    @State private var share: SharePayload?
    @State private var editor: Editor?
    @State private var position = 0.50
    @State private var originalOnly = false
    @State private var strength = 0.0
    @State private var showPhotoActions = false
    @State private var selectedPhotoAction: PhotoAction?
    @State private var confirmDelete = false
    @State private var sharing = false
    @State private var renderedDemo = false
    @State private var editCopy: UUID?

    private enum Editor: String, Identifiable {
        case corners, date, place, people, note, back
        var id: String { rawValue }
    }

    private enum PhotoAction {
        case exportFull, exportOriginal, exportPage, shareClean, delete
    }

    var body: some View {
        Group {
            if let item = model.scan(editCopy ?? id), let archive = model.archive {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 12) {
                            comparator(item, archive: archive)
                            restorePanel(item)
                            EnhancementPanel(item: item, archive: archive, upgrade: upgrade)
                            info(item)
                            RecognitionPanel(item: item, archive: archive, upgrade: upgrade)
                        }.padding(.horizontal, 16).padding(.vertical, 8)
                    }
                    footer(item)
                }
                .navigationTitle(title(item)).navigationBarTitleDisplayMode(.inline)
                .sheet(item: $editor) { current in editorView(current, item: item, archive: archive) }
                .sheet(item: $share) { SharePresentation(payload: $0) }
                .sheet(isPresented: $showPhotoActions, onDismiss: { performPhotoAction(item, archive: archive) }) {
                    photoActionsSheet
                }
                .confirmationDialog(L.t("delete_title"), isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button(L.t("delete"), role: .destructive) {
                        model.delete(item.id)
                        if model.scan(item.id) == nil { dismiss() }
                    }
                } message: { Text(L.t("delete_message")) }
                .onChange(of: item.strength, initial: true) { _, value in strength = value }
                .task {
                    if Launch.has("-shot-share"), !renderedDemo {
                        renderedDemo = true
                        comparison(item, archive: archive)
                    }
                }
            } else {
                ContentUnavailableView(L.t("missing_scan"), systemImage: "photo")
            }
        }
        .foregroundStyle(Paper.ink).background(Paper.background.ignoresSafeArea())
    }

    private func title(_ item: Scan) -> String {
        let list = model.photos(in: item.albumID)
        let index = (list.firstIndex { $0.id == item.id } ?? 0) + 1
        let name = model.album(item.albumID)?.title ?? L.t("library")
        return "\(name) · \(index) / \(list.count)"
    }

    private func comparator(_ item: Scan, archive: Archive) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width, height = proxy.size.height
            ZStack {
                Paper.line
                ArchiveImage(url: archive.result(item), limit: 1360, mode: .fit)
                ArchiveImage(url: archive.original(item), limit: 1360, mode: .fit)
                    .mask(alignment: .leading) { Rectangle().frame(width: originalOnly ? width : width * position) }
                if !originalOnly {
                    Rectangle().fill(.white).frame(width: 2, height: height).position(x: width * position, y: height / 2)
                    Image(systemName: "arrow.left.and.right").font(.caption.bold())
                        .foregroundStyle(Color(hex: 0x221E1A))
                        .frame(width: 34, height: 34).background(.white, in: Circle()).shadow(radius: 4, y: 1)
                        .position(x: width * position, y: height / 2)
                }
                VStack {
                    Spacer()
                    HStack {
                        imageLabel("original")
                        Spacer()
                        if !originalOnly {
                            let edit = archive.result(item) == archive.baseResult(item) ? nil : item.enhancement
                            imageLabel(edit.map { "enhance_" + $0.kind.rawValue } ??
                                       ((item.unenhanced != true && (item.strength > 0 || item.glareReduced)) ? "restored" : "scan"))
                        }
                    }.padding(9)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4).onChanged { value in
                originalOnly = false
                position = max(0.04, min(0.96, value.location.x / max(1, width)))
            })
        }
        .frame(height: 285)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Paper.line, lineWidth: 1).allowsHitTesting(false) }
        .accessibilityLabel(L.t("comparison"))
        .accessibilityIdentifier("comparison")
        .accessibilityAdjustableAction { direction in
            originalOnly = false
            if direction == .increment { position = min(0.96, position + 0.1) }
            if direction == .decrement { position = max(0.04, position - 0.1) }
        }
    }

    private func imageLabel(_ key: String) -> some View {
        Text(L.t(key)).font(.caption2.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 4)
            .background(.black.opacity(0.5), in: Capsule()).foregroundStyle(.white)
    }

    private func restorePanel(_ item: Scan) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(L.t("fade_restore")).font(.headline)
                Spacer()
                Text(strength, format: .percent.precision(.fractionLength(0))).font(.subheadline.bold())
                    .monospacedDigit().foregroundStyle(Paper.accent)
            }
            if purchases.hasPro {
                Slider(value: $strength, in: 0...1, step: 0.05) { editing in
                    if !editing, abs(strength - item.strength) > 0.001 {
                        Task { await model.recrop(item.id, strength: strength) }
                    }
                }.accessibilityLabel(L.t("restore_strength")).accessibilityIdentifier("strength")
            } else {
                Button(L.t("upgrade"), systemImage: "lock") { upgrade() }.font(.subheadline)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    Button(L.t(originalOnly ? "show_comparison" : "show_original")) { originalOnly.toggle() }
                        .accessibilityIdentifier("toggle-original")
                    Button(L.t(item.whiteBorder ? "trim_border" : "keep_border")) {
                        Task { editCopy = await model.recrop(item.id, border: !item.whiteBorder) ?? editCopy }
                    }
                    Button(L.t("edit_frame")) { editor = .corners }.accessibilityIdentifier("edit-frame")
                    Button(L.t("rotate")) { Task { editCopy = await model.recrop(item.id, rotation: (item.rotation + 1) % 4) ?? editCopy } }
                }.buttonStyle(.bordered).font(.caption)
            }.scrollIndicators(.hidden)
            Label("\(item.width) × \(item.height)", systemImage: "viewfinder")
                .font(.caption2).monospacedDigit().foregroundStyle(Paper.secondary)
        }.padding(13).modifier(PaperCard()).disabled(model.busy)
    }

    private func info(_ item: Scan) -> some View {
        VStack(spacing: 0) {
            if let suggested = item.suggestedDate, item.date == nil {
                Button {
                    premium { model.update(item.id) { if $0.date == nil { $0.date = suggested; $0.suggestedDate = nil } } }
                } label: {
                    infoRow("date", value: suggested.label, hint: "confirm_ocr")
                }.accessibilityIdentifier("confirm-year")
            } else {
                Button { premium { editor = .date } } label: { infoRow("date", value: item.date?.label ?? "") }
                    .accessibilityIdentifier("edit-date")
            }
            Divider()
            Button { premium { editor = .place } } label: { infoRow("place", value: item.place?.name ?? "") }
            Divider()
            Button { premium { editor = .people } } label: { infoRow("people", value: item.people) }
            Divider()
            Button { premium { editor = .note } } label: { infoRow("note", value: item.note) }
            Divider()
            Button { premium { editor = .back } } label: {
                Label(L.t("scan_back"), systemImage: "text.viewfinder").font(.subheadline.weight(.semibold))
                    .foregroundStyle(Paper.accent).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }.accessibilityIdentifier("scan-back")
        }.buttonStyle(.plain).modifier(PaperCard()).disabled(model.busy)
    }

    private func infoRow(_ key: String, value: String, hint: String? = nil) -> some View {
        HStack(spacing: 10) {
            Text(L.t(key)).foregroundStyle(Paper.secondary).frame(width: 52, alignment: .leading)
            Text(value.isEmpty ? L.t("add_info") : value).lineLimit(1)
                .foregroundStyle(value.isEmpty ? Paper.accent : Paper.ink)
            Spacer(minLength: 1)
            if let hint { Text(L.t(hint)).font(.caption2.weight(.medium)).foregroundStyle(Paper.accent) }
            else { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Paper.secondary) }
        }.font(.subheadline).padding(.horizontal, 13).frame(minHeight: 42).contentShape(Rectangle())
    }

    private func footer(_ item: Scan) -> some View {
        HStack(spacing: 11) {
            Button {
                model.enqueueSave([item])
            } label: {
                Label(L.t(item.saved ? "photo_saved" : "save_photos"), systemImage: item.saved ? "checkmark" : "arrow.down.to.line")
                    .font(.caption.weight(.medium)).multilineTextAlignment(.leading).frame(minHeight: 44)
            }.disabled(item.saved)
            Spacer(minLength: 0)
            Button(L.t("share_comparison")) {
                if let archive = model.archive { comparison(item, archive: archive) }
            }
            .buttonStyle(ActionStyle()).frame(maxWidth: 210).disabled(sharing || model.busy)
            .accessibilityIdentifier("share-comparison")
            Button { showPhotoActions = true } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L.t("photo_actions"))
            .accessibilityIdentifier("detail-actions")
        }.padding(.horizontal, 16).padding(.vertical, 8).background(Paper.background)
    }

    private var photoActionsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    photoActionButton("export_full", icon: "square.and.arrow.up", action: .exportFull)
                        .accessibilityIdentifier("export-full")
                    photoActionButton("export_original", icon: "photo", action: .exportOriginal)
                    photoActionButton("export_page", icon: "rectangle.stack", action: .exportPage)
                    photoActionButton("share_clean", icon: "rectangle", action: .shareClean)
                    photoActionButton("delete", icon: "trash", action: .delete, role: .destructive)
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
            }
            .background(Paper.background)
            .navigationTitle(L.t("photo_actions")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.t("cancel")) { showPhotoActions = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func photoActionButton(_ key: String, icon: String, action: PhotoAction, role: ButtonRole? = nil) -> some View {
        Button(role: role) {
            selectedPhotoAction = action
            showPhotoActions = false
        } label: {
            Label(L.t(key), systemImage: icon)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Color.red : Paper.ink)
    }

    private func performPhotoAction(_ item: Scan, archive: Archive) {
        guard let action = selectedPhotoAction else { return }
        selectedPhotoAction = nil
        switch action {
        case .exportFull: export(item, original: false)
        case .exportOriginal: export(item, original: true)
        case .exportPage: exportPage(item)
        case .shareClean: premium { comparison(item, archive: archive, branded: false) }
        case .delete: confirmDelete = true
        }
    }

    @ViewBuilder private func editorView(_ editor: Editor, item: Scan, archive: Archive) -> some View {
        switch editor {
        case .corners: CropEditor(item: item, archive: archive) { editCopy = $0 }
        case .date: DateEditor(initial: item.date) { new in model.update(item.id) { $0.date = new; $0.suggestedDate = nil } }
        case .place: PlaceEditor(initial: item.place) { new in model.update(item.id) { $0.place = new } }
        case .people: TextEditorSheet(key: "people", value: item.people, suggestions: Array(Set(model.scans.map(\.people))).sorted()) { text in
            model.update(item.id) { $0.people = text }
        }
        case .note: TextEditorSheet(key: "note", value: item.note, suggestions: []) { text in model.update(item.id) { $0.note = text } }
        case .back: BackEditor(id: item.id)
        }
    }

    private func premium(_ action: () -> Void) { if purchases.hasPro { action() } else { upgrade() } }

    private func export(_ item: Scan, original: Bool) {
        guard let archive = model.archive else { return }
        Task {
            do {
                let url = try await model.work { try archive.export(item, original: original) }
                share = SharePayload(content: [url], cleanup: [url])
            } catch { model.message = L.t("export_error") }
        }
    }

    private func exportPage(_ item: Scan) {
        guard let archive = model.archive else { return }
        Task {
            do {
                let url = try await model.work { try archive.exportPage(item) }
                share = SharePayload(content: [url], cleanup: [url])
            } catch { model.message = L.t("export_error") }
        }
    }

    private func comparison(_ item: Scan, archive: Archive, branded: Bool = true) {
        guard !sharing else { return }
        sharing = true
        Task {
            defer { sharing = false }
            do {
                let images = try await model.work {
                    (ArchiveImage.read(archive.original(item), limit: 1300), ArchiveImage.read(archive.result(item), limit: 1300))
                }
                guard let before = images.0, let after = images.1,
                      let card = Cards.comparison(item: item, before: before, after: after, branded: branded) else {
                    throw ScanError.image
                }
                let words = L.t(item.enhancement?.kind == .colorize ? "colorize_disclaimer" :
                                (item.unenhanced != true && item.strength > 0 ? "compare_caption" : "scan_caption"))
                if !Launch.isolated { UIPasteboard.general.string = words }
                share = SharePayload(content: [card], card: card, copied: true)
                model.success()
            } catch { model.message = L.t("export_error") }
        }
    }
}
