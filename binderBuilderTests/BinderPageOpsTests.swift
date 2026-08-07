//
//  BinderPageOpsTests.swift
//  binderBuilderTests
//
//  Page add/insert/remove re-keying (the negate-and-flip shift) and the
//  configurable display-case row.
//

import Foundation
import GRDB
import Testing
@testable import binderBuilder

@MainActor struct BinderPageOpsTests {
    struct Stores {
        let user: UserDatabase
        let collection: CollectionStore
        let binders: BinderStore
    }

    func makeStores() throws -> Stores {
        let user = try UserDatabase.inMemory()
        let catalog = try TestCatalog.makeCatalog()
        let collection = CollectionStore(database: user)
        let binders = BinderStore(database: user, catalog: catalog) { ref in
            collection.isOwned(ref)
        }
        return Stores(user: user, collection: collection, binders: binders)
    }

    private func rowCount(_ user: UserDatabase, binderID: String) throws -> Int {
        try user.queue.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM slot_assignment WHERE binder_id = ?",
                arguments: [binderID]) ?? 0
        }
    }

    /// The binder's assignments keyed by (pageIndex, side, slotIndex).
    private func layout(_ binders: BinderStore, _ binderID: String) -> [SlotLocation: CardRef] {
        Dictionary(uniqueKeysWithValues: binders.assignments(binderID: binderID).map {
            ($0.location, $0.ref)
        })
    }

    private func slot(_ binderID: String, _ page: Int, _ side: PageSide, _ index: Int) -> SlotLocation {
        SlotLocation(binderID: binderID, pageIndex: page, side: side, slotIndex: index)
    }

    // MARK: - addPages

    @Test func addPagesBumpsThePageCountAndNothingElse() throws {
        let stores = try makeStores()
        let binder = try #require(stores.binders.createBinder(name: "Grow", coverColor: "#1B6CA8", pageCount: 2))
        stores.binders.assign(CardRef(cardID: "base1-4", variant: .holo),
                              to: slot(binder.id, 1, .front, 4))
        let tokenBefore = stores.binders.changeToken

        #expect(stores.binders.addPages(2, to: binder.id))
        #expect(stores.binders.binders.first?.pageCount == 4)
        #expect(stores.binders.changeToken == tokenBefore + 1)
        // Existing assignments stay exactly where they were.
        #expect(layout(stores.binders, binder.id)[slot(binder.id, 1, .front, 4)]?.cardID == "base1-4")
        #expect(try rowCount(stores.user, binderID: binder.id) == 1)

        // Zero / negative counts are refused.
        #expect(!stores.binders.addPages(0, to: binder.id))
        #expect(!stores.binders.addPages(-1, to: binder.id))
        #expect(stores.binders.changeToken == tokenBefore + 1)
    }

    // MARK: - insertPage

    @Test func insertPageShiftsLaterSheetsAndPreservesRefs() throws {
        let stores = try makeStores()
        let binder = try #require(stores.binders.createBinder(name: "Insert", coverColor: "#1B6CA8", pageCount: 3))
        let a = CardRef(cardID: "base1-4", variant: .holo)
        let b = CardRef(cardID: "base1-58", variant: .normal)
        let c = CardRef(cardID: "base1-4", variant: .reverse)
        stores.binders.assign(a, to: slot(binder.id, 0, .front, 0))
        stores.binders.assign(b, to: slot(binder.id, 1, .back, 2))
        stores.binders.assign(c, to: slot(binder.id, 2, .front, 8))

        #expect(stores.binders.insertPage(at: 1, in: binder.id))
        #expect(stores.binders.binders.first?.pageCount == 4)

        let after = layout(stores.binders, binder.id)
        #expect(after[slot(binder.id, 0, .front, 0)] == a)      // before the insert point: untouched
        #expect(after[slot(binder.id, 2, .back, 2)] == b)       // shifted up one sheet
        #expect(after[slot(binder.id, 3, .front, 8)] == c)
        #expect(after.count == 3)
    }

    @Test func insertIntoDenseBinderNeverCollidesPrimaryKeys() throws {
        let stores = try makeStores()
        let binder = try #require(stores.binders.createBinder(name: "Dense", coverColor: "#1B6CA8", pageCount: 3))
        // Fill every pocket of all 3 sheets (54 rows), then shift them all.
        for page in 0..<3 {
            for side in PageSide.allCases {
                for index in 0..<SpreadModel.slotsPerPage {
                    stores.binders.assign(CardRef(cardID: "base1-4", variant: .normal),
                                          to: slot(binder.id, page, side, index))
                }
            }
        }
        #expect(try rowCount(stores.user, binderID: binder.id) == 54)

        #expect(stores.binders.insertPage(at: 0, in: binder.id))
        #expect(try rowCount(stores.user, binderID: binder.id) == 54)
        let after = layout(stores.binders, binder.id)
        #expect(after.keys.allSatisfy { $0.pageIndex >= 1 && $0.pageIndex <= 3 })
    }

    @Test func insertAtEndAndOutOfRangeBounds() throws {
        let stores = try makeStores()
        let binder = try #require(stores.binders.createBinder(name: "Edges", coverColor: "#1B6CA8", pageCount: 2))
        let token = stores.binders.changeToken

        #expect(stores.binders.insertPage(at: 2, in: binder.id))    // == pageCount appends
        #expect(stores.binders.binders.first?.pageCount == 3)

        #expect(!stores.binders.insertPage(at: -1, in: binder.id))
        #expect(!stores.binders.insertPage(at: 5, in: binder.id))
        #expect(!stores.binders.insertPage(at: 0, in: "missing"))
        #expect(stores.binders.changeToken == token + 1)            // only the append bumped
    }

    // MARK: - removePage

    @Test func removePageDeletesItsRowsAndShiftsTheRest() throws {
        let stores = try makeStores()
        let binder = try #require(stores.binders.createBinder(name: "Remove", coverColor: "#1B6CA8", pageCount: 3))
        let keep0 = CardRef(cardID: "base1-4", variant: .holo)
        let gone = CardRef(cardID: "base1-58", variant: .normal)
        let keep2 = CardRef(cardID: "base1-4", variant: .reverse)
        stores.binders.assign(keep0, to: slot(binder.id, 0, .back, 1))
        stores.binders.assign(gone, to: slot(binder.id, 1, .front, 5))
        stores.binders.assign(gone, to: slot(binder.id, 1, .back, 6))
        stores.binders.assign(keep2, to: slot(binder.id, 2, .front, 7))

        #expect(stores.binders.removePage(at: 1, from: binder.id))
        #expect(stores.binders.binders.first?.pageCount == 2)

        let after = layout(stores.binders, binder.id)
        #expect(after.count == 2)                                   // sheet 1's two rows are gone
        #expect(after[slot(binder.id, 0, .back, 1)] == keep0)
        #expect(after[slot(binder.id, 1, .front, 7)] == keep2)      // sheet 2 slid down to 1
    }

    @Test func removeFirstPageOfDenseBinderNeverCollides() throws {
        let stores = try makeStores()
        let binder = try #require(stores.binders.createBinder(name: "Dense2", coverColor: "#1B6CA8", pageCount: 3))
        for page in 0..<3 {
            for side in PageSide.allCases {
                for index in 0..<SpreadModel.slotsPerPage {
                    stores.binders.assign(CardRef(cardID: "base1-4", variant: .normal),
                                          to: slot(binder.id, page, side, index))
                }
            }
        }
        #expect(stores.binders.removePage(at: 0, from: binder.id))
        #expect(try rowCount(stores.user, binderID: binder.id) == 36)
        let after = layout(stores.binders, binder.id)
        #expect(after.keys.allSatisfy { $0.pageIndex >= 0 && $0.pageIndex <= 1 })
    }

    /// Unlike sort() — which leaves orphans alone by contract — the page ops
    /// shift orphan rows (page_index beyond the page range) along with
    /// everything else, so a shrink-then-remove never doubles rows up.
    @Test func pageOpsShiftOrphanRowsToo() throws {
        let stores = try makeStores()
        let binder = try #require(stores.binders.createBinder(name: "Orphans", coverColor: "#1B6CA8", pageCount: 2))
        let orphan = CardRef(cardID: "base1-58", variant: .holo)
        stores.binders.assign(orphan, to: slot(binder.id, 5, .front, 0))

        #expect(stores.binders.insertPage(at: 0, in: binder.id))
        #expect(layout(stores.binders, binder.id)[slot(binder.id, 6, .front, 0)] == orphan)

        #expect(stores.binders.removePage(at: 0, from: binder.id))
        #expect(layout(stores.binders, binder.id)[slot(binder.id, 5, .front, 0)] == orphan)
    }

    @Test func removePageBoundsAndEmptyBinder() throws {
        let stores = try makeStores()
        let binder = try #require(stores.binders.createBinder(name: "Bounds", coverColor: "#1B6CA8", pageCount: 1))
        #expect(!stores.binders.removePage(at: 1, from: binder.id))
        #expect(!stores.binders.removePage(at: -1, from: binder.id))

        stores.binders.assign(CardRef(cardID: "base1-4", variant: .normal),
                              to: slot(binder.id, 0, .front, 0))
        #expect(stores.binders.assignmentCount(binderID: binder.id, pageIndex: 0) == 1)

        #expect(stores.binders.removePage(at: 0, from: binder.id))
        #expect(stores.binders.binders.first?.pageCount == 0)
        #expect(!stores.binders.removePage(at: 0, from: binder.id))  // nothing left to remove
        #expect(stores.binders.spreadCount(binderID: binder.id) == 1)
    }

    @Test func removingTheOnlyCardBearingPageLeavesCoherentSpreads() async throws {
        let stores = try makeStores()
        let binder = try #require(stores.binders.createBinder(name: "Last", coverColor: "#1B6CA8", pageCount: 2))
        stores.binders.assign(CardRef(cardID: "base1-4", variant: .holo),
                              to: slot(binder.id, 0, .front, 0))

        #expect(stores.binders.removePage(at: 0, from: binder.id))
        let spread = try await stores.binders.spread(0, in: binder.id)
        #expect(spread.right.allSatisfy { $0 == nil })
        #expect(try rowCount(stores.user, binderID: binder.id) == 0)
    }
}

