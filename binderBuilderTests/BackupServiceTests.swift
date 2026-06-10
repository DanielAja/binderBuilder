//
//  BackupServiceTests.swift
//  binderBuilderTests
//

import Foundation
import GRDB
import Testing
@testable import binderBuilder

@MainActor struct BackupServiceTests {
    @Test func exportThenRestoreRoundTrips() throws {
        let user = try UserDatabase.inMemory()
        let collection = CollectionStore(database: user)
        let wishlist = WishlistStore(database: user)
        let binders = BinderStore(database: user, catalog: nil, isOwned: { collection.isOwned($0) })

        let holo = CardRef(cardID: "base1-4", variant: .holo)
        collection.addCopy(holo, condition: .lp, grade: CardGrade(company: .psa, value: 10), acquiredPrice: 500)
        collection.addCopy(holo, condition: .nm)
        wishlist.set(CardRef(cardID: "base1-2", variant: .normal), wished: true)
        let binder = try #require(binders.createBinder(name: "My Binder", coverColor: "#1B6CA8", pageCount: 2))
        binders.assign(holo, to: SlotLocation(binderID: binder.id, pageIndex: 0, side: .front, slotIndex: 0))

        let data = try BackupService.export(user)

        // Wipe everything, then restore.
        try user.queue.write { db in
            for t in ["card_copy", "wishlist", "slot_assignment", "display_case", "binder"] {
                try db.execute(sql: "DELETE FROM \(t)")
            }
        }
        try BackupService.restore(data, into: user)

        // Fresh stores read the restored data.
        let collection2 = CollectionStore(database: user)
        #expect(collection2.quantity(of: holo) == 2)
        let graded = collection2.copies(of: holo).first { $0.isGraded }
        #expect(graded?.grade?.label == "PSA 10")
        #expect(graded?.acquiredPrice == 500)
        #expect(collection2.copies(of: holo).contains { $0.condition == .lp })

        let wishlist2 = WishlistStore(database: user)
        #expect(wishlist2.isWished(CardRef(cardID: "base1-2", variant: .normal)))

        let binders2 = BinderStore(database: user, catalog: nil, isOwned: { _ in false })
        #expect(binders2.binders.count == 1)
        #expect(binders2.firstEmptySlot(binderID: binder.id) ==
                SlotLocation(binderID: binder.id, pageIndex: 0, side: .front, slotIndex: 1))
    }
}
