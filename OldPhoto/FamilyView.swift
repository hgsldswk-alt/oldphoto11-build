import SwiftUI
import UIKit

struct FamilyView: View {
    let albumID: UUID?
    let upgrade: () -> Void
    @EnvironmentObject private var model: Model
    @EnvironmentObject private var purchases: Purchases
    @State private var input = ""
    @State private var code: FamilyCode?
    @State private var outgoing = ""
    @State private var status = ""
    @State private var share: SharePayload?
    @State private var datingID: UUID?
    @State private var dateSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                Text(L.t("family_intro")).font(.subheadline).foregroundStyle(Paper.secondary)
                if let albumID {
                    Button(L.t("make_family_code"), systemImage: "person.2") {
                        if purchases.hasPro { generate(albumID) } else { upgrade() }
                    }.buttonStyle(ActionStyle()).disabled(model.photos(in: albumID).allSatisfy { !$0.needsDate })
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L.t("family_paste")).font(.headline)
                    TextField(L.t("family_enter"), text: $input, axis: .vertical)
                        .lineLimit(2...5).textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(L.t("open_code")) { readCode() }.buttonStyle(.bordered).disabled(input.isEmpty)
                }.padding(13).modifier(PaperCard())
                if let code {
                    if code.reply { replyReview(code) } else { questions(code) }
                }
                if !outgoing.isEmpty {
                    Button(L.t("copy_code"), systemImage: "doc.on.doc") {
                        if !Launch.isolated { UIPasteboard.general.string = outgoing }
                        status = L.t("code_copied")
                    }.buttonStyle(.bordered)
                }
                if !status.isEmpty { Text(status).font(.footnote).foregroundStyle(Paper.secondary) }
            }.padding(18)
        }
        .foregroundStyle(Paper.ink).background(Paper.background.ignoresSafeArea())
        .navigationTitle(L.t("family_title")).navigationBarTitleDisplayMode(.inline)
        .sheet(item: $share) { SharePresentation(payload: $0) }
        .sheet(isPresented: $dateSheet) {
            DateEditor(initial: code?.entries.first(where: { $0.id == datingID })?.date) { date in
                if let index = code?.entries.firstIndex(where: { $0.id == datingID }) { code?.entries[index].date = date }
            }
        }
    }

    private func readCode() {
        do {
            let incoming = try FamilyCode.decode(input)
            if incoming.reply && !incoming.entries.contains(where: { model.scan($0.id) != nil }) { throw ScanError.invalidCode }
            code = incoming
            outgoing = ""
            status = ""
        } catch { status = L.t("invalid_code") }
    }

    private func generate(_ album: UUID) {
        let photos = Array(model.photos(in: album).filter(\.needsDate).prefix(9))
        guard !photos.isEmpty else { return }
        do {
            let request = FamilyCode(entries: photos.map { FamilyCode.Entry(id: $0.id) })
            outgoing = try request.encode()
            let images = photos.compactMap { item in model.archive.flatMap { ArchiveImage.read($0.thumbnail(item), limit: 400) } }
            let card = Cards.occasion(title: L.t("family_question"), subtitle: L.t("family_share_hint"), images: images)
            share = SharePayload(content: card.map { [$0 as Any, outgoing as Any] } ?? [outgoing], card: card)
        } catch { status = L.t("export_error") }
    }

    private func questions(_ request: FamilyCode) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            ForEach(request.entries) { entry in
                let index = (request.entries.firstIndex { $0.id == entry.id } ?? 0) + 1
                VStack(alignment: .leading, spacing: 5) {
                    Text(L.f("photo_number", String(index))).font(.headline)
                    Button(entry.date?.label ?? L.t("date")) { datingID = entry.id; dateSheet = true }
                    TextField(L.t("people"), text: entryBinding(entry.id, \.people)).textFieldStyle(.roundedBorder)
                    TextField(L.t("place"), text: entryBinding(entry.id, \.place)).textFieldStyle(.roundedBorder)
                }.padding(10).modifier(PaperCard())
            }
            Button(L.t("share_reply")) {
                var reply = request
                reply.reply = true
                if let value = try? reply.encode() {
                    outgoing = value
                    share = SharePayload(content: [value])
                }
            }.buttonStyle(ActionStyle())
        }
    }

    private func entryBinding(_ id: UUID, _ key: WritableKeyPath<FamilyCode.Entry, String>) -> Binding<String> {
        Binding {
            code?.entries.first(where: { $0.id == id })?[keyPath: key] ?? ""
        } set: { value in
            if let index = code?.entries.firstIndex(where: { $0.id == id }) { code?.entries[index][keyPath: key] = String(value.prefix(300)) }
        }
    }

    private func replyReview(_ reply: FamilyCode) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(reply.entries.filter { model.scan($0.id) != nil }) { entry in
                let values = [entry.date?.label ?? "", entry.people, entry.place].filter { !$0.isEmpty }
                if !values.isEmpty { Text(values.joined(separator: " · ")).font(.callout) }
            }
            Button(L.t("merge_reply")) {
                for entry in reply.entries {
                    model.update(entry.id) {
                        if $0.date == nil, let date = entry.date { $0.date = date; $0.suggestedDate = nil }
                        if $0.people.isEmpty { $0.people = entry.people }
                        if $0.place == nil, !entry.place.isEmpty { $0.place = Place(name: entry.place) }
                    }
                }
                status = L.t("reply_merged")
            }.buttonStyle(.bordered)
        }.padding(12).modifier(PaperCard())
    }
}
