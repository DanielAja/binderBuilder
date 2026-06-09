//
//  PriceQuote.swift
//  binderBuilder
//
//  A market price for one variant of one card from one source.
//  Bundled quotes come from catalog.sqlite's `price_snapshot` (isLive=false);
//  live quotes come from the Pricing module's network providers (isLive=true).
//

import Foundation

nonisolated struct PriceQuote: Sendable, Equatable {
    nonisolated enum Source: String, Codable, Sendable, CaseIterable {
        case tcgplayer
        case cardmarket
        case ebayActive
    }

    let source: Source
    let variant: CardVariant
    /// ISO 4217 code, e.g. "USD" (TCGplayer) or "EUR" (Cardmarket).
    let currency: String
    let market: Double?
    let low: Double?
    /// For bundled quotes this is the snapshot's `updated_at` (catalog build
    /// time); `.distantPast` when the snapshot has no usable timestamp.
    let fetchedAt: Date
    /// false = baked into the bundled catalog, true = fetched at runtime.
    let isLive: Bool
}
