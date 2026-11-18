import Combine
import Foundation
import Security
import StoreKit

struct Access: Equatable {
    var started: Date
    var credential: Date?
    var bought = false
    var trialStart: Date { min(started, credential ?? started) }
    var trialEnd: Date { trialStart.addingTimeInterval(30 * 86_400) }
    func hasPro(at time: Date) -> Bool { Launch.freePeriod || bought || time < trialEnd }
    func days(at time: Date) -> Int { Int(max(0, min(30, ceil(trialEnd.timeIntervalSince(time) / 86_400)))) }
}

@MainActor
final class Purchases: ObservableObject {
    static let pro = "com.hgsldswk.oldphoto.pro"
    static let trial = "com.hgsldswk.oldphoto.trial"
    @Published private(set) var access: Access
    @Published private(set) var products: [Product] = []
    @Published private(set) var working = false
    @Published var feedback = ""
    @Published private(set) var now = Date()
    private var updates: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    init() {
        if Launch.isolated || Launch.freePeriod {
            let start = Launch.has("-expired") ? Date().addingTimeInterval(-31 * 86_400) : Date()
            access = Access(started: start)
        } else {
            let cached = TrialDates.read("start")
            let defaults = UserDefaults.standard
            let local = defaults.object(forKey: "paid-start") as? Date
            let start = [cached, local].compactMap { $0 }.min() ?? Date()
            defaults.set(start, forKey: "paid-start")
            TrialDates.store(start, key: "start")
            access = Access(started: start, credential: TrialDates.read("credential"))
        }
    }
    deinit { updates?.cancel(); timer?.cancel() }

    var hasPro: Bool { access.hasPro(at: Date()) }
    var days: Int { access.days(at: now) }
    var demoPrice: String? {
        guard Launch.demo else { return nil }
        return Locale.current.region?.identifier == "CN" ? "¥30" : "$5.99"
    }
    func product(_ id: String) -> Product? { products.first { $0.id == id } }

    func start() async {
        guard !Launch.isolated, !Launch.freePeriod else { return }
        if updates == nil {
            updates = Task { [weak self] in
                for await update in Transaction.updates {
                    guard let self, !Task.isCancelled else { return }
                    if case .verified(let transaction) = update, Self.accepted(transaction.productID) {
                        await self.refresh()
                        await transaction.finish()
                    }
                }
            }
        }
        if timer == nil {
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { return }
                    self?.now = Date()
                }
            }
        }
        await refresh()
    }

    private static func accepted(_ id: String) -> Bool { id == pro || id == trial }

    func load() async {
        guard !Launch.isolated, !Launch.freePeriod, !working else { return }
        working = true
        defer { working = false }
        do {
            products = try await Product.products(for: [Self.pro, Self.trial])
            feedback = products.isEmpty ? L.t("store_unavailable") : ""
        } catch { feedback = L.t("store_unavailable") }
    }

    func purchase(_ id: String) async {
        guard !working, !Launch.isolated, !Launch.freePeriod, let product = product(id) else { return }
        working = true
        feedback = ""
        defer { working = false }
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                if transaction.productID == Self.trial { recordCredential(transaction.originalPurchaseDate) }
                await refresh()
                if transaction.productID == Self.pro, transaction.revocationDate == nil { access.bought = true }
                await transaction.finish()
                feedback = L.t(transaction.productID == Self.pro ? "purchase_done" : "credential_done")
            case .success(.unverified): feedback = L.t("purchase_verify")
            case .pending: feedback = L.t("purchase_pending")
            case .userCancelled: break
            @unknown default: break
            }
        } catch { feedback = L.t("purchase_error") }
    }

    func restore() async {
        guard !working, !Launch.isolated, !Launch.freePeriod else { return }
        working = true
        feedback = ""
        defer { working = false }
        do {
            try await AppStore.sync()
            await refresh()
            feedback = access.bought || access.credential != nil ? L.t("purchase_restored") : L.t("purchase_none")
        } catch { feedback = L.t("purchase_error") }
    }

    func refresh() async {
        guard !Launch.isolated, !Launch.freePeriod else { return }
        var unlocked = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil else { continue }
            if transaction.productID == Self.pro { unlocked = true }
            if transaction.productID == Self.trial { recordCredential(transaction.originalPurchaseDate) }
        }
        access.bought = unlocked
        now = Date()
    }

    private func recordCredential(_ date: Date) {
        let earliest = min(date, access.credential ?? date)
        access.credential = earliest
        TrialDates.store(earliest, key: "credential")
    }
}

private enum TrialDates {
    static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.hgsldswk.oldphoto.access",
         kSecAttrAccount as String: key]
    }
    static func read(_ key: String) -> Date? {
        var attrs = query(key)
        attrs[kSecReturnData as String] = true
        attrs[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(attrs as CFDictionary, &result) == errSecSuccess,
              let bytes = result as? Data,
              let seconds = Double(String(decoding: bytes, as: UTF8.self)), seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
    static func store(_ date: Date, key: String) {
        let bytes = Data(String(date.timeIntervalSince1970).utf8)
        var attrs = query(key)
        let value = [kSecValueData as String: bytes]
        if SecItemUpdate(attrs as CFDictionary, value as CFDictionary) == errSecItemNotFound {
            attrs[kSecValueData as String] = bytes
            attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(attrs as CFDictionary, nil)
        }
    }
}
