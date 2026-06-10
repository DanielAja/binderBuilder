//
//  CollectionView.swift
//  binderBuilder
//
//  The Collection tab: every owned printing as a grid (grayscale-free since
//  it's all owned), with quantity badges. (Phase 4 adds filters/sort, wishlist,
//  and per-copy condition/grade management.)
//

import SwiftUI

struct CollectionView: View {
    let env: AppEnvironment

    @State private var summaries: [CardSummary] = []
    @State private var loaded = false

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 12)]

    var body: some View {
        NavigationStack {
            Group {
                if env.collection.ownedCount == 0 {
                    ContentUnavailableView(
                        "No cards yet", systemImage: "square.stack.3d.up.slash",
                        description: Text("Add cards from Browse, or scan a page, to start your collection."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(summaries) { card in
                                NavigationLink(value: card) { tile(card) }.buttonStyle(.plain)
                            }
                        }
                        .padding(12)
                    }
                }
            }
            .navigationTitle("Collection")
            .navigationDestination(for: CardSummary.self) { CardDetailView(card: $0, env: env) }
            .task(id: env.collection.changeToken) { await load() }
        }
    }

    private func tile(_ card: CardSummary) -> some View {
        let qty = CardVariant.allCases.reduce(0) { $0 + env.collection.quantity(of: CardRef(cardID: card.id, variant: $1)) }
        return CardImageView(cardID: card.id, imageBase: card.imageBase, quality: .low, imageCache: env.imageCache)
            .overlay(alignment: .topTrailing) {
                if qty > 1 {
                    Text("×\(qty)").font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(4)
                }
            }
    }

    private func load() async {
        let ids = env.collection.ownedCardIDs()
        let result = (try? await env.catalog?.summaries(forCardIDs: ids)) ?? []
        summaries = result.sorted { $0.name < $1.name }
        loaded = true
    }
}
