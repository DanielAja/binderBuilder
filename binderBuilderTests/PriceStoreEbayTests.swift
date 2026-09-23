//
//  PriceStoreEbayTests.swift
//  binderBuilderTests
//
//  The optional eBay provider follows Settings live: never built while eBay
//  is off or unconfigured, built once for a set of keys, rebuilt when the
//  keys change.
//

import Foundation
import Testing
@testable import binderBuilder

@MainActor @Suite struct PriceStoreEbayTests {
    nonisolated struct EmptyProvider: PriceProvider {
        let id: String
        func quotes(for card: CardSummary) async throws -> [PriceQuote] { [] }
    }

    final class FactoryLog { var built: [String] = [] }

    @Test func ebayProviderFollowsTheSettings() async throws {
        let catalog = try TestCatalog.makeCatalog()
        let card = try #require(try await catalog.card(id: "base1-4")).summary
        let settings = SettingsStore(
            defaults: UserDefaults(suiteName: "PriceStoreEbayTests-\(UUID())")!, keychain: FakeKeychain())
        let log = FactoryLog()
        let store = PriceStore(
            database: try UserDatabase.inMemory(), catalog: catalog, settings: settings,
            tcgdexProvider: EmptyProvider(id: "tcgdex"),
            makeEbayProvider: { appID, certID in
                log.built.append("\(appID):\(certID)")
                return EmptyProvider(id: "ebay")
            })

        await store.refreshIfStale(card: card)
        #expect(log.built.isEmpty)                 // off

        settings.ebayEnabled = true
        await store.refreshIfStale(card: card)
        #expect(log.built.isEmpty)                 // on, but no keys

        settings.ebayAppID = "app"
        settings.ebayCertID = "cert"
        await store.refreshIfStale(card: card)
        await store.refreshIfStale(card: card)
        #expect(log.built == ["app:cert"])         // built once, then reused

        settings.ebayCertID = "cert2"
        await store.refreshIfStale(card: card)
        #expect(log.built == ["app:cert", "app:cert2"])
    }
}
