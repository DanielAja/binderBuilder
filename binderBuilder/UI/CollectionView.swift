//
//  CollectionView.swift
//  binderBuilder
//
//  The Collection tab: owned cards (filter raw/graded, sort, and optional
//  attribute grouping by set/rarity/condition), custom Groups, and the
//  Wishlist — all grids that push to card detail.
//

import SwiftUI

struct CollectionView: View {
    let env: AppEnvironment

    @State private var section: Section = .collection
    @State private var sort: Sort = .name
    @State private var kind: Kind = .all
    @State private var groupBy: GroupBy = .none
    @State private var owned: [CardSummary] = []
    @State private var wished: [CardSummary] = []
    @State private var market: [CardRef: Double] = [:]
    @State private var valueByCard: [String: Double] = [:]
    @State private var recentByCard: [String: Date] = [:]
    @State private var showNewGroup = false
    @State private var newGroupName = ""

    // Derived view data, computed off the render path (on load + filter change)
    // rather than inside `body`, so scrolling doesn't re-filter/re-sort.
    @State private var copiesByCard: [String: [CardCopy]] = [:]
    @State private var displayed: [CardSummary] = []
    @State private var groupedSections: [CardSection] = []

    struct CardSection: Identifiable { let title: String; let cards: [CardSummary]; var id: String { title } }

