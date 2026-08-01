//
//  BinderSortTests.swift
//  binderBuilderTests
//
//  The pure ordering rules, plus the store-level rewrite: a sort compacts the
//  binder's cards to the front and leaves the empty pockets as one tail.
//

import Foundation
import GRDB
import Testing
@testable import binderBuilder

struct BinderSortOrderingTests {

    private func entry(
        _ cardID: String,
        variant: CardVariant = .normal,
        name: String = "Card",
        setOrder: Int = 0,
        number: String = "1",
        rarity: String? = nil,
        market: Double? = nil
    ) -> BinderSortEntry {
        BinderSortEntry(
            ref: CardRef(cardID: cardID, variant: variant),
            name: name, setOrder: setOrder, localNumber: number,
            rarity: rarity, market: market)
    }

    // MARK: - Set & number

    @Test func setNumberOrdersByReleaseThenCollectorNumber() {
        let entries = [
            entry("c", name: "C", setOrder: 1, number: "TG12"),
            entry("a", name: "A", setOrder: 1, number: "2"),
            entry("b", name: "B", setOrder: 0, number: "102"),
            entry("d", name: "D", setOrder: 0, number: "4"),
        ]
        #expect(BinderSort.sorted(entries, by: .setNumber).map(\.ref.cardID) == ["d", "b", "a", "c"])
    }

    @Test func unknownSetsSortLast() {
        let entries = [
            entry("late", name: "Late", setOrder: Int.max, number: "1"),
            entry("early", name: "Early", setOrder: 3, number: "999"),
        ]
        #expect(BinderSort.sorted(entries, by: .setNumber).map(\.ref.cardID) == ["early", "late"])
    }

    @Test func collectorNumbersSortNaturally() {
        let numbers = ["24", "4", "TG12", "102", "TG2", "SV1"]
        let sorted = numbers.sorted { a, b in
            let left = BinderSort.collectorOrder(a), right = BinderSort.collectorOrder(b)
            if left.prefix != right.prefix { return left.prefix < right.prefix }
            if left.value != right.value { return left.value < right.value }
            return left.raw < right.raw
        }
        #expect(sorted == ["4", "24", "102", "SV1", "TG2", "TG12"])
    }

    @Test func collectorOrderHandlesNonNumericAndPadding() {
        #expect(BinderSort.collectorOrder(" 007 ").value == 7)
        #expect(BinderSort.collectorOrder("H").value == Int.max)
        #expect(BinderSort.collectorOrder("tg1").prefix == "TG")
    }

    // MARK: - Name

    @Test func nameOrderIsCaseInsensitive() {
        let entries = [
            entry("c", name: "zapdos"),
            entry("a", name: "Articuno"),
            entry("b", name: "Moltres"),
        ]
        #expect(BinderSort.sorted(entries, by: .name).map(\.name) == ["Articuno", "Moltres", "zapdos"])
    }

    // MARK: - Value

