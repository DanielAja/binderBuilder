//
//  CardSummary.swift
//  binderBuilder
//
//  Lightweight card row used by search results, set browsing, and binder
//  slot rendering. Backed by the `card` + `set_info` tables in catalog.sqlite.
//

import Foundation

nonisolated struct CardSummary: Identifiable, Hashable, Sendable {
    /// TCGdex card id, e.g. "base1-4".
    let id: String
    let name: String
    let setID: String
    let setName: String
    /// Collector number within the set, e.g. "4" or "TG12".
    let localNumber: String
    let rarity: String?
    /// CDN image base URL without the quality/extension suffix; nil when
    /// TCGdex has no image for this card.
    let imageBase: String?
    /// Which printings of this card exist (from the has_* flags).
    let availableVariants: Set<CardVariant>
}
