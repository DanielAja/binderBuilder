//
//  CardRef.swift
//  binderBuilder
//
//  Cross-layer currency type. Every layer (catalog, collection, 3D scene,
//  pricing, scanner) refers to a specific printing of a card with a CardRef.
//

import Foundation

/// A printing variant of a Pokemon card.
///
/// Raw values match the `variant` TEXT columns in both catalog.sqlite
/// (`price_snapshot.variant`) and user.sqlite (`owned_card.variant`,
/// `slot_assignment.variant`, `display_case.variant`, `price_cache.variant`).
nonisolated enum CardVariant: String, Codable, Sendable, CaseIterable, Hashable {
    case normal
    case holo
    case reverse
    case firstEdition
}

/// Identifies one variant of one card.
///
/// `cardID` is a TCGdex card id like `"base1-4"`.
nonisolated struct CardRef: Hashable, Codable, Sendable {
    var cardID: String
    var variant: CardVariant

    init(cardID: String, variant: CardVariant) {
        self.cardID = cardID
        self.variant = variant
    }
}
