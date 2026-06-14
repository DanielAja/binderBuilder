//
//  CollectingDataTests.swift
//  binderBuilderTests
//
//  Wishlist store + catalog collection-aggregate queries (set completion,
//  stats facets, bundled value).
//

import Foundation
import Testing
@testable import binderBuilder

@MainActor struct WishlistStoreTests {
    @Test func toggleSetAndReload() async throws {
        let user = try UserDatabase.inMemory()
        let store = WishlistStore(database: user)
        let holo = CardRef(cardID: "base1-4", variant: .holo)
        let reverse = CardRef(cardID: "base1-4", variant: .reverse)

        #expect(store.isWished(holo) == false)
        #expect(store.toggle(holo) == true)
        #expect(store.isWished(holo) == true)
        // Per-variant: wishing holo does not wish reverse.
        #expect(store.isWished(reverse) == false)
        store.set(reverse, wished: true)
        #expect(store.count == 2)
        #expect(Set(store.wishedRefs()) == [holo, reverse])

        #expect(store.toggle(holo) == false)
        #expect(store.isWished(holo) == false)
        #expect(store.count == 1)

        // Reloads from the database.
        let reloaded = WishlistStore(database: user)
        await reloaded.load()
        #expect(reloaded.isWished(reverse) == true)
        #expect(reloaded.count == 1)
    }
}

struct CatalogAggregateTests {
    @Test func ownedCardCountsBySet() async throws {
        let catalog = try TestCatalog.makeCatalog()
        let counts = try await catalog.ownedCardCounts(
            forCardIDs: ["base1-4", "base1-24", "swsh9-1", "ghost-0"])
        #expect(counts["base1"] == 2)
        #expect(counts["swsh9"] == 1)
        #expect(counts["ghost"] == nil)

        #expect(try await catalog.ownedCardCounts(forCardIDs: []).isEmpty)
    }

    @Test func cardFacetsHistograms() async throws {
        let catalog = try TestCatalog.makeCatalog()
        let facets = try await catalog.cardFacets(forCardIDs: ["base1-4"])
        #expect(facets.rarities["Rare Holo"] == 1)
        #expect(facets.types["Fire"] == 1)
    }

    @Test func bundledMarketPerPrinting() async throws {
        let catalog = try TestCatalog.makeCatalog()
        let market = try await catalog.bundledMarket(for: [
            CardRef(cardID: "base1-4", variant: .holo),
            CardRef(cardID: "base1-4", variant: .firstEdition),
            CardRef(cardID: "base1-58", variant: .normal) // no snapshot row
        ])
        #expect(market[CardRef(cardID: "base1-4", variant: .holo)] == 420.5)
        #expect(market[CardRef(cardID: "base1-4", variant: .firstEdition)] == 5200.0)
        #expect(market[CardRef(cardID: "base1-58", variant: .normal)] == nil)
    }
}