    enum Section: String, CaseIterable { case collection = "Cards", groups = "Groups", wishlist = "Wishlist" }
    enum Sort: String, CaseIterable { case name = "Name", value = "Value", recent = "Recent" }
    enum Kind: String, CaseIterable { case all = "All", raw = "Raw", graded = "Graded" }
    enum GroupBy: String, CaseIterable { case none = "None", set = "Set", rarity = "Rarity", condition = "Condition" }

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 12)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $section) {
                    ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).padding([.horizontal, .top])

                switch section {
                case .collection: collectionContent
                case .groups: groupsContent
                case .wishlist: wishlistGrid
                }
            }
            .navigationTitle("Collection")
            .toolbar { toolbarContent }
            .navigationDestination(for: CardSummary.self) { CardDetailView(card: $0, env: env) }
            .navigationDestination(for: CardGroup.self) { GroupDetailView(group: $0, env: env) }
            .alert("New Group", isPresented: $showNewGroup) {
                TextField("Name", text: $newGroupName)
                Button("Create") {
                    let n = newGroupName.trimmingCharacters(in: .whitespaces)
                    _ = env.groups.createGroup(name: n.isEmpty ? "New Group" : n)
                }
                Button("Cancel", role: .cancel) {}
            }
            .task(id: env.collection.changeToken) { await load() }
            .task(id: env.wishlist.changeToken) { await loadWishlist() }
            .onChange(of: sort) { recompute() }
            .onChange(of: kind) { recompute() }
            .onChange(of: groupBy) { recompute() }
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if section == .collection {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) { ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Picker("Show", selection: $kind) { ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Picker("Group by", selection: $groupBy) { ForEach(GroupBy.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
            }
        }
        if section == .groups {
            ToolbarItem(placement: .topBarTrailing) {
                Button { newGroupName = ""; showNewGroup = true } label: { Image(systemName: "plus") }
            }
        }
        ToolbarItem(placement: .topBarLeading) {
            NavigationLink { StatsView(env: env) } label: { Image(systemName: "chart.bar.fill") }
        }
    }

    // MARK: Collection

    @ViewBuilder private var collectionContent: some View {
        if displayed.isEmpty {
            ContentUnavailableView("No cards yet", systemImage: "square.stack.3d.up.slash",
                                   description: Text("Add cards from Browse or scan a page."))
        } else if groupBy == .none {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(displayed) { card in NavigationLink(value: card) { tile(card) }.buttonStyle(.pressable) }
                }.padding(12)
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                    ForEach(groupedSections) { group in
                        SwiftUI.Section {
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(group.cards) { card in NavigationLink(value: card) { tile(card) }.buttonStyle(.pressable) }
                            }
                        } header: {
                            Text("\(group.title)  ·  \(group.cards.count)")
                                .font(.headline).padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.bar)
                        }
                    }
                }.padding(12)
            }
        }
    }

    // MARK: Groups

    @ViewBuilder private var groupsContent: some View {
        if env.groups.groups.isEmpty {
            ContentUnavailableView("No groups yet", systemImage: "folder.badge.plus",
                                   description: Text("Create groups like \"For Trade\" or \"Vintage\", then add cards from any card's menu."))
        } else {
            List {
                ForEach(env.groups.groups) { group in
                    NavigationLink(value: group) {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 5).fill(Color(hex: group.color) ?? .accentColor)
                                .frame(width: 28, height: 28)
                            Text(group.name)
                            Spacer()
                            Text("\(env.groups.memberCount(group.id))").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { env.groups.deleteGroup(group.id) }
                    }
                }
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
                                .overlay(alignment: .topTrailing) { Image(systemName: "heart.fill").foregroundStyle(.pink).padding(5) }
                        }.buttonStyle(.pressable)
                    }
                }.padding(12)
            }
        }
    }

    private func tile(_ card: CardSummary) -> some View {
        let copies = copiesByCard[card.id] ?? []
        let qty = copies.count
        return CardImageView(cardID: card.id, imageBase: card.imageBase, quality: .low, imageCache: env.imageCache)
            .overlay(alignment: .topTrailing) {
                if qty > 1 {
                    Text("×\(qty)").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule()).padding(4)
                }
            }
            .overlay(alignment: .topLeading) {
                if copies.contains(where: \.isGraded) {
                    Image(systemName: "seal.fill").foregroundStyle(.yellow).padding(5)
                }
            }
    }

    // MARK: Data

    /// Pure filter+sort, off the render path. Static so it's unit-testable.
    nonisolated static func filterSort(
        _ owned: [CardSummary], kind: Kind, sort: Sort,
        copiesByCard: [String: [CardCopy]], valueByCard: [String: Double], recentByCard: [String: Date]
    ) -> [CardSummary] {
        var cards = owned
        switch kind {
        case .all: break
        case .raw: cards = cards.filter { (copiesByCard[$0.id] ?? []).contains { !$0.isGraded } }
        case .graded: cards = cards.filter { (copiesByCard[$0.id] ?? []).contains(where: \.isGraded) }
        }
        switch sort {
        case .name: cards.sort { $0.name < $1.name }
        case .value: cards.sort { (valueByCard[$0.id] ?? 0) > (valueByCard[$1.id] ?? 0) }
        case .recent: cards.sort { (recentByCard[$0.id] ?? .distantPast) > (recentByCard[$1.id] ?? .distantPast) }
        }
        return cards
    }

    nonisolated static func makeSections(
        _ cards: [CardSummary], groupBy: GroupBy, copiesByCard: [String: [CardCopy]]
    ) -> [CardSection] {
        let keyed: [String: [CardSummary]]
        switch groupBy {
        case .none: return [CardSection(title: "", cards: cards)]
        case .set: keyed = Dictionary(grouping: cards) { $0.setName }
        case .rarity: keyed = Dictionary(grouping: cards) { $0.rarity ?? "Unknown" }
        case .condition: keyed = Dictionary(grouping: cards) { bestCondition(copiesByCard[$0.id] ?? [])?.displayName ?? "—" }
        }
        return keyed.map { CardSection(title: $0.key, cards: $0.value) }.sorted { $0.title < $1.title }
    }

    nonisolated static func bestCondition(_ copies: [CardCopy]) -> CardCondition? {
        let order: [CardCondition] = [.nm, .lp, .mp, .hp, .dmg]
        let conditions = copies.map(\.condition)
        return order.first { conditions.contains($0) }
    }

    private func recompute() {
        displayed = Self.filterSort(owned, kind: kind, sort: sort,
                                    copiesByCard: copiesByCard, valueByCard: valueByCard, recentByCard: recentByCard)
        groupedSections = groupBy == .none ? [] : Self.makeSections(displayed, groupBy: groupBy, copiesByCard: copiesByCard)
    }

    private func load() async {
        let ids = env.collection.ownedCardIDs()
        owned = (try? await env.catalog?.summaries(forCardIDs: ids)) ?? []
        market = (try? await env.catalog?.bundledMarket(for: env.collection.ownedRefs())) ?? [:]
        // Build the card_id -> copies map once (instead of CardVariant.allCases per card per render).
        var byCard: [String: [CardCopy]] = [:]
        for (ref, copies) in env.collection.copiesByRef { byCard[ref.cardID, default: []].append(contentsOf: copies) }
        copiesByCard = byCard
        var values: [String: Double] = [:], recents: [String: Date] = [:]
        for (id, copies) in byCard {
            var v = 0.0, newest = Date.distantPast
            for copy in copies {
                let m = market[copy.ref] ?? 0
                v += copy.isGraded ? (copy.acquiredPrice ?? m) : m
                newest = max(newest, copy.acquiredAt)
            }
            values[id] = v; recents[id] = newest
        }
        valueByCard = values; recentByCard = recents
        recompute()
    }

    private func loadWishlist() async {
        let ids = Array(Set(env.wishlist.wishedRefs().map(\.cardID)))
        wished = ((try? await env.catalog?.summaries(forCardIDs: ids)) ?? []).sorted { $0.name < $1.name }
    }
}

/// The cards in one custom group.
struct GroupDetailView: View {
    let group: CardGroup
    let env: AppEnvironment
    @State private var cards: [CardSummary] = []
    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 12)]

    var body: some View {
        Group {
            if cards.isEmpty {
                ContentUnavailableView("Empty group", systemImage: "folder",
                                       description: Text("Add cards to \"\(group.name)\" from a card's menu."))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(cards) { card in
                            NavigationLink(value: card) {
                                CardImageView(cardID: card.id, imageBase: card.imageBase, quality: .low,
                                              owned: true, imageCache: env.imageCache)
                            }.buttonStyle(.pressable)
                        }
                    }.padding(12)
                }
            }
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: env.groups.changeToken) {
            let ids = Array(Set(env.groups.members(of: group.id).map(\.cardID)))
            cards = ((try? await env.catalog?.summaries(forCardIDs: ids)) ?? []).sorted { $0.name < $1.name }
        }
    }
}
