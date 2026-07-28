//
//  TradingPrice.swift
//  binderBuilder
//
//  Collapses a card's several quotes (per source, per variant, live + bundled)
//  into ONE "what's it trading at" figure for the fast scanner and the trade
//  value math. Prefers a USD number for the exact variant, live over bundled,
//  TCGplayer over eBay over Cardmarket.
//

import Foundation

/// A single headline market price for a printing.
nonisolated struct TradingPrice: Sendable, Equatable {
    let amount: Double
    /// ISO 4217, e.g. "USD" or "EUR".
    let currency: String
    /// true = fetched at runtime, false = bundled snapshot.
    let isLive: Bool

    /// "$12.34" / "€9.50" / "12.34 GBP".
    var display: String {
        let symbol = currency == "USD" ? "$" : (currency == "EUR" ? "€" : "")
        return symbol.isEmpty
            ? String(format: "%.2f %@", amount, currency)
            : String(format: "%@%.2f", symbol, amount)
    }
}

extension PriceStore {
    /// The best single trading price for a printing, fetching/merging quotes.
    func tradingPrice(for ref: CardRef) async -> TradingPrice? {
        let quotes = await quotes(for: ref.cardID)
        return Self.bestTradingPrice(from: quotes, variant: ref.variant)
    }

    /// Pure ranking (unit-tested): pick the most representative USD-first quote
    /// for `variant`, preferring exact-variant → live → TCGplayer.
    nonisolated static func bestTradingPrice(
        from quotes: [PriceQuote], variant: CardVariant
    ) -> TradingPrice? {
        func variantRank(_ q: PriceQuote) -> Int {
            if q.variant == variant { return 0 }
            if q.variant == .normal { return 1 }  // usable fallback
            return 2                               // a different specific variant — skip
        }
        func currencyRank(_ q: PriceQuote) -> Int { q.currency == "USD" ? 0 : 1 }
        func sourceRank(_ q: PriceQuote) -> Int {
            switch q.source {
            case .tcgplayer: return 0
            case .ebayActive: return 1
            case .cardmarket: return 2
            }
        }

        let candidates = quotes.filter { $0.market != nil && variantRank($0) < 2 }
        let best = candidates.min { a, b in
            (currencyRank(a), variantRank(a), a.isLive ? 0 : 1, sourceRank(a))
                < (currencyRank(b), variantRank(b), b.isLive ? 0 : 1, sourceRank(b))
        }
        guard let best, let market = best.market else { return nil }
        return TradingPrice(amount: market, currency: best.currency, isLive: best.isLive)
    }
}
