import StoreKit
import SwiftUI

struct SettingsView: View {
    let upgrade: () -> Void
    let family: () -> Void
    @EnvironmentObject private var model: Model
    @EnvironmentObject private var purchases: Purchases
    @State private var share: SharePayload?

    var body: some View {
        Form {
            Section {
                Toggle(L.t("auto_capture"), isOn: $model.preferences.autoCapture)
                Toggle(L.t("auto_restore"), isOn: $model.preferences.autoRestore)
                Toggle(L.t("auto_save"), isOn: $model.preferences.autoSave)
            } footer: { Text(L.t("settings_storage")) }
            if !Launch.freePeriod {
                Section {
                    if purchases.access.bought { Label(L.t("pro_unlocked"), systemImage: "checkmark.seal") }
                    else {
                        Button { upgrade() } label: {
                            HStack {
                                Text(L.t("upgrade"))
                                Spacer()
                                if purchases.days > 0 { Text(L.f("days_left", String(purchases.days))).font(.footnote) }
                            }
                        }.accessibilityIdentifier("settings-upgrade")
                    }
                    Button(L.t("restore_purchase")) { Task { await purchases.restore() } }.disabled(purchases.working)
                    if !purchases.feedback.isEmpty { Text(purchases.feedback).font(.footnote).foregroundStyle(Paper.secondary) }
                }
            }
            Section {
                Button(L.t("family_paste"), systemImage: "person.2", action: family)
                Button(L.t("recommend"), systemImage: "square.and.arrow.up") {
                    let card = Cards.occasion(title: L.t("app_short"), subtitle: L.t("recommend_text"), images: [])
                    share = SharePayload(content: card.map { [$0 as Any, AppLinks.listing as Any] } ?? [AppLinks.listing], card: card)
                }
                Link(destination: AppLinks.review) { Label(L.t("rate"), systemImage: "star") }
                Link(destination: AppLinks.privacy) { Label(L.t("privacy"), systemImage: "lock") }
                Link(destination: AppLinks.help) { Label(L.t("help"), systemImage: "questionmark.circle") }
            }
        }
        .scrollContentBackground(.hidden).background(Paper.background.ignoresSafeArea())
        .navigationTitle(L.t("settings")).navigationBarTitleDisplayMode(.inline)
        .sheet(item: $share) { SharePresentation(payload: $0) }
    }
}

struct PaywallView: View {
    @EnvironmentObject private var purchases: Purchases
    @Environment(\.dismiss) private var dismiss
    private let features = ["pro_restore", "pro_glare", "pro_details", "pro_album"]
    private let icons = ["wand.and.stars", "sun.max", "text.viewfinder", "rectangle.stack"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(L.t("app_short"), systemImage: "photo.on.rectangle").font(.subheadline.weight(.semibold))
                            .foregroundStyle(Paper.accent)
                        Text(L.t("pro_title")).font(.system(size: 34, weight: .semibold, design: .serif))
                            .accessibilityIdentifier("paywall-title")
                        Text(L.t("trial_description")).font(.subheadline).foregroundStyle(Paper.secondary)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(features.indices, id: \.self) { index in
                            Label(L.t(features[index]), systemImage: icons[index]).font(.subheadline)
                        }
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading).modifier(PaperCard())
                    Text(L.t("always_free")).font(.callout.weight(.semibold))
                    if purchases.access.bought {
                        Label(L.t("pro_unlocked"), systemImage: "checkmark.seal").font(.headline).foregroundStyle(Paper.accent)
                    } else if let price = purchases.product(Purchases.pro)?.displayPrice ?? purchases.demoPrice {
                        Button(L.f("buy_price", price)) { Task { await purchases.purchase(Purchases.pro) } }
                            .buttonStyle(ActionStyle()).disabled(purchases.working)
                    } else if !purchases.working {
                        Button(L.t("reload_store")) { Task { await purchases.load() } }.buttonStyle(ActionStyle())
                    }
                    if purchases.days > 0, !purchases.access.bought, purchases.access.credential == nil,
                       purchases.product(Purchases.trial) != nil || Launch.demo {
                        Button(L.t("claim_trial")) { Task { await purchases.purchase(Purchases.trial) } }
                            .buttonStyle(.bordered).frame(maxWidth: .infinity).disabled(purchases.working)
                    }
                    if purchases.working { ProgressView().frame(maxWidth: .infinity) }
                    if !purchases.feedback.isEmpty { Text(purchases.feedback).font(.footnote).foregroundStyle(Paper.secondary) }
                    HStack(spacing: 14) {
                        Button(L.t("restore_purchase")) { Task { await purchases.restore() } }.disabled(purchases.working)
                        Spacer(minLength: 2)
                        Link(L.t("privacy"), destination: AppLinks.privacy)
                    }.font(.footnote)
                }.padding(22)
            }
            .foregroundStyle(Paper.ink).background(Paper.background.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.t("close")) { dismiss() }.accessibilityIdentifier("paywall-close")
                }
            }
        }
        .presentationDetents([.large])
        .task { await purchases.load() }
    }
}
