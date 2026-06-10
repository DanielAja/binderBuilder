//
//  CollectionView.swift
//  binderBuilder
//
//  The Collection tab: your owned cards (filter raw/graded, sort by
//  name/value/recent) and your wishlist, as grids that push to card detail.
//

import SwiftUI

struct CollectionView: View {
    let env: AppEnvironment

    @State private var section: Section = .collection
    @State private var sort: Sort = .name
    @State private var kind: Kind = .all
    @State private var owned: [CardSummary] = []
    @State private var wished: [CardSummary] = []
    @State private var market: [CardRef: Double] = [:]
    @State private var valueByCard: [String: Double] = [:]
    @State private var recentByCard: [String: Date] = [:]

    enum Section: String, CaseIterable { case collection = "Collection", wishlist = "Wishlist" }
    enum Sort: String, CaseIterable { case name = "Name", value = "Value", recent = "Recent" }
    enum Kind: String, CaseIterable { case all = "All", raw = "Raw", graded = "Graded" }

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 12)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $section) {
                    ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top])

                if section == .collection { collectionGrid } else { wishlistGrid }
            }
            .navigationTitle("Collection")
            .toolbar {
                if section == .collection {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Picker("Sort", selection: $sort) {
                                ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            Picker("Show", selection: $kind) {
                                ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                        } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { StatsView(env: env) } label: { Image(systemName: "chart.bar.fill") }
                }
            }
            .navigationDestination(for: CardSummary.self) { CardDetailView(card: $0, env: env) }
            .task(id: env.collection.changeToken) { await load() }
            .task(id: env.wishlist.changeToken) { await loadWishlist() }
        }
    }

    // MARK: Grids

    @ViewBuilder private var collectionGrid: some View {
        let cards = filteredSortedOwned
        if cards.isEmpty {
            ContentUnavailableView("No cards yet", systemImage: "square.stack.3d.up.slash",
                                   description: Text("Add cards from Browse or scan a page."))
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(cards) { card in
                        NavigationLink(value: card) { tile(card) }.buttonStyle(.plain)
                    }
                }.padding(12)
            }
        }
    }

    @ViewBuilder private var wishlistGrid: some View {
        if wished.isEmpty {
            ContentUnavailableView("No wishlist yet", systemImage: "heart",
                                   description: Text("Swipe a search result, or tap the heart on a card, to add it."))
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(wished) { card in
                        NavigationLink(value: card) {
                            CardImageView(cardID: card.id, imageBase: card.imageBase, quality: .low,
                                          owned: false, imageCache: env.imageCache)
                                .overlay(alignment: .topTrailing) {
                                    Image(systemName: "heart.fill").foregroundStyle(.pink).padding(5)
                                }
                        }.buttonStyle(.plain)
                    }
                }.padding(12)
            }
        }
    }

    private func tile(_ card: CardSummary) -> some View {
        let qty = copies(card.id).count
        return CardImageView(cardID: card.id, imageBase: card.imageBase, quality: .low, imageCache: env.imageCache)
            .overlay(alignment: .topTrailing) {
                if qty > 1 {
                    Text("×\(qty)").font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule()).padding(4)
                }
            }
            .overlay(alignment: .topLeading) {
                if copies(card.id).contains(where: \.isGraded) {
                    Image(systemName: "seal.fill").foregroundStyle(.yellow).padding(5)
                }
            }
    }

    // MARK: Data

    private func copies(_ cardID: String) -> [CardCopy] {
        CardVariant.allCases.flatMap { env.collection.copies(of: CardRef(cardID: cardID, variant: $0)) }
    }

    private var filteredSortedOwned: [CardSummary] {
        var cards = owned
        switch kind {
        case .all: break
        case .raw: cards = cards.filter { copies($0.id).contains { !$0.isGraded } }
        case .graded: cards = cards.filter { copies($0.id).contains(where: \.isGraded) }
        }
        switch sort {
        case .name: cards.sort { $0.name < $1.name }
        case .value: cards.sort { (valueByCard[$0.id] ?? 0) > (valueByCard[$1.id] ?? 0) }
        case .recent: cards.sort { (recentByCard[$0.id] ?? .distantPast) > (recentByCard[$1.id] ?? .distantPast) }
        }
        return cards
    }

    private func load() async {
        let ids = env.collection.ownedCardIDs()
        owned = (try? await env.catalog?.summaries(forCardIDs: ids)) ?? []
        market = (try? await env.catalog?.bundledMarket(for: env.collection.ownedRefs())) ?? [:]
        var values: [String: Double] = [:]
        var recents: [String: Date] = [:]
        for id in ids {
            var v = 0.0
            var newest = Date.distantPast
            for variant in CardVariant.allCases {
                let ref = CardRef(cardID: id, variant: variant)
                let m = market[ref] ?? 0
                for copy in env.collection.copies(of: ref) {
                    v += copy.isGraded ? (copy.acquiredPrice ?? m) : m
                    newest = max(newest, copy.acquiredAt)
                }
            }
            values[id] = v; recents[id] = newest
        }
        valueByCard = values; recentByCard = recents
    }

    private func loadWishlist() async {
        let ids = Array(Set(env.wishlist.wishedRefs().map(\.cardID)))
        wished = ((try? await env.catalog?.summaries(forCardIDs: ids)) ?? []).sorted { $0.name < $1.name }
    }
}
