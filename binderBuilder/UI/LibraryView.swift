//
//  LibraryView.swift
//  binderBuilder
//
//  Card search (used by BrowseView) and the shared CardRow used across
//  search/browse lists. Card rows push to CardDetailView.
//

import SwiftUI
import UIKit

struct SearchView: View {
    let env: AppEnvironment

    @State private var ownFilter: OwnFilter = .all
    @State private var sort: SortMode = .relevance
    /// A swipe-to-remove that would delete more than a lone raw copy waits
    /// here for confirmation (see CollectionStore.removalNeedsConfirmation).
    @State private var pendingRemoval: CardSummary?

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
        .confirmationDialog(
            pendingRemoval.map {
                "Remove \(CollectionStore.copiesPhrase(env.collection.allCopies(ofCardID: $0.id))) of \($0.name)?"
            } ?? "",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible, presenting: pendingRemoval
        ) { card in
            Button("Remove from collection", role: .destructive) { removeAllCopies(of: card); haptic() }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Every copy of this card, graded ones included, is deleted with its condition, price, and notes. This can't be undone.")
        }
        .navigationDestination(for: CardSummary.self) { CardDetailView(card: $0, env: env) }
    }

    private func primaryRef(_ card: CardSummary) -> CardRef {
        let preferred: [CardVariant] = [.normal, .holo, .reverse, .firstEdition]
        let v = preferred.first { card.availableVariants.contains($0) } ?? .normal
        return CardRef(cardID: card.id, variant: v)
    }
    private func toggleOwned(_ card: CardSummary) {
        if isOwned(card) {
            if CollectionStore.removalNeedsConfirmation(env.collection.allCopies(ofCardID: card.id)) {
                pendingRemoval = card
                return
            }
            removeAllCopies(of: card)
        } else {
            env.collection.setOwned(primaryRef(card), quantity: 1)
        }
        haptic()
    }
    private func removeAllCopies(of card: CardSummary) {
        for v in CardVariant.allCases { env.collection.setOwned(CardRef(cardID: card.id, variant: v), quantity: 0) }
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
