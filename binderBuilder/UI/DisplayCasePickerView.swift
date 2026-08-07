//
//  DisplayCasePickerView.swift
//  binderBuilder
//
//  Picks the card for a shelf display case. Leads with what people actually
//  showcase — recent pulls and their most valuable cards (both already
//  computed by CollectionStatsStore) — with full catalog search as the
//  fallback. Returns a concrete CardRef (variant included).
//

import SwiftUI

struct DisplayCasePickerView: View {
    let env: AppEnvironment
    let onPick: (CardRef) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .topValue
    @State private var search: CatalogStore

    private enum Tab: String, CaseIterable, Identifiable {
        case topValue = "Top Value"
        case recent = "Recent"
        case search = "Search"
        var id: String { rawValue }
    }

    init(env: AppEnvironment, onPick: @escaping (CardRef) -> Void) {
        self.env = env
        self.onPick = onPick
        _search = State(initialValue: CatalogStore(catalog: env.catalog))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Source", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 6)

                switch tab {
                case .topValue: topValueList
                case .recent: recentList
                case .search: searchList
                }
            }
            .navigationTitle("Display a Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await env.stats.refreshIfNeeded() }
        }
    }

    // MARK: Sources

    private var topValueList: some View {
        List {
            if env.stats.topValuable.isEmpty {
                ContentUnavailableView(
                    "Nothing valued yet", systemImage: "sparkles",
                    description: Text("Add cards to your collection and their market values appear here."))
            }
            ForEach(env.stats.topValuable) { valued in
                row(card: valued.card,
                    detail: valued.value.formatted(.currency(code: "USD"))) {
                    pick(preferredRef(for: valued.card))
                }
            }
        }
        .listStyle(.plain)
    }

    private var recentList: some View {
        List {
            if env.stats.recent.isEmpty {
                ContentUnavailableView(
                    "No recent cards", systemImage: "clock",
                    description: Text("Cards you add show up here, newest first."))
            }
            ForEach(env.stats.recent) { recent in
                row(card: recent.card, detail: recent.card.setName) {
                    pick(recent.copy.ref)
                }
            }
        }
        .listStyle(.plain)
    }

    private var searchList: some View {
        @Bindable var search = search
        return List {
            ForEach(search.results) { card in
                row(card: card, detail: card.setName) {
                    pick(preferredRef(for: card))
                }
            }
            if search.results.isEmpty, !search.searchText.isEmpty, !search.isSearching {
                ContentUnavailableView.search(text: search.searchText)
            }
        }
        .listStyle(.plain)
        .searchable(text: $search.searchText, prompt: "Search cards")
        .overlay {
            if search.searchText.isEmpty {
                ContentUnavailableView(
                    "Find a card", systemImage: "magnifyingglass",
                    description: Text("Search by name, set, or number."))
            }
        }
    }

    private func row(card: CardSummary, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                CardImageView(cardID: card.id, imageBase: card.imageBase, imageCache: env.imageCache)
                    .frame(width: 40, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.name).font(.body)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "sparkles.rectangle.stack")
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Picking

    private func pick(_ ref: CardRef) {
        onPick(ref)
        Haptics.selection()
        dismiss()
    }

    /// The variant the user owns when they own one — the case shows their
    /// actual card, in color.
    private func preferredRef(for card: CardSummary) -> CardRef {
        let variant = CardVariant.allCases.first {
            env.collection.isOwned(CardRef(cardID: card.id, variant: $0))
        } ?? .normal
        return CardRef(cardID: card.id, variant: variant)
    }
}
