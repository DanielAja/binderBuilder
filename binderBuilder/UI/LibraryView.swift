//
//  LibraryView.swift
//  binderBuilder
//
//  The 2D companion to the 3D binder, presented as a sheet: tabs for searching
//  the catalog, browsing sets, managing binders, and settings. Card rows push
//  to CardDetailView.
//

import SwiftUI
import UIKit

struct LibraryView: View {
    let env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TabView {
            NavigationStack { SearchView(env: env) }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            NavigationStack { SetBrowserView(env: env) }
                .tabItem { Label("Sets", systemImage: "square.grid.2x2") }
            NavigationStack { BinderManagerView(env: env) }
                .tabItem { Label("Binders", systemImage: "books.vertical") }
            NavigationStack { SettingsView(env: env) }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

struct SearchView: View {
    let env: AppEnvironment

    @State private var ownFilter: OwnFilter = .all
    @State private var sort: SortMode = .relevance

    enum OwnFilter: String, CaseIterable { case all = "All", owned = "Owned", missing = "Missing", wishlist = "Wishlist" }
    enum SortMode: String, CaseIterable { case relevance = "Relevance", name = "Name", rarity = "Rarity" }

    private func isOwned(_ card: CardSummary) -> Bool {
        CardVariant.allCases.contains { env.collection.isOwned(CardRef(cardID: card.id, variant: $0)) }
    }
    private func isWished(_ card: CardSummary) -> Bool {
        CardVariant.allCases.contains { env.wishlist.isWished(CardRef(cardID: card.id, variant: $0)) }
    }

    private func displayed(_ results: [CardSummary]) -> [CardSummary] {
        var r = results
        switch ownFilter {
        case .all: break
        case .owned: r = r.filter(isOwned)
        case .missing: r = r.filter { !isOwned($0) }
        case .wishlist: r = r.filter(isWished)
        }
        switch sort {
        case .relevance: break
        case .name: r.sort { $0.name < $1.name }
        case .rarity: r.sort { ($0.rarity ?? "") < ($1.rarity ?? "") }
        }
        return r
    }

    var body: some View {
        @Bindable var search = env.search
        let rows = displayed(search.results)
        List {
            if rows.isEmpty, !search.searchText.isEmpty, !search.isSearching {
                ContentUnavailableView.search(text: search.searchText)
            }
            ForEach(rows) { card in
                NavigationLink(value: card) {
                    CardRow(card: card, owned: isOwned(card), wished: isWished(card), env: env)
                }
                .swipeActions(edge: .leading) {
                    Button { toggleOwned(card) } label: {
                        Label(isOwned(card) ? "Remove" : "Own", systemImage: isOwned(card) ? "minus.circle" : "checkmark.circle")
                    }.tint(isOwned(card) ? .gray : .green)
                }
                .swipeActions(edge: .trailing) {
                    Button { _ = env.wishlist.toggle(primaryRef(card)); haptic() } label: {
                        Label("Wish", systemImage: "heart")
                    }.tint(.pink)
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $search.searchText, prompt: "Search 23,000+ cards")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Show", selection: $ownFilter) {
                        ForEach(OwnFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Sort", selection: $sort) {
                        ForEach(SortMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Image(systemName: ownFilter == .all && sort == .relevance
                          ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
        .overlay {
            if search.searchText.isEmpty {
                ContentUnavailableView(
                    "Find any card", systemImage: "sparkles",
                    description: Text("Search by name, set, or collector number. Swipe a result to own or wishlist it.")
                )
            }
        }
        .navigationTitle("Search")
        .navigationDestination(for: CardSummary.self) { CardDetailView(card: $0, env: env) }
    }

    private func primaryRef(_ card: CardSummary) -> CardRef {
        let preferred: [CardVariant] = [.normal, .holo, .reverse, .firstEdition]
        let v = preferred.first { card.availableVariants.contains($0) } ?? .normal
        return CardRef(cardID: card.id, variant: v)
    }
    private func toggleOwned(_ card: CardSummary) {
        if isOwned(card) {
            for v in CardVariant.allCases { env.collection.setOwned(CardRef(cardID: card.id, variant: v), quantity: 0) }
        } else {
            env.collection.setOwned(primaryRef(card), quantity: 1)
        }
        haptic()
    }
    private func haptic() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}

/// A card list row: thumbnail + name + set, with owned / wishlist marks.
struct CardRow: View {
    let card: CardSummary
    let owned: Bool
    var wished: Bool = false
    let env: AppEnvironment

    var body: some View {
        HStack(spacing: 12) {
            CardImageView(
                cardID: card.id, imageBase: card.imageBase, quality: .low,
                owned: owned, imageCache: env.imageCache
            )
            .frame(width: 44, height: 61)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.name).font(.body)
                Text("\(card.setName) · #\(card.localNumber)")
                    .font(.caption).foregroundStyle(.secondary)
                if let rarity = card.rarity {
                    Text(rarity).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if wished { Image(systemName: "heart.fill").foregroundStyle(.pink) }
            if owned { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green) }
        }
    }
}
