//
//  PriceProvider.swift
//  binderBuilder
//
//  A source of live market prices. Implemented by TCGdexPriceProvider
//  (TCGplayer USD + Cardmarket EUR via the free TCGdex API) and
//  EbayBrowseProvider (median of active eBay listings, opt-in).
//

import Foundation

nonisolated protocol PriceProvider: Sendable {
    /// Stable identifier for staleness bookkeeping ("tcgdex", "ebay").
    var id: String { get }
    /// Fetches the current quotes for one card. Quotes are isLive=true.
    func quotes(for card: CardSummary) async throws -> [PriceQuote]
}

nonisolated enum PricingError: Error, Equatable {
    /// The daily eBay request budget is exhausted (resets at UTC midnight).
    case rateLimited
    /// The provider needs credentials that are missing or disabled.
    case notConfigured
    /// Non-2xx HTTP answer.
    case badStatus(Int)
    /// The response body could not be interpreted at all.
    case malformedResponse
}
