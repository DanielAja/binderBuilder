//
//  AlertChecker.swift
//  binderBuilder
//
//  Runs the price-drop + new-release checks (free TCGdex, on-device). Invoked
//  when the app becomes active and from Settings' "Check now"; fires local
//  notifications. Trigger/diff logic is pure + unit-tested.
//

import Foundation
import OSLog

@MainActor
struct AlertChecker {
    let env: AppEnvironment
    private static let log = Logger(subsystem: "com.aja.binderBuilder", category: "AlertChecker")
    static let setsEndpoint = URL(string: "https://api.tcgdex.net/v2/en/sets")!

    // MARK: Pure logic

    static func isTriggered(kind: AlertKind, threshold: Double, baseline: Double?, price: Double) -> Bool {
        switch kind {
        case .belowTarget:
            return price <= threshold
        case .percentDrop:
            guard let baseline, baseline > 0 else { return false }
            return price <= baseline * (1 - threshold / 100)
        }
    }

    static func newSetIDs(remote: [String], known: Set<String>) -> [String] {
        remote.filter { !known.contains($0) }
    }

    // MARK: Checks

    func runAll() async {
        await checkPrices()
        await checkNewReleases()
    }

    func checkPrices() async {
        guard env.settings.priceAlertsEnabled, !env.alerts.all.isEmpty else { return }
        for alert in env.alerts.all {
            guard let price = await currentPrice(alert.ref) else { continue }
            guard Self.isTriggered(kind: alert.kind, threshold: alert.threshold,
                                   baseline: alert.baseline, price: price) else { continue }
            let name = (try? await env.catalog?.card(id: alert.ref.cardID))?.name ?? alert.ref.cardID
            NotificationService.fire(
                title: "Price drop",
                body: "\(name) is now \(price.formatted(.currency(code: "USD")))",
                id: "price-\(alert.id)")
            env.alerts.removeAlert(alert.ref)  // one-shot; user can re-arm
        }
    }

    func checkNewReleases() async {
        guard env.settings.newReleaseAlertsEnabled else { return }
        guard let remote = await fetchRemoteSetIDs() else { return }
        let known = env.userDatabase.knownSetIDs()
        let new = Self.newSetIDs(remote: remote, known: known)
        guard !new.isEmpty else { return }
        env.userDatabase.addKnownSets(new)
        // Don't notify on the first-ever seeding (no baseline yet).
        guard !known.isEmpty else { return }
        NotificationService.fire(
            title: "New set released",
            body: new.count == 1 ? "A new set just dropped!" : "\(new.count) new sets just dropped!",
            id: "release-\(new.sorted().joined(separator: "-").hashValue)")
    }

    // MARK: Helpers

    private func currentPrice(_ ref: CardRef) async -> Double? {
        let quotes = await env.prices.quotes(for: ref.cardID)
        if let market = quotes.first(where: { $0.source == .tcgplayer && $0.variant == ref.variant })?.market {
            return market
        }
        return (try? await env.catalog?.bundledMarket(for: [ref]))?[ref]
    }

    private func fetchRemoteSetIDs() async -> [String]? {
        struct SetBrief: Decodable { let id: String }
        do {
            let (data, _) = try await URLSession.shared.data(from: Self.setsEndpoint)
            return try JSONDecoder().decode([SetBrief].self, from: data).map(\.id)
        } catch {
            Self.log.error("set list fetch failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
