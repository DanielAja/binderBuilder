//
//  CardDetail.swift
//  binderBuilder
//
//  Full card record for the card-detail screen: everything in CardSummary
//  plus the remaining `card` table columns.
//

import Foundation

nonisolated struct CardDetail: Identifiable, Hashable, Sendable {
    let summary: CardSummary

    /// "Pokemon", "Trainer", or "Energy" (nullable in the catalog).
    let category: String?
    /// Pokemon types, e.g. ["Fire"]. Empty for trainers/energies.
    let types: [String]
    let hp: Int?
    let illustrator: String?
    let regulationMark: String?
    /// Numeric sort key within the set (0 when the catalog has none).
    let sortNumber: Int

    var id: String { summary.id }
    var name: String { summary.name }
    var setID: String { summary.setID }
    var setName: String { summary.setName }
    var localNumber: String { summary.localNumber }
    var rarity: String? { summary.rarity }
    var imageBase: String? { summary.imageBase }
    var availableVariants: Set<CardVariant> { summary.availableVariants }
}
