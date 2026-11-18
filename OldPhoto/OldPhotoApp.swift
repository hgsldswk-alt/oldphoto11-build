import StoreKit
import SwiftUI

enum Route: Hashable {
    case library, album(UUID), detail(UUID), timeline, settings, family(UUID?), people
}

@main
@MainActor
struct OldPhotoApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.purchases)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: Model
    @EnvironmentObject private var purchases: Purchases
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var review
    @State private var path: [Route] = []
    @State private var paywall = false
    @State private var prepared = false
    @State private var showNotice = false

    var body: some View {
        NavigationStack(path: $path) {
            FinderView(active: path.isEmpty && prepared && !paywall && scenePhase == .active,
                       open: { path.append($0) }, upgrade: { paywall = true })
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .library: LibraryView(path: $path)
                    case .album(let id): AlbumView(id: id, path: $path, upgrade: { paywall = true })
                    case .detail(let id): DetailView(id: id, upgrade: { paywall = true })
                    case .timeline: TimelineView(path: $path)
                    case .people: PeopleView(path: $path)
                    case .settings: SettingsView(upgrade: { paywall = true }, family: { path.append(.family(nil)) })
                    case .family(let id): FamilyView(albumID: id, upgrade: { paywall = true })
                    }
                }
        }
        .tint(Paper.accent)
        .sheet(isPresented: $paywall) { PaywallView() }
        .overlay(alignment: .top) {
            if showNotice, !model.message.isEmpty, !path.isEmpty {
                Text(model.message).font(.footnote.weight(.semibold)).padding(.vertical, 9).padding(.horizontal, 14)
                    .foregroundStyle(Paper.ink).background(.regularMaterial, in: Capsule())
                    .padding(.horizontal, 12).padding(.top, 48)
                    .accessibilityIdentifier("notice")
                    .allowsHitTesting(false)
            }
        }
        .task {
            await model.prepare()
            if Launch.demo, let first = model.scans.first {
                if Launch.has("-shot-library") { path = [.library] }
                if Launch.has("-shot-detail") || Launch.has("-shot-share") { path = [.detail(first.id)] }
                if Launch.has("-shot-timeline") { path = [.timeline] }
                if Launch.has("-paywall") { paywall = true }
            }
            prepared = true
            await purchases.start()
        }
        .onChange(of: scenePhase) { _, value in
            if value == .active { Task { await purchases.refresh() } }
        }
        .onChange(of: path) {
            if !path.isEmpty { model.expiryNotice(); requestReviewIfReady() }
        }
        .onChange(of: model.reviewReady) { _, ready in
            if ready, !path.isEmpty { requestReviewIfReady() }
        }
        .task(id: model.message) {
            guard !model.message.isEmpty else { return }
            showNotice = true
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { showNotice = false }
        }
    }

    private func requestReviewIfReady() {
        guard model.reviewReady, !paywall, scenePhase == .active else { return }
        guard let route = path.last else { return }
        switch route {
        case .library, .album: break
        default: return
        }
        model.dismissReview()
        review()
    }
}
