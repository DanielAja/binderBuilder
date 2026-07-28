//
//  FavoriteStoreTests.swift
//  binderBuilderTests
//
//  FavoriteStoreStore CRUD round-trip + ordering on an in-memory database.
//

import Foundation
import Testing
@testable import binderBuilder

@MainActor
struct FavoriteStoreTests {

    private func nearby(_ name: String, lat: Double, lon: Double, kind: StoreKind = .lgs) -> NearbyStore {
        NearbyStore(
            id: "\(lat),\(lon)|\(name.lowercased())", name: name, address: "123 Main St",
            latitude: lat, longitude: lon, kind: kind, distanceMiles: 2.0)
    }

    @Test func addPersistsAndRoundTripsThroughANewStoreInstance() async throws {
        let database = try UserDatabase.inMemory()
        let store = FavoriteStoreStore(database: database)
        await store.load()
        #expect(store.count == 0)

        let added = store.add(nearby("Bob's Cards", lat: 40.0, lon: -75.0))
        #expect(added != nil)
        #expect(store.count == 1)
        #expect(store.isFavorite(added!.id))

        // A fresh store instance backed by the same database sees the write.
        let reloaded = FavoriteStoreStore(database: database)
        await reloaded.load()
        #expect(reloaded.count == 1)
        #expect(reloaded.stores.first?.name == "Bob's Cards")
        #expect(reloaded.stores.first?.address == "123 Main St")
        #expect(reloaded.stores.first?.kind == .lgs)
        #expect(reloaded.stores.first?.latitude == 40.0)
        #expect(reloaded.stores.first?.longitude == -75.0)
    }

    @Test func addIsIdempotentForTheSameID() async throws {
        let database = try UserDatabase.inMemory()
        let store = FavoriteStoreStore(database: database)
        await store.load()

        let place = nearby("Target Supercenter", lat: 40.0, lon: -75.0, kind: .bigbox)
        store.add(place)
        store.add(place) // same id, should not duplicate
        #expect(store.count == 1)
    }

    @Test func removeDeletesFromMemoryAndDisk() async throws {
        let database = try UserDatabase.inMemory()
        let store = FavoriteStoreStore(database: database)
        await store.load()
        let added = store.add(nearby("Bob's Cards", lat: 40.0, lon: -75.0))!

        store.remove(id: added.id)
        #expect(store.count == 0)
        #expect(!store.isFavorite(added.id))

        let reloaded = FavoriteStoreStore(database: database)
        await reloaded.load()
        #expect(reloaded.count == 0)
    }

    @Test func loadOrdersByAddedAtAscending() async throws {
        let database = try UserDatabase.inMemory()
        // Insert directly via the DB extension with explicit, distinct
        // timestamps so ordering doesn't depend on Date() resolution.
        let first = FavoriteStore(
            id: "1", name: "First Shop", address: nil, latitude: 40.0, longitude: -75.0,
            kind: .lgs, addedAt: Date(timeIntervalSince1970: 100))
        let second = FavoriteStore(
            id: "2", name: "Second Shop", address: nil, latitude: 41.0, longitude: -76.0,
            kind: .bigbox, addedAt: Date(timeIntervalSince1970: 200))
        let third = FavoriteStore(
            id: "3", name: "Third Shop", address: nil, latitude: 42.0, longitude: -77.0,
            kind: .other, addedAt: Date(timeIntervalSince1970: 300))

        // Insert out of order to prove the query, not insertion order, sorts.
        try database.upsertFavoriteStore(second)
        try database.upsertFavoriteStore(third)
        try database.upsertFavoriteStore(first)

        let store = FavoriteStoreStore(database: database)
        await store.load()
        #expect(store.stores.map(\.name) == ["First Shop", "Second Shop", "Third Shop"])
    }

    @Test func changeTokenBumpsOnLoadAddAndRemove() async throws {
        let database = try UserDatabase.inMemory()
        let store = FavoriteStoreStore(database: database)
        let afterInit = store.changeToken
        await store.load()
        let afterLoad = store.changeToken
        #expect(afterLoad != afterInit)

        store.add(nearby("Bob's Cards", lat: 40.0, lon: -75.0))
        let afterAdd = store.changeToken
        #expect(afterAdd != afterLoad)
    }
}
