//
//  PerfDerivedTests.swift
//  binderBuilderTests
//
//  Covers the derived-state helpers moved out of `body` (CollectionView,
//  SetBrowserView) and the async store `load()` refactor.
//

import Testing
@testable import binderBuilder

@MainActor struct PerfDerivedTests {
    private func summary(_ id: String, name: String, set: String = "Base", rarity: String? = "Common") -> CardSummary {
        CardSummary(id: id, name: name, setID: "s", setName: set, localNumber: "1",
                    rarity: rarity, imageBase: nil, availableVariants: [.normal])
    }

    @Test func collectionFilterSortByName() {
        let a = summary("a", name: "Zard"); let b = summary("b", name: "Abra")
        let sorted = CollectionView.filterSort([a, b], kind: .all, sort: .name,
                                               copiesByCard: [:], valueByCard: [:], recentByCard: [:])
        #expect(sorted.map(\.id) == ["b", "a"])
    }

    @Test func collectionRawVsGradedFilter() {
        let a = summary("a", name: "A"); let b = summary("b", name: "B")
        let copies: [String: [CardCopy]] = [
            "a": [CardCopy(ref: CardRef(cardID: "a", variant: .normal), condition: .nm)],
            "b": [CardCopy(ref: CardRef(cardID: "b", variant: .normal), condition: .nm,
                           grade: CardGrade(company: .psa, value: 10))],
        ]
        let raw = CollectionView.filterSort([a, b], kind: .raw, sort: .name,
                                            copiesByCard: copies, valueByCard: [:], recentByCard: [:])
        #expect(raw.map(\.id) == ["a"])
        let graded = CollectionView.filterSort([a, b], kind: .graded, sort: .name,
                                               copiesByCard: copies, valueByCard: [:], recentByCard: [:])
        #expect(graded.map(\.id) == ["b"])
    }

    @Test func collectionSectionsBySet() {
        let a = summary("a", name: "A", set: "Base"); let b = summary("b", name: "B", set: "Jungle")
        let sections = CollectionView.makeSections([a, b], groupBy: .set, copiesByCard: [:])
        #expect(sections.map(\.title) == ["Base", "Jungle"])
        #expect(sections.first?.cards.map(\.id) == ["a"])
    }

    @Test func setGenerationAndFlatSort() {
        let base = SetInfo(id: "base1", name: "Base", seriesID: "base", seriesName: "Base",
                           cardCountOfficial: 102, cardCountTotal: 102, releaseDate: "1999-01-09",
                           symbolURL: nil, logoURL: nil)
        let sv = SetInfo(id: "sv1", name: "Scarlet & Violet", seriesID: "sv", seriesName: "Scarlet & Violet",
                         cardCountOfficial: nil, cardCountTotal: nil, releaseDate: "2023-03-31",
                         symbolURL: nil, logoURL: nil)
        // Series ordered by earliest release; newest set first within the flat list.
        #expect(SetBrowserView.generationSections([sv, base]).map(\.series) == ["Base", "Scarlet & Violet"])
        #expect(SetBrowserView.flatSorted([base, sv], sort: .release).map(\.id) == ["sv1", "base1"])
        #expect(SetBrowserView.flatSorted([sv, base], sort: .name).map(\.id) == ["base1", "sv1"])
    }

    @Test func collectionStoreLoadsAsync() async throws {
        let db = try UserDatabase.inMemory()
        let writer = CollectionStore(database: db)
        await writer.load()                      // cheap init, then load
        writer.addCopy(CardRef(cardID: "base1-4", variant: .holo))

        // A fresh store starts empty until load() pulls the mirror from disk.
        let reader = CollectionStore(database: db)
        #expect(reader.ownedCount == 0)
        await reader.load()
        #expect(reader.ownedCount == 1)
        #expect(reader.isOwned(CardRef(cardID: "base1-4", variant: .holo)))
    }
}
