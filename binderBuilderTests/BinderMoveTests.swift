//
//  BinderMoveTests.swift
//  binderBuilderTests
//
//  moveCard semantics: swap, and insert-&-shift with its gap-absorbing
//  ripple across side and page boundaries.
//

import Foundation
import GRDB
import Testing
@testable import binderBuilder

@MainActor struct BinderMoveTests {
    struct Stores {
        let user: UserDatabase
        let binders: BinderStore
    }

    func makeStores() throws -> Stores {
        let user = try UserDatabase.inMemory()
        let binders = BinderStore(database: user, catalog: try TestCatalog.makeCatalog()) { _ in true }
        return Stores(user: user, binders: binders)
    }

    private func rowCount(_ user: UserDatabase) throws -> Int {
        try user.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM slot_assignment") ?? 0
        }
    }

    /// Assignments keyed by linear pocket ordinal, for readable expectations.
    private func byOrdinal(_ binders: BinderStore, _ binderID: String) -> [Int: CardRef] {
        Dictionary(uniqueKeysWithValues: binders.assignments(binderID: binderID).map {
            (BinderStore.ordinal(of: $0.location), $0.ref)
        })
    }

    private func place(_ binders: BinderStore, _ binderID: String, _ ordinal: Int, _ ref: CardRef) {
        binders.assign(ref, to: BinderStore.slotLocation(atOrdinal: ordinal, binderID: binderID))
    }

    private func loc(_ binderID: String, _ ordinal: Int) -> SlotLocation {
        BinderStore.slotLocation(atOrdinal: ordinal, binderID: binderID)
    }

    private let a = CardRef(cardID: "base1-4", variant: .holo)
    private let b = CardRef(cardID: "base1-4", variant: .normal)
    private let c = CardRef(cardID: "base1-58", variant: .normal)
    private let d = CardRef(cardID: "base1-58", variant: .holo)
    private let x = CardRef(cardID: "swsh9-1", variant: .reverse)

    // MARK: - Ordinal mapping

    @Test func ordinalRoundTripsThroughSlotLocation() {
        for ordinal in [0, 8, 9, 17, 18, 26, 35, 53] {
            let location = loc("b", ordinal)
            #expect(BinderStore.ordinal(of: location) == ordinal)
            #expect((0..<SpreadModel.slotsPerPage).contains(location.slotIndex))
        }
        // Boundary spot checks: 9 is page 0's back side, 18 is page 1's front.
        #expect(loc("b", 9).side == .back && loc("b", 9).pageIndex == 0)
        #expect(loc("b", 18).side == .front && loc("b", 18).pageIndex == 1)
    }

    // MARK: - Swap

    @Test func swapExchangesTwoOccupiedPocketsAcrossPages() throws {
        let stores = try makeStores()
        let binder = try #require(stores.binders.createBinder(name: "Swap", coverColor: "#111111", pageCount: 2))
        place(stores.binders, binder.id, 0, a)
        place(stores.binders, binder.id, 25, b)   // page 1, back side
        let token = stores.binders.changeToken

        let result = stores.binders.moveCard(from: loc(binder.id, 0), to: loc(binder.id, 25), mode: .swap)
        #expect(result == MoveResult(shifted: []))
        let after = byOrdinal(stores.binders, binder.id)
        #expect(after[0] == b)
        #expect(after[25] == a)
        #expect(after.count == 2)
        #expect(stores.binders.changeToken == token + 1)
    }

    @Test func swapWithEmptyTargetIsAPlainMove() throws {
        let stores = try makeStores()
        let binder = try #require(stores.binders.createBinder(name: "Move", coverColor: "#111111", pageCount: 2))
        place(stores.binders, binder.id, 3, a)

        let result = stores.binders.moveCard(from: loc(binder.id, 3), to: loc(binder.id, 30), mode: .swap)
        #expect(result != nil)
        let after = byOrdinal(stores.binders, binder.id)
        #expect(after[30] == a)
        #expect(after[3] == nil)
        #expect(try rowCount(stores.user) == 1)
    }

    // MARK: - Insert & shift

    @Test func insertShiftRipplesForwardAndReportsShiftedSlots() throws {
        let stores = try makeStores()
        let binder = try #require(stores.binders.createBinder(name: "Ripple", coverColor: "#111111", pageCount: 2))
        place(stores.binders, binder.id, 0, a)
        place(stores.binders, binder.id, 1, b)
        place(stores.binders, binder.id, 2, c)
        place(stores.binders, binder.id, 10, x)

        let result = stores.binders.moveCard(from: loc(binder.id, 10), to: loc(binder.id, 0), mode: .insertShift)
        #expect(result?.shifted == [loc(binder.id, 1), loc(binder.id, 2), loc(binder.id, 3)])
        let after = byOrdinal(stores.binders, binder.id)
        #expect(after[0] == x)
        #expect(after[1] == a)
        #expect(after[2] == b)
        #expect(after[3] == c)
        #expect(after[10] == nil)
        #expect(after.count == 4)
    }

    @Test func rippleCrossesSideAndPageBoundaries() throws {
        let stores = try makeStores()
        let binder = try #require(stores.binders.createBinder(name: "Bounds", coverColor: "#111111", pageCount: 2))
        // 17 is page 0's last back pocket; 18 is page 1's first front pocket.
        place(stores.binders, binder.id, 17, a)
        place(stores.binders, binder.id, 18, b)
        place(stores.binders, binder.id, 30, x)

        let result = stores.binders.moveCard(from: loc(binder.id, 30), to: loc(binder.id, 17), mode: .insertShift)
        #expect(result?.shifted == [loc(binder.id, 18), loc(binder.id, 19)])
        let after = byOrdinal(stores.binders, binder.id)
        #expect(after[17] == x)
        #expect(after[18] == a)
        #expect(after[19] == b)
    }

    @Test func firstGapAbsorbsTheRipple() throws {
        let stores = try makeStores()
        let binder = try #require(stores.binders.createBinder(name: "Gap", coverColor: "#111111", pageCount: 1))
        place(stores.binders, binder.id, 0, a)
        place(stores.binders, binder.id, 1, b)
        // 2 is empty — the gap.
        place(stores.binders, binder.id, 3, c)
        place(stores.binders, binder.id, 10, x)

        let result = stores.binders.moveCard(from: loc(binder.id, 10), to: loc(binder.id, 0), mode: .insertShift)
        #expect(result?.shifted == [loc(binder.id, 1), loc(binder.id, 2)])
        let after = byOrdinal(stores.binders, binder.id)
        #expect(after[0] == x)
        #expect(after[1] == a)
        #expect(after[2] == b)
        #expect(after[3] == c)     // beyond the gap: untouched
    }

    @Test func theSourcesVacatedPocketCountsAsAGap() throws {
        let stores = try makeStores()
        let binder = try #require(stores.binders.createBinder(name: "Back", coverColor: "#111111", pageCount: 1))
        place(stores.binders, binder.id, 0, a)
        place(stores.binders, binder.id, 1, b)
        place(stores.binders, binder.id, 2, c)

        // Moving 2 -> 0 shifts only the cards in between; the ripple stops in
        // the pocket the moved card vacated.
        let result = stores.binders.moveCard(from: loc(binder.id, 2), to: loc(binder.id, 0), mode: .insertShift)
        #expect(result?.shifted == [loc(binder.id, 1), loc(binder.id, 2)])
        let after = byOrdinal(stores.binders, binder.id)
        #expect(after[0] == c)
        #expect(after[1] == a)
        #expect(after[2] == b)
        #expect(after.count == 3)
    }

    @Test func insertShiftIntoEmptyPocketIsAPlainMove() throws {
        let stores = try makeStores()
        let binder = try #require(stores.binders.createBinder(name: "Plain", coverColor: "#111111", pageCount: 1))
        place(stores.binders, binder.id, 5, a)

        let result = stores.binders.moveCard(from: loc(binder.id, 5), to: loc(binder.id, 9), mode: .insertShift)
        #expect(result == MoveResult(shifted: []))
        let after = byOrdinal(stores.binders, binder.id)
        #expect(after[9] == a)
        #expect(after.count == 1)
    }

    @Test func fullBinderWithNoGapRefusesAndLeavesTheDatabaseUntouched() throws {
        let stores = try makeStores()
        let binder = try #require(stores.binders.createBinder(name: "Full", coverColor: "#111111", pageCount: 1))
        for ordinal in 0..<18 {
            place(stores.binders, binder.id, ordinal, ordinal % 2 == 0 ? a : b)
        }
        let before = byOrdinal(stores.binders, binder.id)
        let token = stores.binders.changeToken

        // Source (0) vacates BEHIND the target, so the ripple from 1 upward
        // never finds a gap and must refuse.
        let result = stores.binders.moveCard(from: loc(binder.id, 0), to: loc(binder.id, 1), mode: .insertShift)
        #expect(result == nil)
        #expect(byOrdinal(stores.binders, binder.id) == before)
        #expect(stores.binders.changeToken == token)
    }

    // MARK: - Refusals

    @Test func invalidMovesReturnNil() throws {
        let stores = try makeStores()
        let binder = try #require(stores.binders.createBinder(name: "Nope", coverColor: "#111111", pageCount: 1))
        place(stores.binders, binder.id, 0, a)
        let token = stores.binders.changeToken

        // Empty source.
        #expect(stores.binders.moveCard(from: loc(binder.id, 5), to: loc(binder.id, 0), mode: .swap) == nil)
        // Same pocket.
        #expect(stores.binders.moveCard(from: loc(binder.id, 0), to: loc(binder.id, 0), mode: .swap) == nil)
        // Target beyond the page range.
        #expect(stores.binders.moveCard(from: loc(binder.id, 0), to: loc(binder.id, 20), mode: .swap) == nil)
        // Cross-binder.
        let other = try #require(stores.binders.createBinder(name: "Other", coverColor: "#111111", pageCount: 1))
        #expect(stores.binders.moveCard(from: loc(binder.id, 0), to: loc(other.id, 1), mode: .swap) == nil)
        // Unknown binder.
        #expect(stores.binders.moveCard(from: loc("missing", 0), to: loc("missing", 1), mode: .swap) == nil)

        #expect(stores.binders.changeToken == token)
        #expect(byOrdinal(stores.binders, binder.id) == [0: a])
    }
}
