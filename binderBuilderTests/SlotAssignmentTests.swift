//
//  SlotAssignmentTests.swift
//  binderBuilderTests
//

import Foundation
import GRDB
import Testing
@testable import binderBuilder

@MainActor struct SlotAssignmentTests {
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

    private func assignmentCount(_ user: UserDatabase, binderID: String? = nil) throws -> Int {
        try user.queue.read { db in
            if let binderID {
                return try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM slot_assignment WHERE binder_id = ?",
                    arguments: [binderID]) ?? 0
            }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM slot_assignment") ?? 0
        }
    }

    // MARK: - Assignment

    @Test func assignOverwriteAndClear() async throws {
        let stores = try makeStores()
        let binder = try #require(stores.binders.createBinder(name: "Fire", coverColor: "#D2042D"))
        let slot = SlotLocation(binderID: binder.id, pageIndex: 0, side: .front, slotIndex: 0)

        stores.binders.assign(CardRef(cardID: "base1-4", variant: .holo), to: slot)
        var spread = try await stores.binders.spread(0, in: binder.id)
        #expect(spread.right[0]?.card.id == "base1-4")
        #expect(spread.right[0]?.variant == .holo)

        // Overwriting the same pocket replaces, not duplicates.
        stores.binders.assign(CardRef(cardID: "base1-58", variant: .normal), to: slot)
        #expect(try assignmentCount(stores.user) == 1)
        spread = try await stores.binders.spread(0, in: binder.id)
        #expect(spread.right[0]?.card.id == "base1-58")
        #expect(spread.right[0]?.variant == .normal)

        stores.binders.clear(slot: slot)
        #expect(try assignmentCount(stores.user) == 0)
        spread = try await stores.binders.spread(0, in: binder.id)
        #expect(spread.right[0] == nil)

        // Out-of-range slot indices are rejected.
        stores.binders.assign(
            CardRef(cardID: "base1-4", variant: .holo),
            to: SlotLocation(binderID: binder.id, pageIndex: 0, side: .front, slotIndex: 9))
        #expect(try assignmentCount(stores.user) == 0)
    }

    @Test func ownedFlagComesFromTheInjectedClosure() async throws {
        let stores = try makeStores()
        let binder = try #require(stores.binders.createBinder(name: "Owned", coverColor: "#000000"))
        let ref = CardRef(cardID: "base1-4", variant: .holo)
        stores.binders.assign(ref, to: SlotLocation(binderID: binder.id, pageIndex: 0, side: .front, slotIndex: 4))

        var spread = try await stores.binders.spread(0, in: binder.id)
        #expect(spread.right[4]?.owned == false)

        stores.collection.setOwned(ref, quantity: 1)
        spread = try await stores.binders.spread(0, in: binder.id)
        #expect(spread.right[4]?.owned == true)

        // Owning a different variant of the same card does not count.
        let otherVariant = CardRef(cardID: "base1-4", variant: .firstEdition)
        stores.collection.setOwned(ref, quantity: 0)
        stores.collection.setOwned(otherVariant, quantity: 1)
        spread = try await stores.binders.spread(0, in: binder.id)
        #expect(spread.right[4]?.owned == false)
    }

    // MARK: - Cascade delete

    @Test func deletingABinderCascadesToItsAssignments() throws {
        let stores = try makeStores()
        let keep = try #require(stores.binders.createBinder(name: "Keep", coverColor: "#00FF00"))
        let doomed = try #require(stores.binders.createBinder(name: "Doomed", coverColor: "#FF0000"))

        for slotIndex in 0..<3 {
            stores.binders.assign(
                CardRef(cardID: "base1-46", variant: .normal),
                to: SlotLocation(binderID: doomed.id, pageIndex: 0, side: .front, slotIndex: slotIndex))
        }
        stores.binders.assign(
            CardRef(cardID: "base1-4", variant: .holo),
            to: SlotLocation(binderID: keep.id, pageIndex: 1, side: .back, slotIndex: 8))
        #expect(try assignmentCount(stores.user) == 4)

        stores.binders.deleteBinder(doomed.id)
        #expect(stores.binders.binders.map(\.id) == [keep.id])
        #expect(try assignmentCount(stores.user, binderID: doomed.id) == 0)
        #expect(try assignmentCount(stores.user, binderID: keep.id) == 1)
    }

    // MARK: - Spread mapping

    /// Spread s shows sheet (s-1)'s BACK on the left and sheet s's FRONT on
    /// the right; spread 0 has no left page, spread N no right page.
    @Test func spreadMappingMatchesPhysicalSheets() async throws {
        let stores = try makeStores()
        let binder = try #require(
            stores.binders.createBinder(name: "Map", coverColor: "#1B6CA8", pageCount: 2))
        #expect(stores.binders.spreadCount(binderID: binder.id) == 3)

        let a = CardRef(cardID: "base1-4", variant: .holo)       // sheet 0 front, slot 0
        let b = CardRef(cardID: "base1-24", variant: .normal)    // sheet 0 back, slot 4
        let c = CardRef(cardID: "base1-46", variant: .normal)    // sheet 1 front, slot 8
        let d = CardRef(cardID: "base1-58", variant: .normal)    // sheet 1 back, slot 2
        stores.binders.assign(a, to: SlotLocation(binderID: binder.id, pageIndex: 0, side: .front, slotIndex: 0))
        stores.binders.assign(b, to: SlotLocation(binderID: binder.id, pageIndex: 0, side: .back, slotIndex: 4))
        stores.binders.assign(c, to: SlotLocation(binderID: binder.id, pageIndex: 1, side: .front, slotIndex: 8))
        stores.binders.assign(d, to: SlotLocation(binderID: binder.id, pageIndex: 1, side: .back, slotIndex: 2))

        // Spread 0: left page is the inside cover (all nil), right = sheet 0 front.
        let spread0 = try await stores.binders.spread(0, in: binder.id)
        #expect(spread0.left.allSatisfy { $0 == nil })
        #expect(spread0.right[0]?.card.id == "base1-4")
        #expect(spread0.right.filter { $0 != nil }.count == 1)

        // Spread 1: left = sheet 0 back, right = sheet 1 front.
        let spread1 = try await stores.binders.spread(1, in: binder.id)
        #expect(spread1.left[4]?.card.id == "base1-24")
        #expect(spread1.left.filter { $0 != nil }.count == 1)
        #expect(spread1.right[8]?.card.id == "base1-46")
        #expect(spread1.right.filter { $0 != nil }.count == 1)

        // Spread 2 (== pageCount): left = sheet 1 back, right is the inside
        // back cover (all nil).
        let spread2 = try await stores.binders.spread(2, in: binder.id)
        #expect(spread2.left[2]?.card.id == "base1-58")
        #expect(spread2.left.filter { $0 != nil }.count == 1)
        #expect(spread2.right.allSatisfy { $0 == nil })

        // Out-of-range spreads are empty, not a crash.
        let beyond = try await stores.binders.spread(3, in: binder.id)
        #expect(beyond == .empty)
        let negative = try await stores.binders.spread(-1, in: binder.id)
        #expect(negative == .empty)
    }

    @Test func occupiedSlotCountsPerSide() throws {
        let stores = try makeStores()
        let binder = try #require(stores.binders.createBinder(name: "Mass", coverColor: "#333333"))

        for slotIndex in 0..<5 {
            stores.binders.assign(
                CardRef(cardID: "swsh9-1", variant: .normal),
                to: SlotLocation(binderID: binder.id, pageIndex: 3, side: .front, slotIndex: slotIndex))
        }
        for slotIndex in 0..<2 {
            stores.binders.assign(
                CardRef(cardID: "swsh9-25", variant: .holo),
                to: SlotLocation(binderID: binder.id, pageIndex: 3, side: .back, slotIndex: slotIndex))
        }

        let counts = stores.binders.occupiedSlotCounts(binderID: binder.id, pageIndex: 3)
        #expect(counts.front == 5)
        #expect(counts.back == 2)

        let empty = stores.binders.occupiedSlotCounts(binderID: binder.id, pageIndex: 0)
        #expect(empty.front == 0)
        #expect(empty.back == 0)
    }

    // MARK: - Display case

    @Test func displayCaseStoresThreeSlotsAndIgnoresOutOfBounds() async throws {
        let stores = try makeStores()
        let mew = CardRef(cardID: "swsh9-TG12", variant: .holo)
        let zard = CardRef(cardID: "base1-4", variant: .firstEdition)

        stores.binders.setDisplayCase(mew, at: 0)
        stores.binders.setDisplayCase(zard, at: 2)
        #expect(stores.binders.displayCase == [mew, nil, zard])

        // Out-of-bounds positions are no-ops.
        stores.binders.setDisplayCase(mew, at: 3)
        stores.binders.setDisplayCase(mew, at: -1)
        #expect(stores.binders.displayCase == [mew, nil, zard])

        // Clearing and persistence across a fresh store on the same database.
        stores.binders.setDisplayCase(nil, at: 0)
        #expect(stores.binders.displayCase == [nil, nil, zard])

        let reloaded = BinderStore(database: stores.user, catalog: nil) { _ in false }
        await reloaded.load()
        #expect(reloaded.displayCase == [nil, nil, zard])
    }

    // MARK: - Binder CRUD details

    @Test func createOrdersBySortOrderAndRenamePersists() async throws {
        let stores = try makeStores()
        let first = try #require(stores.binders.createBinder(name: "One", coverColor: "#111111"))
        let second = try #require(stores.binders.createBinder(name: "Two", coverColor: "#222222"))
        #expect(first.sortOrder < second.sortOrder)
        #expect(first.pageCount == 10)

        stores.binders.renameBinder(first.id, to: "One Renamed")
        let reloaded = BinderStore(database: stores.user, catalog: nil) { _ in false }
        await reloaded.load()
        #expect(reloaded.binders.map(\.name) == ["One Renamed", "Two"])
        #expect(reloaded.binders.map(\.id) == [first.id, second.id])
    }

    @Test func spreadWithoutCatalogHasEmptyPocketsButKeepsRows() async throws {
        let user = try UserDatabase.inMemory()
        let collection = CollectionStore(database: user)
        let binders = BinderStore(database: user, catalog: nil) { collection.isOwned($0) }
        let binder = try #require(binders.createBinder(name: "No Catalog", coverColor: "#ABCDEF"))
        binders.assign(
            CardRef(cardID: "base1-4", variant: .holo),
            to: SlotLocation(binderID: binder.id, pageIndex: 0, side: .front, slotIndex: 0))

        // The assignment row is preserved...
        let count = try await user.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM slot_assignment") ?? 0
        }
        #expect(count == 1)
        // ...but renders as an empty pocket without card metadata.
        let spread = try await binders.spread(0, in: binder.id)
        #expect(spread.right[0] == nil)
    }
}