    @Test func valueOrdersDescendingWithUnpricedLast() {
        let entries = [
            entry("cheap", name: "Cheap", market: 0.25),
            entry("none", name: "None", market: nil),
            entry("dear", name: "Dear", market: 5200),
            entry("mid", name: "Mid", market: 420.5),
        ]
        #expect(BinderSort.sorted(entries, by: .marketValue).map(\.ref.cardID)
                == ["dear", "mid", "cheap", "none"])
    }

    // MARK: - Rarity

    @Test func rarityRankClimbsTheLadder() {
        #expect(BinderSort.rarityRank("Common") < BinderSort.rarityRank("Uncommon"))
        #expect(BinderSort.rarityRank("Uncommon") < BinderSort.rarityRank("Rare Holo"))
        #expect(BinderSort.rarityRank("Rare Holo") < BinderSort.rarityRank("Ultra Rare"))
        #expect(BinderSort.rarityRank("Ultra Rare") < BinderSort.rarityRank("Secret Rare"))
        // Case-insensitive, and catalog variations fall back to their family.
        #expect(BinderSort.rarityRank("rare holo") == BinderSort.rarityRank("Rare Holo"))
        #expect(BinderSort.rarityRank("Rare Holo VMAX") == BinderSort.rarityRank("Rare Holo"))
        // Absent / unrecognized ranks below everything on the ladder.
        #expect(BinderSort.rarityRank(nil) < BinderSort.rarityRank("None"))
        #expect(BinderSort.rarityRank("Promo") < BinderSort.rarityRank("Common"))
    }

    @Test func rarityOrdersRarestFirst() {
        let entries = [
            entry("common", name: "Common Card", rarity: "Common"),
            entry("secret", name: "Secret Card", rarity: "Secret Rare"),
            entry("unknown", name: "Unknown Card", rarity: "Promo"),
            entry("holo", name: "Holo Card", rarity: "Rare Holo"),
        ]
        #expect(BinderSort.sorted(entries, by: .rarity).map(\.ref.cardID)
                == ["secret", "holo", "common", "unknown"])
    }

    // MARK: - Tiebreak

    @Test func tiesFallThroughToNameThenIDThenVariant() {
        // Same rarity, same everything else: name wins, then id, then variant.
        let entries = [
            entry("b", variant: .holo, name: "Same", rarity: "Common"),
            entry("b", variant: .firstEdition, name: "Same", rarity: "Common"),
            entry("a", name: "Same", rarity: "Common"),
            entry("z", name: "Alpha", rarity: "Common"),
        ]
        let sorted = BinderSort.sorted(entries, by: .rarity)
        #expect(sorted.map(\.ref.cardID) == ["z", "a", "b", "b"])
        #expect(sorted[2].ref.variant == .firstEdition)  // "firstEdition" < "holo"
        #expect(sorted[3].ref.variant == .holo)
    }

    @Test func sortingIsIdempotent() {
        let entries = [
            entry("a", name: "A", setOrder: 1, number: "9", rarity: "Common", market: 1),
            entry("b", name: "B", setOrder: 0, number: "3", rarity: "Ultra Rare", market: 9),
            entry("c", name: "C", setOrder: 0, number: "12", rarity: "Common", market: nil),
        ]
        for key in BinderSortKey.allCases {
            let once = BinderSort.sorted(entries, by: key)
            #expect(BinderSort.sorted(once, by: key) == once)
        }
    }

    // MARK: - Pocket layout

    @Test func slotSequenceRunsFrontToBack() {
        let slots = BinderSort.slotSequence(binderID: "b", pageCount: 2)
        #expect(slots.count == 2 * 2 * SpreadModel.slotsPerPage)
        #expect(slots[0] == SlotLocation(binderID: "b", pageIndex: 0, side: .front, slotIndex: 0))
        #expect(slots[8] == SlotLocation(binderID: "b", pageIndex: 0, side: .front, slotIndex: 8))
        #expect(slots[9] == SlotLocation(binderID: "b", pageIndex: 0, side: .back, slotIndex: 0))
        #expect(slots[18] == SlotLocation(binderID: "b", pageIndex: 1, side: .front, slotIndex: 0))
        #expect(slots.last == SlotLocation(binderID: "b", pageIndex: 1, side: .back, slotIndex: 8))
        #expect(BinderSort.slotSequence(binderID: "b", pageCount: 0).isEmpty)
    }
}

// MARK: - Store-level rewrite

@MainActor struct BinderSortStoreTests {
    private struct Stores {
        let user: UserDatabase
        let binders: BinderStore
    }

    private func makeStores() throws -> Stores {
        let user = try UserDatabase.inMemory()
        let catalog = try TestCatalog.makeCatalog()
        let collection = CollectionStore(database: user)
        return Stores(
            user: user,
            binders: BinderStore(database: user, catalog: catalog) { collection.isOwned($0) })
    }

    private struct Placement: Equatable {
        let page: Int
        let side: Int
        let slot: Int
        let ref: CardRef
    }

