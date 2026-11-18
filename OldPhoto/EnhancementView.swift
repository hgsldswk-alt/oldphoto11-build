import SwiftUI

struct EnhancementPanel: View {
    let item: Scan
    let archive: Archive
    let upgrade: () -> Void
    @EnvironmentObject private var model: Model
    @EnvironmentObject private var purchases: Purchases
    @State private var kind: EnhancementKind = .clarity
    @State private var strength = Double(EnhancementKind.clarity.defaultStrength)
    @State private var job: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Button(EnhancementKind.clarity.title) { select(.clarity) }.accessibilityIdentifier("select-clarity")
                if item.colorizable == true || item.enhancement?.kind == .colorize {
                    Button(EnhancementKind.colorize.title) { select(.colorize) }.accessibilityIdentifier("select-colorize")
                }
            }.buttonStyle(.bordered)
            if kind == .colorize || item.enhancement?.kind == .colorize {
                Text(L.t("colorize_disclaimer")).font(.caption).foregroundStyle(Paper.secondary)
                    .accessibilityIdentifier("colorize-disclaimer")
            }
            if kind == .colorize && !DDColorRenderer.isBundled {
                Text(L.t("colorize_unavailable")).font(.caption).foregroundStyle(Paper.secondary)
                    .accessibilityIdentifier("colorize-unavailable")
            }
            HStack {
                Slider(value: $strength, in: 0...100, step: 1).accessibilityLabel(L.t("restore_strength"))
                    .accessibilityIdentifier("enhancement-strength")
                Text("\(Int(strength))%").font(.caption.monospacedDigit())
            }
            HStack {
                Button(L.t("enhance_apply")) {
                    if purchases.hasPro {
                        job = Task { await model.enhance(item.id, kind: kind, strength: Int(strength)) }
                    } else { upgrade() }
                }.accessibilityIdentifier("apply-enhancement")
                    .disabled(kind == .colorize && (!DDColorRenderer.isBundled || item.colorizable != true))
                if item.enhancement != nil {
                    Spacer()
                    Button(L.t("enhance_undo")) { model.undoEnhancement(item.id) }.accessibilityIdentifier("undo-enhancement")
                }
            }
            if item.enhancement != nil, archive.result(item) == archive.baseResult(item) {
                Button(L.t("enhance_replay")) {
                    if purchases.hasPro { job = Task { await model.replayEnhancement(item.id) } }
                    else { upgrade() }
                }
            }
        }
        .padding(12).modifier(PaperCard()).disabled(model.busy || model.enhancing || model.colorBatch)
        .onChange(of: item.enhancement, initial: true) { _, edit in
            if let edit { select(edit.kind) }
        }
        .onChange(of: item.revision) { if item.colorizable != true && kind == .colorize { select(.clarity) } }
        .task(id: item.revision) {
            guard item.colorizable == nil, DDColorRenderer.isBundled, !Launch.isolated else { return }
            await model.checkColorEligibility(item.id)
        }
        .onDisappear { job?.cancel() }
    }

    private func select(_ selection: EnhancementKind) {
        kind = selection
        strength = Double(item.enhancement.flatMap { $0.kind == selection ? $0.strength : nil } ?? selection.defaultStrength)
    }
}
