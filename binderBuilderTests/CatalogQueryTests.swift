//
//  CatalogQueryTests.swift
//  binderBuilderTests
//

import Foundation
import Testing
@testable import binderBuilder

struct CatalogQueryTests {
    @Test func prefixSearchFindsTheCharEvolutionLine() async throws {
        let catalog = try TestCatalog.makeCatalog()
        let results = try await catalog.searchCards(matching: "char", limit: 10)
        #expect(results.count == 3)
        #expect(Set(results.map(\.name)) == ["Charizard", "Charmeleon", "Charmander"])
        // An exact-name query must rank the exact card first (bm25 order).
        let exact = try await catalog.searchCards(matching: "charizard", limit: 10)
        #expect(exact.first?.id == "base1-4")
    }

    @Test func multiTokenSearchIsAndAcrossNameAndSetName() async throws {
        let catalog = try TestCatalog.makeCatalog()
        let results = try await catalog.searchCards(matching: "charizard base", limit: 10)
        #expect(results.map(\.id) == ["base1-4"])
    }

    @Test func searchMatchesNonNumericLocalNumber() async throws {
        let catalog = try TestCatalog.makeCatalog()
        let results = try await catalog.searchCards(matching: "tg1", limit: 10)
        #expect(results.map(\.id) == ["swsh9-TG12"])
    }

    @Test func blankAndQuoteOnlyQueriesReturnEmpty() async throws {
        let catalog = try TestCatalog.makeCatalog()
        let blank = try await catalog.searchCards(matching: "   ", limit: 10)
        #expect(blank.isEmpty)
        let quotes = try await catalog.searchCards(matching: "\"\"", limit: 10)
        #expect(quotes.isEmpty)
    }

    @Test func cardsInSetAreOrderedBySortNumber() async throws {
        let catalog = try TestCatalog.makeCatalog()
        let cards = try await catalog.cards(inSet: "base1")
        #expect(cards.map(\.id) == ["base1-4", "base1-24", "base1-46", "base1-58", "base1-102"])
        // TG card sorts after the numbered cards via sort_number 198.
        let swsh = try await catalog.cards(inSet: "swsh9")
        #expect(swsh.map(\.id) == ["swsh9-1", "swsh9-25", "swsh9-TG12"])
    }

    @Test func nilImageBaseSurvivesRoundTrip() async throws {
        let catalog = try TestCatalog.makeCatalog()
        let pikachu = try await catalog.card(id: "base1-58")
        #expect(pikachu != nil)
        #expect(pikachu?.imageBase == nil)
        // Same through the set listing path.
        let viaSet = try await catalog.cards(inSet: "base1")
        let pikachuSummary = viaSet.first { $0.id == "base1-58" }
        #expect(pikachuSummary != nil)
        #expect(pikachuSummary?.imageBase == nil)
        // And a non-nil one stays non-nil.
        let charizard = try await catalog.card(id: "base1-4")
        #expect(charizard?.imageBase == "https://assets.tcgdex.net/en/base/base1/4")
    }

    @Test func cardDetailMapsAllColumns() async throws {
        let catalog = try TestCatalog.makeCatalog()
        let maybeDetail = try await catalog.card(id: "base1-4")
        let detail = try #require(maybeDetail)
        #expect(detail.name == "Charizard")
        #expect(detail.setID == "base1")
        #expect(detail.setName == "Base Set")
        #expect(detail.localNumber == "4")
        #expect(detail.rarity == "Rare Holo")
        #expect(detail.category == "Pokemon")
        #expect(detail.types == ["Fire"])
        #expect(detail.hp == 120)
        #expect(detail.illustrator == "Mitsuhiro Arita")
        #expect(detail.regulationMark == nil)
        #expect(detail.sortNumber == 4)
        #expect(detail.availableVariants == [.holo, .firstEdition])

        let maybeExeggcute = try await catalog.card(id: "swsh9-1")
        let exeggcute = try #require(maybeExeggcute)
        #expect(exeggcute.regulationMark == "F")
        #expect(exeggcute.availableVariants == [.normal, .reverse])

        let missing = try await catalog.card(id: "nope-0")
        #expect(missing == nil)
    }

    @Test func allSetsMapsAndOrdersByReleaseDate() async throws {
        let catalog = try TestCatalog.makeCatalog()
        let sets = try await catalog.allSets()
        #expect(sets.map(\.id) == ["base1", "swsh9"])
        let base = try #require(sets.first)
        #expect(base.name == "Base Set")
        #expect(base.seriesID == "base")
        #expect(base.seriesName == "Base")
        #expect(base.cardCountOfficial == 102)
        #expect(base.cardCountTotal == 102)
        #expect(base.releaseDate == "1999-01-09")
        #expect(base.symbolURL == "https://assets.tcgdex.net/en/base/base1/symbol")
        #expect(base.logoURL == "https://assets.tcgdex.net/en/base/base1/logo")
    }

    @Test func bundledQuotesMapVariantsCurrencyAndSkipUnknowns() async throws {
        let catalog = try TestCatalog.makeCatalog()
        let quotes = try await catalog.bundledQuotes(for: "base1-4")
        // The unknown-source and unknown-variant fixture rows are skipped.
        #expect(quotes.count == 3)
        #expect(quotes.allSatisfy { $0.isLive == false })

        let tcgHolo = try #require(quotes.first { $0.source == .tcgplayer && $0.variant == .holo })
        #expect(tcgHolo.currency == "USD")
        #expect(tcgHolo.market == 420.5)
        #expect(tcgHolo.low == 350.0)
        #expect(tcgHolo.fetchedAt == ISO8601DateFormatter().date(from: "2026-06-01T12:00:00Z"))

        let cardmarket = try #require(quotes.first { $0.source == .cardmarket })
        #expect(cardmarket.currency == "EUR")
        #expect(cardmarket.variant == .holo)
        #expect(cardmarket.market == 380.25)

        let firstEdition = try #require(quotes.first { $0.variant == .firstEdition })
        #expect(firstEdition.source == .tcgplayer)
        #expect(firstEdition.market == 5200.0)

        let reverse = try await catalog.bundledQuotes(for: "swsh9-1")
        #expect(reverse.map(\.variant) == [.reverse])

        let none = try await catalog.bundledQuotes(for: "base1-58")
        #expect(none.isEmpty)
    }

    @Test func hashEntriesRoundTrip() async throws {
        let catalog = try TestCatalog.makeCatalog()
        let entries = try await catalog.hashEntries()
        #expect(entries.count == 4)
        #expect(Set(entries.map(\.orientation)) == [0, 90, 180, 270])
        #expect(entries.allSatisfy { $0.cardID == "base1-4" })
        #expect(entries.allSatisfy { $0.dhash.count == 8 && $0.phash.count == 8 })
    }
}
