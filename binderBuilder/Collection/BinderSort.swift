//
//  BinderSort.swift
//  binderBuilder
//
//  Ordering rules for "sort a binder's pages" — the pure, testable half of
//  BinderStore.sort(binderID:by:).
//
//  A sort COMPACTS: every card in the binder is pulled out, ordered by the
//  chosen key, and laid back down from the first pocket of the first sheet
//  forward. Gaps close up and the empty pockets end up as one tail at the
//  back. That is what collectors expect from a sort, and it makes the result
//  depend only on the key — not on where the holes happened to be before.
//

import Foundation

/// What a binder sort orders by.
nonisolated enum BinderSortKey: String, CaseIterable, Sendable, Identifiable {
    /// Set release order, then collector number within the set.
    case setNumber
    case name
    /// Bundled market price, most valuable first.
    case marketValue
    /// Rarest first.
    case rarity

    var id: String { rawValue }

    /// Menu / confirmation title.
    var title: String {
        switch self {
        case .setNumber: return "Set & Number"
        case .name: return "Name"
        case .marketValue: return "Value"
        case .rarity: return "Rarity"
        }
    }
}

/// One card pulled out of a binder, carrying everything the ordering needs.
/// Built by BinderStore from the catalog; a pure value so the ordering itself
/// is testable without a database.
nonisolated struct BinderSortEntry: Equatable, Sendable {
    let ref: CardRef
    /// Card name. Cards missing from the catalog fall back to their card id,
    /// so a sort never silently drops a pocket.
    let name: String
    /// Index of the card's set in catalog release order (earlier = smaller).
    /// `Int.max` when the set is unknown, so those land at the back.
    let setOrder: Int
    /// Collector number as printed, e.g. "4" or "TG12".
    let localNumber: String
    let rarity: String?
    /// Bundled TCGplayer market price for this exact printing; nil when the
    /// catalog has no price (unpriced cards sort last by Value).
    let market: Double?
}

/// Pure ordering + pocket-layout helpers.
nonisolated enum BinderSort {

    /// Orders the binder's cards by `key`. Every key falls through to the same
    /// total tiebreak — name, then card id, then variant — so the result is
    /// deterministic and re-sorting by the same key is a no-op.
    static func sorted(_ entries: [BinderSortEntry], by key: BinderSortKey) -> [BinderSortEntry] {
        entries.sorted { a, b in
            switch key {
            case .setNumber:
                if a.setOrder != b.setOrder { return a.setOrder < b.setOrder }
                let left = collectorOrder(a.localNumber)
                let right = collectorOrder(b.localNumber)
                if left.prefix != right.prefix { return left.prefix < right.prefix }
                if left.value != right.value { return left.value < right.value }
                if left.raw != right.raw { return left.raw < right.raw }
            case .name:
                let comparison = a.name.localizedCaseInsensitiveCompare(b.name)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            case .marketValue:
                // Unpriced cards sink below every priced one.
                let left = a.market ?? -Double.greatestFiniteMagnitude
                let right = b.market ?? -Double.greatestFiniteMagnitude
                if left != right { return left > right }
            case .rarity:
                let left = rarityRank(a.rarity)
                let right = rarityRank(b.rarity)
                if left != right { return left > right }
            }
            return tiebreak(a, b)
        }
    }

    /// Name, then card id, then variant — a total order over distinct pockets.
    private static func tiebreak(_ a: BinderSortEntry, _ b: BinderSortEntry) -> Bool {
        let byName = a.name.localizedCaseInsensitiveCompare(b.name)
        if byName != .orderedSame { return byName == .orderedAscending }
        if a.ref.cardID != b.ref.cardID { return a.ref.cardID < b.ref.cardID }
        return a.ref.variant.rawValue < b.ref.variant.rawValue
    }

    /// Collector numbers sort naturally: plain numbers before lettered ones
    /// ("4" before "TG12"), then by the embedded number ("4" before "24"),
    /// then by the raw text so "4a"/"4b" stay put.
    static func collectorOrder(_ number: String) -> (prefix: String, value: Int, raw: String) {
        let trimmed = number.trimmingCharacters(in: .whitespaces)
        let prefix = String(trimmed.prefix { !$0.isNumber }).uppercased()
        let digits = trimmed.drop { !$0.isNumber }.prefix { $0.isNumber }
        return (prefix, Int(digits) ?? Int.max, trimmed.uppercased())
    }

    /// Rarity ladder, commonest first — the index is the rank, so a Rarity
    /// sort walks it backwards (rarest first).
    private static let rarityLadder = [
        "none", "common", "uncommon", "rare", "rare holo", "double rare",
        "rare holo ex", "amazing rare", "radiant rare", "ultra rare",
        "illustration rare", "shiny rare", "special illustration rare",
        "hyper rare", "secret rare",
    ]

    /// Rank of a catalog rarity string, higher = rarer. Matched exactly first
    /// (case-insensitively), then by the rarest containing tier so catalog
    /// variations still land with their family ("Rare Holo VMAX" -> Rare Holo).
    /// Absent and unrecognized rarities rank below everything and are ordered
    /// among themselves by the tiebreak.
    static func rarityRank(_ rarity: String?) -> Int {
        guard let rarity else { return -1 }
        let key = rarity.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return -1 }
        if let exact = rarityLadder.firstIndex(of: key) { return exact }
        for index in rarityLadder.indices.reversed() where key.contains(rarityLadder[index]) {
            return index
        }
        return -1
    }

    /// The binder's pockets in laydown order — sheet 0 front (0...8), sheet 0
    /// back, sheet 1 front, … — the same front-to-back order
    /// `BinderStore.firstEmptySlot` fills.
    static func slotSequence(binderID: String, pageCount: Int) -> [SlotLocation] {
        guard pageCount > 0 else { return [] }
        var slots: [SlotLocation] = []
        slots.reserveCapacity(pageCount * PageSide.allCases.count * SpreadModel.slotsPerPage)
        for page in 0..<pageCount {
            for side in [PageSide.front, .back] {
                for slot in 0..<SpreadModel.slotsPerPage {
                    slots.append(SlotLocation(
                        binderID: binderID, pageIndex: page, side: side, slotIndex: slot))
                }
            }
        }
        return slots
    }
}
