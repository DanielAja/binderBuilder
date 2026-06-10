//
//  PriceCacheDatabase.swift
//  binderBuilder
//
//  Raw-GRDB access to the existing `price_cache` table in user.sqlite
//  (card_id, source, variant, currency, market, low, fetched_at). Lives in
//  the Pricing module so UserDatabase.swift stays untouched.
//

import Foundation
import GRDB

extension UserDatabase {
    /// All live quotes previously fetched for a card. Rows whose source or
    /// variant this app version doesn't know are skipped.
    func cachedQuotes(for cardID: String) throws -> [PriceQuote] {
        try queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT source, variant, currency, market, low, fetched_at
                FROM price_cache
                WHERE card_id = ?
                """,
                arguments: [cardID])
            return rows.compactMap { row in
                guard let source = PriceQuote.Source(rawValue: row["source"] as String? ?? ""),
                      let variant = CardVariant(rawValue: row["variant"] as String? ?? "")
                else { return nil }
                return PriceQuote(
                    source: source,
                    variant: variant,
                    currency: row["currency"] as String? ?? "USD",
                    market: row["market"],
                    low: row["low"],
                    fetchedAt: Date(timeIntervalSince1970: row["fetched_at"] as Double? ?? 0),
                    isLive: true)
            }
        }
    }

    /// Atomically replaces the cached quotes of the given sources for one
    /// card with a fresh fetch result. Quotes from other sources are ignored.
    func replacePriceCache(
        with quotes: [PriceQuote],
        cardID: String,
        sources: Set<PriceQuote.Source>
    ) throws {
        try queue.write { db in
            for source in sources.sorted(by: { $0.rawValue < $1.rawValue }) {
                try db.execute(
                    sql: "DELETE FROM price_cache WHERE card_id = ? AND source = ?",
                    arguments: [cardID, source.rawValue])
            }
            for quote in quotes where sources.contains(quote.source) {
                try db.execute(
                    sql: """
                    INSERT INTO price_cache (card_id, source, variant, currency, market, low, fetched_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(card_id, source, variant) DO UPDATE SET
                      currency = excluded.currency, market = excluded.market,
                      low = excluded.low, fetched_at = excluded.fetched_at
                    """,
                    arguments: [
                        cardID, quote.source.rawValue, quote.variant.rawValue,
                        quote.currency, quote.market, quote.low,
                        quote.fetchedAt.timeIntervalSince1970,
                    ])
            }
        }
    }

    /// Most recent fetched_at across all variants of (card, source); nil
    /// when this source has never been fetched for this card.
    func lastPriceFetch(cardID: String, source: PriceQuote.Source) throws -> Date? {
        try queue.read { db in
            try Double.fetchOne(
                db,
                sql: "SELECT MAX(fetched_at) FROM price_cache WHERE card_id = ? AND source = ?",
                arguments: [cardID, source.rawValue])
        }
        .map(Date.init(timeIntervalSince1970:))
    }
}
