import SwiftUI

struct RecognitionPanel: View {
    let item: Scan
    let archive: Archive
    let upgrade: () -> Void
    @EnvironmentObject private var model: Model
    @EnvironmentObject private var purchases: Purchases
    @State private var naming: PhotoFace?
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(L.t("recognize_photo"), systemImage: "viewfinder") {
                if purchases.hasPro { Task { await model.recognizeFront(item.id) } }
                else { upgrade() }
            }.accessibilityIdentifier("recognize-photo").disabled(model.busy || model.recognizing.contains(item.id))
            ForEach(item.sceneTags ?? []) { tag in
                HStack {
                    Label(tag.title, systemImage: "tag").accessibilityIdentifier("scene-tag")
                    Spacer()
                    Button {
                        model.update(item.id) { $0.sceneTags?.removeAll { $0 == tag } }
                    } label: {
                        Image(systemName: "xmark.circle").frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel(L.f("remove_scene_tag", tag.title)).accessibilityIdentifier("remove-scene-tag")
                }
            }
            if let faces = item.faces, !faces.isEmpty {
                Text(L.t("name_faces")).font(.subheadline.weight(.semibold))
                GeometryReader { proxy in
                    let aspect = CGFloat(max(1, item.width)) / CGFloat(max(1, item.height))
                    let width = min(proxy.size.width, proxy.size.height * aspect)
                    let height = width / aspect
                    ZStack(alignment: .topLeading) {
                        ArchiveImage(url: archive.original(item), limit: 920, mode: .fit)
                            .frame(width: width, height: height)
                        ForEach(faces) { face in
                            Button {
                                if purchases.hasPro { naming = face; name = face.name }
                                else { upgrade() }
                            } label: {
                                RoundedRectangle(cornerRadius: 4).strokeBorder(.white, lineWidth: 2)
                                    .background(.black.opacity(0.17), in: RoundedRectangle(cornerRadius: 4))
                                    .overlay { Text(face.name).font(.caption2.bold()).lineLimit(1).foregroundStyle(.white) }
                                    .frame(width: max(32, face.rect.width * width), height: max(32, face.rect.height * height))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .position(x: face.rect.midX * width, y: face.rect.midY * height)
                                .accessibilityLabel(face.name.isEmpty ? L.t("name_faces") : face.name)
                                .accessibilityIdentifier("name-face")
                        }
                    }.frame(width: width, height: height).frame(maxWidth: .infinity, maxHeight: .infinity)
                }.frame(height: 180)
            }
        }.padding(12).modifier(PaperCard())
            .alert(L.t("name_faces"), isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
                TextField(L.t("people"), text: $name).accessibilityIdentifier("face-name-field")
                Button(L.t("save")) {
                    guard let face = naming else { return }
                    let value = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
                    model.update(item.id) { scan in
                        guard let index = scan.faces?.firstIndex(where: { $0.id == face.id }) else { return }
                        scan.faces?[index].name = value
                    }
                    naming = nil
                }
                Button(L.t("cancel"), role: .cancel) { naming = nil }
            }
    }
}

struct PeopleView: View {
    @EnvironmentObject private var model: Model
    @Binding var path: [Route]

    var body: some View {
        let named = model.scans.flatMap { scan in
            (scan.faces ?? []).filter { !$0.name.isEmpty }.map { (face: $0, scan: scan) }
        }
        let groups = Dictionary(grouping: named) { $0.face.group }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if groups.isEmpty { Text(L.t("name_faces")).foregroundStyle(Paper.secondary) }
                ForEach(groups.keys.sorted(), id: \.self) { key in
                    if let entries = groups[key], let first = entries.first {
                        Text(first.face.name).font(.headline).accessibilityIdentifier("person-group")
                        let ids = Set(entries.map { $0.scan.id })
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3)) {
                            ForEach(model.scans.filter { ids.contains($0.id) }) { scan in
                                Button { path.append(.detail(scan.id)) } label: {
                                    ArchiveImage(url: model.archive?.thumbnail(scan)).frame(height: 100)
                                        .clipShape(RoundedRectangle(cornerRadius: 7))
                                }.buttonStyle(.plain).accessibilityLabel(L.t("scan")).accessibilityIdentifier("person-photo")
                            }
                        }
                    }
                }
            }.padding(16)
        }.navigationTitle(L.t("people")).background(Paper.background.ignoresSafeArea())
    }
}
