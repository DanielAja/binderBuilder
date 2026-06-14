//
//  CollectionTests.swift
//  binderBuilderTests
//

import Foundation
import GRDB
import Testing
@testable import binderBuilder

@MainActor struct CollectionTests {
    /// Total physical copies (card_copy rows).
    private func copyRowCount(_ user: UserDatabase) throws -> Int {
        try user.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM card_copy") ?? 0
        }
    }

    @Test func setOwnedIsOwnedQuantityRoundTrip() throws {
        let user = try UserDatabase.inMemory()
        let store = CollectionStore(database: user)
        let holo = CardRef(cardID: "base1-4", variant: .holo)
        let firstEdition = CardRef(cardID: "base1-4", variant: .firstEdition)

        #expect(store.isOwned(holo) == false)
        #expect(store.quantity(of: holo) == 0)
        #expect(store.ownedCount == 0)

        store.setOwned(holo)            // default quantity 1
        store.setOwned(firstEdition, quantity: 3)

        #expect(store.isOwned(holo) == true)
        #expect(store.quantity(of: holo) == 1)
        #expect(store.quantity(of: firstEdition) == 3)
        #expect(store.ownedCount == 2)                       // distinct printings
        #expect(Set(store.ownedRefs()) == [holo, firstEdition])

        // Quantity increase adds copies (one card_copy row per copy).
        store.setOwned(firstEdition, quantity: 5)
        #expect(store.quantity(of: firstEdition) == 5)
        #expect(store.ownedCount == 2)
        #expect(try copyRowCount(user) == 6)                 // 1 + 5

        #expect(store.isOwned(CardRef(cardID: "base1-4", variant: .normal)) == false)
    }

    @Test func zeroQuantityRemovesAllCopies() throws {
        let user = try UserDatabase.inMemory()
        let store = CollectionStore(database: user)
        let ref = CardRef(cardID: "swsh9-1", variant: .reverse)

        store.setOwned(ref, quantity: 2)
        #expect(try copyRowCount(user) == 2)

        store.setOwned(ref, quantity: 0)
        #expect(store.isOwned(ref) == false)
        #expect(store.ownedCount == 0)
        #expect(try copyRowCount(user) == 0)

        store.setOwned(ref, quantity: 4)
        store.setOwned(ref, quantity: -1)            // negative behaves like 0
        #expect(try copyRowCount(user) == 0)
    }

    @Test func stateReloadsFromTheDatabase() async throws {
        let user = try UserDatabase.inMemory()
        let ref = CardRef(cardID: "swsh9-TG12", variant: .holo)
        do {
            let store = CollectionStore(database: user)
            store.setOwned(ref, quantity: 2)
        }
        let reloaded = CollectionStore(database: user)
        await reloaded.load()
        #expect(reloaded.isOwned(ref) == true)
        #expect(reloaded.quantity(of: ref) == 2)
        #expect(reloaded.ownedCount == 1)
        #expect(reloaded.ownedRefs() == [ref])
    }

    @Test func copyCRUDWithConditionAndGrade() throws {
        let user = try UserDatabase.inMemory()
        let store = CollectionStore(database: user)
        let ref = CardRef(cardID: "base1-4", variant: .holo)

        let raw = store.addCopy(ref, condition: .lp, acquiredPrice: 120)
        let graded = store.addCopy(ref, condition: .nm,
                                   grade: CardGrade(company: .psa, value: 10), acquiredPrice: 1500)
        #expect(raw != nil && graded != nil)
        #expect(store.quantity(of: ref) == 2)

        var copies = store.copies(of: ref)
        #expect(copies.count == 2)
        #expect(copies.contains { $0.isGraded && $0.grade?.label == "PSA 10" })

        // Update the raw copy's condition.
        var updated = copies.first { !$0.isGraded }!
        updated.condition = .mp
        updated.notes = "edge wear"
        store.updateCopy(updated)
        copies = store.copies(of: ref)
        #expect(copies.first { $0.id == updated.id }?.condition == .mp)
        #expect(copies.first { $0.id == updated.id }?.notes == "edge wear")

        store.removeCopy(updated.id)
        #expect(store.quantity(of: ref) == 1)
        #expect(store.copies(of: ref).allSatisfy { $0.isGraded })
    }

    @Test func setOwnedDecrementPreservesGradedCopies() throws {
        let user = try UserDatabase.inMemory()
        let store = CollectionStore(database: user)
        let ref = CardRef(cardID: "base1-4", variant: .holo)

        store.addCopy(ref, condition: .nm)                                   // raw
        store.addCopy(ref, condition: .nm, grade: CardGrade(company: .psa, value: 9)) // graded
        #expect(store.quantity(of: ref) == 2)

        // Decrement to 1 should drop the raw copy, keep the graded slab.
        store.setOwned(ref, quantity: 1)
        #expect(store.quantity(of: ref) == 1)
        #expect(store.copies(of: ref).first?.isGraded == true)
    }
}
