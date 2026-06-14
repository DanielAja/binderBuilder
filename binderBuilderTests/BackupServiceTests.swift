//
//  BackupServiceTests.swift
//  binderBuilderTests
//

import Foundation
import GRDB
import Testing
@testable import binderBuilder

@MainActor struct BackupServiceTests {
    @Test func exportThenRestoreRoundTrips() async throws {
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
        try await user.queue.write { db in
            for t in ["card_copy", "wishlist", "slot_assignment", "display_case", "binder"] {
                try db.execute(sql: "DELETE FROM \(t)")
            }
        }
        try BackupService.restore(data, into: user)

        // Fresh stores read the restored data.
        let collection2 = CollectionStore(database: user)
        await collection2.load()
        #expect(collection2.quantity(of: holo) == 2)
        let graded = collection2.copies(of: holo).first { $0.isGraded }
        #expect(graded?.grade?.label == "PSA 10")
        #expect(graded?.acquiredPrice == 500)
        #expect(collection2.copies(of: holo).contains { $0.condition == .lp })

        let wishlist2 = WishlistStore(database: user)
        await wishlist2.load()
        #expect(wishlist2.isWished(CardRef(cardID: "base1-2", variant: .normal)))

        let binders2 = BinderStore(database: user, catalog: nil, isOwned: { _ in false })
        await binders2.load()
        #expect(binders2.binders.count == 1)
        #expect(binders2.firstEmptySlot(binderID: binder.id) ==
                SlotLocation(binderID: binder.id, pageIndex: 0, side: .front, slotIndex: 1))
    }

    @Test func backupIncludesGroupsAndAlerts() async throws {
        let user = try UserDatabase.inMemory()
        let groups = GroupStore(database: user)
        let alerts = AlertStore(database: user)
        let holo = CardRef(cardID: "base1-4", variant: .holo)

        let g = try #require(groups.createGroup(name: "Vintage"))
        groups.setMember(holo, group: g.id, member: true)
        alerts.setAlert(holo, kind: .percentDrop, threshold: 15, baseline: 400)

        let data = try BackupService.export(user)
        try await user.queue.write { db in
            for t in ["group_member", "card_group", "price_alert"] { try db.execute(sql: "DELETE FROM \(t)") }
        }
        try BackupService.restore(data, into: user)

        let groups2 = GroupStore(database: user)
        await groups2.load()
        #expect(groups2.groups.first?.name == "Vintage")
        #expect(groups2.isMember(holo, of: g.id))
        let alerts2 = AlertStore(database: user)
        await alerts2.load()
        #expect(alerts2.alert(for: holo)?.kind == .percentDrop)
        #expect(alerts2.alert(for: holo)?.baseline == 400)
    }
}
