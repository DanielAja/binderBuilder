//
//  LibraryView.swift
//  binderBuilder
//
//  The 2D companion to the 3D binder, presented as a sheet: tabs for searching
//  the catalog, browsing sets, managing binders, and settings. Card rows push
//  to CardDetailView.
//

import SwiftUI

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

    var body: some View {
        @Bindable var search = env.search
        List {
            if search.results.isEmpty, !search.searchText.isEmpty, !search.isSearching {
                ContentUnavailableView.search(text: search.searchText)
            }
            ForEach(search.results) { card in
                NavigationLink(value: card) { CardRow(card: card, env: env) }
            }
        }
        .listStyle(.plain)
        .searchable(text: $search.searchText, prompt: "Search 23,000+ cards")
        .overlay {
            if search.searchText.isEmpty {
                ContentUnavailableView(
                    "Find any card", systemImage: "sparkles",
                    description: Text("Search by name, set, or collector number.")
                )
            }
        }
        .navigationTitle("Search")
        .navigationDestination(for: CardSummary.self) { CardDetailView(card: $0, env: env) }
    }
}

/// A card list row: thumbnail + name + set, with an owned check.
struct CardRow: View {
    let card: CardSummary
    let env: AppEnvironment

    private var owned: Bool {
        CardVariant.allCases.contains { env.collection.isOwned(CardRef(cardID: card.id, variant: $0)) }
    }

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
            }
            Spacer()
            if owned {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            }
        }
    }
}
