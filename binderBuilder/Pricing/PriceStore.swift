//
//  PriceStore.swift
//  binderBuilder
//
//  The UI's single source of truth for prices. Merges the live price_cache
//  (user.sqlite) over the bundled price_snapshot (catalog.sqlite), so the
//  app always shows the freshest number it has — offline included.
//
//  Refresh policy: TCGdex (tcgplayer + cardmarket sources) is stale after
//  24h, eBay after 6h. The eBay provider is engaged only when the user has
//  switched it on AND pasted credentials (SettingsStore.ebayConfigured).
//

import Foundation
import Observation
import os

@MainActor @Observable final class PriceStore {
    nonisolated static let tcgdexStaleness: TimeInterval = 24 * 60 * 60
    nonisolated static let ebayStaleness: TimeInterval = 6 * 60 * 60
    nonisolated static let maxConcurrentRefreshes = 4

    /// The sources each provider feeds, for staleness bookkeeping.
    nonisolated private static let tcgdexSources: Set<PriceQuote.Source> = [.tcgplayer, .cardmarket]
    nonisolated private static let ebaySources: Set<PriceQuote.Source> = [.ebayActive]

    @ObservationIgnored private let database: UserDatabase
    @ObservationIgnored private let catalog: (any CatalogReading)?
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let tcgdexProvider: any PriceProvider
    @ObservationIgnored private let ebayProvider: (any PriceProvider)?
    @ObservationIgnored private let now: @Sendable () -> Date

    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.aja.binderBuilder", category: "PriceStore")

    /// Merged quotes per card id, updated whenever quotes(for:) or a refresh
    /// runs. Observable surface for the UI.
    private(set) var latestQuotes: [String: [PriceQuote]] = [:]

    init(
        database: UserDatabase,
        catalog: (any CatalogReading)?,
        settings: SettingsStore,
        tcgdexProvider: any PriceProvider = TCGdexPriceProvider(),
        ebayProvider: (any PriceProvider)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.catalog = catalog
        self.settings = settings
        self.tcgdexProvider = tcgdexProvider
        self.ebayProvider = ebayProvider
        self.now = now
    }

    // MARK: - Reading

    /// Best-known quotes for a card: live cached quotes override the bundled
    /// snapshot per (source, variant); snapshot rows with no live
    /// counterpart still show (with their catalog build date).
    func quotes(for cardID: String) async -> [PriceQuote] {
        let cached = (try? database.cachedQuotes(for: cardID)) ?? []
        var bundled: [PriceQuote] = []
        if let catalog {
            bundled = (try? await catalog.bundledQuotes(for: cardID)) ?? []
        }
        let merged = Self.merge(cached: cached, bundled: bundled)
        latestQuotes[cardID] = merged
        return merged
    }

    nonisolated static func merge(cached: [PriceQuote], bundled: [PriceQuote]) -> [PriceQuote] {
        var byKey: [String: PriceQuote] = [:]
        for quote in bundled {
            byKey["\(quote.source.rawValue)|\(quote.variant.rawValue)"] = quote
        }
        for quote in cached {
            byKey["\(quote.source.rawValue)|\(quote.variant.rawValue)"] = quote
        }
        return byKey.values.sorted {
            ($0.source.rawValue, $0.variant.rawValue) < ($1.source.rawValue, $1.variant.rawValue)
        }
    }

    // MARK: - Refreshing

    /// Refetches any provider whose cached data for this card is stale,
    /// then republishes the merged quotes. Provider failures are logged and
    /// swallowed (the stale/bundled data keeps showing).
    func refreshIfStale(card: CardSummary) async {
        await refresh(
            card: card, provider: tcgdexProvider,
            sources: Self.tcgdexSources, staleness: Self.tcgdexStaleness)
        if settings.ebayConfigured, let ebayProvider {
            await refresh(
                card: card, provider: ebayProvider,
                sources: Self.ebaySources, staleness: Self.ebayStaleness)
        }
        _ = await quotes(for: card.id)
    }

    /// Foreground bulk refresh of every owned + slotted card, at most 4
    /// cards in flight at a time.
    func refreshOwnedAndSlotted(refs: [CardRef]) async {
        guard let catalog else { return }
        // Variants share a card-level price fetch; dedupe to card ids.
        var seen = Set<String>()
        let cardIDs = refs.map(\.cardID).filter { seen.insert($0).inserted }

        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func addNext() {
                guard next < cardIDs.count else { return }
                let cardID = cardIDs[next]
                next += 1
                group.addTask { [weak self] in
                    guard let detail = try? await catalog.card(id: cardID) else { return }
                    await self?.refreshIfStale(card: detail.summary)
                }
            }
            for _ in 0..<Self.maxConcurrentRefreshes { addNext() }
            while await group.next() != nil { addNext() }
        }
    }

    private func refresh(
        card: CardSummary,
        provider: any PriceProvider,
        sources: Set<PriceQuote.Source>,
        staleness: TimeInterval
    ) async {
        let lastFetch = sources
            .compactMap { try? database.lastPriceFetch(cardID: card.id, source: $0) }
            .max()
        if let lastFetch, now().timeIntervalSince(lastFetch) < staleness { return }

        do {
            let fresh = try await provider.quotes(for: card)
            try database.replacePriceCache(with: fresh, cardID: card.id, sources: sources)
        } catch PricingError.rateLimited {
            Self.logger.notice("\(provider.id, privacy: .public) rate-limited; skipping \(card.id, privacy: .public)")
        } catch {
            Self.logger.warning("price refresh (\(provider.id, privacy: .public)) failed for \(card.id, privacy: .public): \(String(describing: error))")
        }
    }
}
