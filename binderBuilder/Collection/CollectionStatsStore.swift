//
//  CollectionStatsStore.swift
//  binderBuilder
//
//  Derived collection insights for the Home dashboard, Stats, and Browse set
//  completion: portfolio value (raw=market, graded=acquired/manual), totals,
//  per-set completion, rarity/type histograms, most-valuable + recent cards,
//  and a daily value trend. Recomputed on demand and whenever the collection
//  changes (CollectionStore.changeToken); aggregates run as a few indexed
//  catalog queries, so it stays cheap even for large collections.
//

import Foundation
import Observation
import os

nonisolated struct ValuedCard: Identifiable, Sendable {
    let card: CardSummary
    let value: Double
    var id: String { card.id }
}

nonisolated struct RecentCopy: Identifiable, Sendable {
    let card: CardSummary
    let copy: CardCopy
    var id: String { copy.id }
}

nonisolated struct SetProgress: Identifiable, Sendable {
    let setInfo: SetInfo
    let owned: Int
    let total: Int
    var id: String { setInfo.id }
    var fraction: Double { total > 0 ? min(1, Double(owned) / Double(total)) : 0 }
    var isComplete: Bool { total > 0 && owned >= total }
}

@MainActor @Observable final class CollectionStatsStore {
    private let catalog: (any CatalogReading)?
    private let collection: CollectionStore
    private let database: UserDatabase

    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.aja.binderBuilder", category: "Stats")

    private(set) var totalCopies = 0
    private(set) var distinctPrintings = 0
    private(set) var totalValue: Double = 0
    private(set) var rawValue: Double = 0
    private(set) var gradedValue: Double = 0
    private(set) var setsStarted = 0
    private(set) var setsCompleted = 0
    private(set) var setProgress: [SetProgress] = []          // started sets, most complete first
    private(set) var completionBySet: [String: SetProgress] = [:]
    private(set) var rarityCounts: [String: Int] = [:]
    private(set) var typeCounts: [String: Int] = [:]
    private(set) var topValuable: [ValuedCard] = []
    private(set) var recent: [RecentCopy] = []
    private(set) var trend: [Double] = []
    private(set) var isComputing = false
    private var lastToken = -1

    init(catalog: (any CatalogReading)?, collection: CollectionStore, database: UserDatabase) {
        self.catalog = catalog
        self.collection = collection
        self.database = database
    }

    /// Recomputes if the collection changed since the last run (or always when
    /// `force`). Safe to call from `.task`/`.onAppear`.
    func refreshIfNeeded(force: Bool = false) async {
        guard force || collection.changeToken != lastToken else { return }
        lastToken = collection.changeToken
        await refresh()
    }

    func refresh() async {
        isComputing = true
        defer { isComputing = false }

        let copiesByRef = collection.copiesByRef
        let refs = Array(copiesByRef.keys)
        let cardIDs = collection.ownedCardIDs()
        let market = (try? await catalog?.bundledMarket(for: refs)) ?? [:]

        // Value + per-printing totals.
        var raw = 0.0, graded = 0.0
        var printingValue: [CardRef: Double] = [:]
        for (ref, copies) in copiesByRef {
            let m = market[ref] ?? 0
            var v = 0.0
            for copy in copies {
                if copy.isGraded { let gv = copy.acquiredPrice ?? m; graded += gv; v += gv }
                else { raw += m; v += m }
            }
            printingValue[ref] = v
        }
        rawValue = raw; gradedValue = graded; totalValue = raw + graded
        totalCopies = collection.totalCopies
        distinctPrintings = collection.ownedCount

        // Set completion.
        let ownedBySet = (try? await catalog?.ownedCardCounts(forCardIDs: cardIDs)) ?? [:]
        let sets = (try? await catalog?.allSets()) ?? []
        var progress: [SetProgress] = []
        var byID: [String: SetProgress] = [:]
        var started = 0, completed = 0
        for set in sets {
            let owned = ownedBySet[set.id] ?? 0
            guard owned > 0 else { continue }
            let total = set.cardCountTotal ?? set.cardCountOfficial ?? 0
            let p = SetProgress(setInfo: set, owned: owned, total: total)
            progress.append(p); byID[set.id] = p
            started += 1
            if p.isComplete { completed += 1 }
        }
        setProgress = progress.sorted { $0.fraction > $1.fraction }
        completionBySet = byID
        setsStarted = started; setsCompleted = completed

        // Facets.
        let facets = (try? await catalog?.cardFacets(forCardIDs: cardIDs)) ?? (rarities: [:], types: [:])
        rarityCounts = facets.rarities
        typeCounts = facets.types

        // Most valuable printings (one batched summary lookup, not per-card).
        let topPairs = Array(printingValue.sorted { $0.value > $1.value }.prefix(6)).filter { $0.value > 0 }
        let topSummaries = await summaryMap(for: topPairs.map { $0.key.cardID })
        topValuable = topPairs.compactMap { pair in
            topSummaries[pair.key.cardID].map { ValuedCard(card: $0, value: pair.value) }
        }

        // Recent additions (one batched summary lookup).
        let recentCopies = Array(collection.allCopies().prefix(10))
        let recentSummaries = await summaryMap(for: recentCopies.map { $0.ref.cardID })
        recent = recentCopies.compactMap { copy in
            recentSummaries[copy.ref.cardID].map { RecentCopy(card: $0, copy: copy) }
        }

        // Value trend (record today, then load the series).
        try? database.recordValueSnapshot(total: totalValue, day: Self.dayString(Date()))
        trend = ((try? database.valueSnapshots(limit: 60)) ?? []).map(\.total)
    }

    /// id -> summary for a batch of card ids (deduped), in one catalog query.
    private func summaryMap(for cardIDs: [String]) async -> [String: CardSummary] {
        let unique = Array(Set(cardIDs))
        let summaries = (try? await catalog?.summaries(forCardIDs: unique)) ?? []
        return Dictionary(summaries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
