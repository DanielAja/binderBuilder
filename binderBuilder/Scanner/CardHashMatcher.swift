//
//  CardHashMatcher.swift
//  binderBuilder
//
//  Nearest-card lookup over the bundled dHash index. Loads every card_hash row
//  (4 orientations per card) once, then Hamming-scans a query dHash against all
//  of them, keeping the best (smallest) distance per card. ~92k 64-bit popcount
//  comparisons. The 4 stored orientations make matching robust to a card
//  photographed rotated.
//
//  The index is immutable once loaded, so the type is `nonisolated` (the
//  project defaults every type to @MainActor) and `Sendable`: callers run the
//  scan off the main thread, which is what keeps the live scanner from
//  stuttering the UI on older devices at one frame every 180 ms.
//

import Foundation

struct CardMatch: Equatable, Sendable {
    let cardID: String
    let distance: Int
    /// 0...1 similarity (1 = identical).
    var confidence: Double { 1 - Double(distance) / 64 }
}

nonisolated final class CardHashMatcher: Sendable {
    struct Entry: Sendable { let cardID: String; let dhash: UInt64 }
    private let entries: [Entry]

    init(entries: [Entry]) { self.entries = entries }

    /// Builds a matcher from the bundled catalog's hash index.
    static func load(from catalog: any CatalogReading) async -> CardHashMatcher {
        let rows = (try? await catalog.hashEntries()) ?? []
        let entries = rows.map { row in
            Entry(cardID: row.cardID, dhash: PerceptualHash.decode(blob: [UInt8](row.dhash)))
        }
        return CardHashMatcher(entries: entries)
    }

    var isEmpty: Bool { entries.isEmpty }

    /// Best matches for a query dHash, smallest distance first, one row per
    /// card (the closest of its orientations).
    func match(_ query: UInt64, limit: Int = 5) -> [CardMatch] {
        var bestByCard: [String: Int] = [:]
        for entry in entries {
            let d = PerceptualHash.hamming(query, entry.dhash)
            if let existing = bestByCard[entry.cardID] {
                if d < existing { bestByCard[entry.cardID] = d }
            } else {
                bestByCard[entry.cardID] = d
            }
        }
        return bestByCard
            .map { CardMatch(cardID: $0.key, distance: $0.value) }
            .sorted { $0.distance < $1.distance }
            .prefix(limit)
            .map { $0 }
    }
}