@MainActor struct DisplayCaseConfigTests {
    private func makeBinders(_ user: UserDatabase) throws -> BinderStore {
        BinderStore(database: user, catalog: try TestCatalog.makeCatalog()) { _ in true }
    }

    @Test func growShrinkClampAndTrailingClear() throws {
        let user = try UserDatabase.inMemory()
        let binders = try makeBinders(user)
        #expect(binders.displayCaseCount == BinderStore.displayCaseMinCount)

        #expect(binders.setDisplayCaseCount(5))
        #expect(binders.displayCaseCount == 5)
        binders.setDisplayCase(CardRef(cardID: "base1-4", variant: .holo), at: 4)
        #expect(binders.displayCase[4] != nil)

        // Shrinking clears the trailing rows in the same transaction.
        #expect(binders.setDisplayCaseCount(3))
        #expect(binders.displayCaseCount == 3)
        let rows = try user.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM display_case") ?? 0
        }
        #expect(rows == 0)

        // Clamps: below min is min (no-op from 3), above max is max.
        #expect(!binders.setDisplayCaseCount(1))
        #expect(binders.setDisplayCaseCount(9))
        #expect(binders.displayCaseCount == BinderStore.displayCaseMaxCount)
    }

    @Test func loadRestoresCountAndContents() async throws {
        let user = try UserDatabase.inMemory()
        let first = try makeBinders(user)
        #expect(first.setDisplayCaseCount(4))
        first.setDisplayCase(CardRef(cardID: "base1-58", variant: .normal), at: 3)

        let second = try makeBinders(user)
        await second.load()
        #expect(second.displayCaseCount == 4)
        #expect(second.displayCase[3] == CardRef(cardID: "base1-58", variant: .normal))
        #expect(second.firstEmptyDisplaySlot() == 0)
    }
}
