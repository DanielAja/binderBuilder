//
//  CollectionTests.swift
//  binderBuilderTests
//

import Foundation
import GRDB
import Testing
@testable import binderBuilder

@MainActor struct CollectionTests {
    private func ownedRowCount(_ user: UserDatabase) throws -> Int {
        try user.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM owned_card") ?? 0
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
        #expect(store.ownedCount == 2)
        #expect(Set(store.ownedRefs()) == [holo, firstEdition])

        // Quantity update keeps a single row.
        store.setOwned(firstEdition, quantity: 5)
        #expect(store.quantity(of: firstEdition) == 5)
        #expect(try ownedRowCount(user) == 2)

        // Variants are tracked independently.
        #expect(store.isOwned(CardRef(cardID: "base1-4", variant: .normal)) == false)
    }

    @Test func zeroQuantityRemovesTheRow() throws {
        let user = try UserDatabase.inMemory()
        let store = CollectionStore(database: user)
        let ref = CardRef(cardID: "swsh9-1", variant: .reverse)

        store.setOwned(ref, quantity: 2)
        #expect(try ownedRowCount(user) == 1)

        store.setOwned(ref, quantity: 0)
        #expect(store.isOwned(ref) == false)
        #expect(store.quantity(of: ref) == 0)
        #expect(store.ownedCount == 0)
        #expect(try ownedRowCount(user) == 0)

        // Negative quantities behave like 0.
        store.setOwned(ref, quantity: 4)
        store.setOwned(ref, quantity: -1)
        #expect(try ownedRowCount(user) == 0)
        #expect(store.isOwned(ref) == false)
    }

    @Test func stateReloadsFromTheDatabase() throws {
        let user = try UserDatabase.inMemory()
        let ref = CardRef(cardID: "swsh9-TG12", variant: .holo)
        do {
            let store = CollectionStore(database: user)
            store.setOwned(ref, quantity: 2)
        }
        let reloaded = CollectionStore(database: user)
        #expect(reloaded.isOwned(ref) == true)
        #expect(reloaded.quantity(of: ref) == 2)
        #expect(reloaded.ownedCount == 1)
        #expect(reloaded.ownedRefs() == [ref])
    }
}