    private func layout(_ user: UserDatabase, _ binderID: String) throws -> [Placement] {
        try user.queue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT page_index, side, slot_index, card_id, variant FROM slot_assignment
                WHERE binder_id = ? ORDER BY page_index, side, slot_index
                """,
                arguments: [binderID]
            ).map { row in
                Placement(
                    page: row["page_index"], side: row["side"], slot: row["slot_index"],
                    ref: CardRef(cardID: row["card_id"],
                                 variant: CardVariant(rawValue: row["variant"] as String? ?? "") ?? .normal))
            }
        }
    }

    /// Scatters the fixture's 8 cards across two sheets, leaving holes.
    private func seedScattered(_ stores: Stores, binderID: String) {
        let scattered: [(String, Int, PageSide, Int)] = [
            ("base1-102", 0, .front, 3),
            ("swsh9-TG12", 0, .front, 7),
            ("base1-58", 0, .back, 1),
            ("swsh9-25", 0, .back, 8),
            ("base1-4", 1, .front, 0),
            ("base1-46", 1, .front, 5),
            ("swsh9-1", 1, .back, 2),
            ("base1-24", 1, .back, 6),
        ]
        for (cardID, page, side, slot) in scattered {
            stores.binders.assign(
                CardRef(cardID: cardID, variant: .normal),
                to: SlotLocation(binderID: binderID, pageIndex: page, side: side, slotIndex: slot))
        }
    }

    @Test func sortByNameCompactsCardsToTheFront() async throws {
        let stores = try makeStores()
        let binder = try #require(
            stores.binders.createBinder(name: "Scatter", coverColor: "#1B6CA8", pageCount: 2))
        seedScattered(stores, binderID: binder.id)
        let before = stores.binders.changeToken

        #expect(await stores.binders.sort(binderID: binder.id, by: .name))
        #expect(stores.binders.changeToken == before + 1)

        let placed = try layout(stores.user, binder.id)
        #expect(placed.count == 8)
        // The 8 cards fill sheet 0's front pockets 0...7 — no holes, and the
        // rest of the binder is now empty.
        #expect(placed.map(\.page).allSatisfy { $0 == 0 })
        #expect(placed.map(\.side).allSatisfy { $0 == PageSide.front.rawValue })
        #expect(placed.map(\.slot) == Array(0..<8))
        #expect(placed.map(\.ref.cardID) == [
            "base1-4",     // Charizard
            "base1-46",    // Charmander
            "base1-24",    // Charmeleon
            "swsh9-1",     // Exeggcute
            "swsh9-25",    // Lumineon V
            "swsh9-TG12",  // Mew
            "base1-58",    // Pikachu
            "base1-102",   // Water Energy
        ])
    }

    @Test func sortBySetAndNumberUsesCatalogReleaseOrder() async throws {
        let stores = try makeStores()
        let binder = try #require(
            stores.binders.createBinder(name: "Sets", coverColor: "#1B6CA8", pageCount: 2))
        seedScattered(stores, binderID: binder.id)

        #expect(await stores.binders.sort(binderID: binder.id, by: .setNumber))
        // Base Set (1999) before Brilliant Stars (2022); within a set, by
        // collector number, with the TG subset after the plain numbers.
        #expect(try layout(stores.user, binder.id).map(\.ref.cardID) == [
            "base1-4", "base1-24", "base1-46", "base1-58", "base1-102",
            "swsh9-1", "swsh9-25", "swsh9-TG12",
        ])
    }

    @Test func sortByRarityPutsTheChaseCardsFirst() async throws {
        let stores = try makeStores()
        let binder = try #require(
            stores.binders.createBinder(name: "Rarity", coverColor: "#1B6CA8", pageCount: 2))
        seedScattered(stores, binderID: binder.id)

        #expect(await stores.binders.sort(binderID: binder.id, by: .rarity))
        let ids = try layout(stores.user, binder.id).map(\.ref.cardID)
        #expect(ids.first == "swsh9-25")                        // Ultra Rare
        #expect(Array(ids[1...2]) == ["base1-4", "swsh9-TG12"])  // Rare Holo, by name
        #expect(ids[3] == "base1-24")                           // Uncommon
        #expect(Set(ids[4...]) == ["base1-46", "base1-58", "base1-102", "swsh9-1"])
    }

    @Test func sortByValueUsesBundledMarketPrices() async throws {
        let stores = try makeStores()
        let binder = try #require(
            stores.binders.createBinder(name: "Value", coverColor: "#1B6CA8", pageCount: 1))
        // Priced printings from the fixture, plus one with no price at all.
        let priced: [(CardRef, Int)] = [
            (CardRef(cardID: "base1-46", variant: .normal), 0),   // unpriced
            (CardRef(cardID: "swsh9-1", variant: .reverse), 3),   // 0.25
            (CardRef(cardID: "base1-4", variant: .firstEdition), 5),  // 5200
            (CardRef(cardID: "base1-4", variant: .holo), 8),      // 420.50
        ]
        for (ref, slot) in priced {
            stores.binders.assign(
                ref, to: SlotLocation(binderID: binder.id, pageIndex: 0, side: .front, slotIndex: slot))
        }

        #expect(await stores.binders.sort(binderID: binder.id, by: .marketValue))
        #expect(try layout(stores.user, binder.id).map(\.ref) == [
            CardRef(cardID: "base1-4", variant: .firstEdition),
            CardRef(cardID: "base1-4", variant: .holo),
            CardRef(cardID: "swsh9-1", variant: .reverse),
            CardRef(cardID: "base1-46", variant: .normal),
        ])
    }

    @Test func sortLeavesRowsOutsideThePageRangeAlone() async throws {
        let stores = try makeStores()
        let binder = try #require(
            stores.binders.createBinder(name: "Shrunk", coverColor: "#1B6CA8", pageCount: 1))
        stores.binders.assign(
            CardRef(cardID: "base1-58", variant: .normal),
            to: SlotLocation(binderID: binder.id, pageIndex: 0, side: .back, slotIndex: 4))
        // A leftover from when the binder had more sheets.
        stores.binders.assign(
            CardRef(cardID: "swsh9-25", variant: .normal),
            to: SlotLocation(binderID: binder.id, pageIndex: 7, side: .front, slotIndex: 0))

        #expect(await stores.binders.sort(binderID: binder.id, by: .name))
        let placed = try layout(stores.user, binder.id)
        #expect(placed.count == 2)
        #expect(placed[0] == Placement(page: 0, side: PageSide.front.rawValue, slot: 0,
                                       ref: CardRef(cardID: "base1-58", variant: .normal)))
        #expect(placed[1].page == 7)
    }

    @Test func sortIsANoOpWithoutCardsOrACatalog() async throws {
        let stores = try makeStores()
        let empty = try #require(stores.binders.createBinder(name: "Empty", coverColor: "#000000"))
        #expect(await stores.binders.sort(binderID: empty.id, by: .name) == false)
        #expect(await stores.binders.sort(binderID: "no-such-binder", by: .name) == false)
        #expect(stores.binders.changeToken == 0)

        let user = try UserDatabase.inMemory()
        let catalogless = BinderStore(database: user, catalog: nil) { _ in false }
        let binder = try #require(catalogless.createBinder(name: "Blind", coverColor: "#000000"))
        catalogless.assign(
            CardRef(cardID: "base1-4", variant: .holo),
            to: SlotLocation(binderID: binder.id, pageIndex: 2, side: .back, slotIndex: 5))
        #expect(await catalogless.sort(binderID: binder.id, by: .name) == false)
        // The untouched assignment is still exactly where it was.
        #expect(try layout(user, binder.id).map(\.page) == [2])
    }

    @Test func sortedSpreadsReadBackThroughTheStore() async throws {
        let stores = try makeStores()
        let binder = try #require(
            stores.binders.createBinder(name: "Read", coverColor: "#1B6CA8", pageCount: 2))
        seedScattered(stores, binderID: binder.id)
        #expect(await stores.binders.sort(binderID: binder.id, by: .name))

        // Spread 0's right page is sheet 0's front: the first nine sorted cards
        // (here, all eight plus one empty pocket).
        let spread0 = try await stores.binders.spread(0, in: binder.id)
        #expect(spread0.right.compactMap { $0?.card.name }.prefix(3)
                == ["Charizard", "Charmander", "Charmeleon"])
        #expect(spread0.right[8] == nil)
        // Everything behind it is empty.
        let spread1 = try await stores.binders.spread(1, in: binder.id)
        #expect(spread1.left.allSatisfy { $0 == nil })
        #expect(spread1.right.allSatisfy { $0 == nil })
    }
}
