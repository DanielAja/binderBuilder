//
//  GroupStoreTests.swift
//  binderBuilderTests
//

import Foundation
import Testing
@testable import binderBuilder

@MainActor struct GroupStoreTests {
    @Test func createAddRemoveAndReload() throws {
        let user = try UserDatabase.inMemory()
        let store = GroupStore(database: user)
        let holo = CardRef(cardID: "base1-4", variant: .holo)
        let reverse = CardRef(cardID: "base1-2", variant: .reverse)

        let trade = try #require(store.createGroup(name: "For Trade"))
        let faves = try #require(store.createGroup(name: "Favorites"))
        #expect(store.groups.count == 2)
        #expect(trade.color != "")  // assigned from palette

        store.setMember(holo, group: trade.id, member: true)
        #expect(store.toggle(reverse, group: trade.id) == true)
        store.setMember(holo, group: faves.id, member: true)

        #expect(store.memberCount(trade.id) == 2)
        #expect(store.isMember(holo, of: trade.id))
        #expect(Set(store.groups(for: holo).map(\.id)) == [trade.id, faves.id])

        #expect(store.toggle(reverse, group: trade.id) == false)  // remove
        #expect(store.memberCount(trade.id) == 1)

        // Reload from DB.
        let reloaded = GroupStore(database: user)
        #expect(reloaded.groups.count == 2)
        #expect(reloaded.isMember(holo, of: trade.id))
        #expect(reloaded.memberCount(trade.id) == 1)

        // Deleting a group cascades its members.
        reloaded.deleteGroup(trade.id)
        #expect(reloaded.groups.count == 1)
        #expect(GroupStore(database: user).memberCount(trade.id) == 0)
    }
}
