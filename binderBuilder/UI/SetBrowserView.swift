//
//  SetBrowserView.swift
//  binderBuilder
//
//  Browse every set, then every card in a set (lazy grid). Cards push to
//  CardDetailView.
//

import SwiftUI

struct SetBrowserView: View {
    let env: AppEnvironment
    @State private var sets: [SetInfo] = []

    var body: some View {
        List(sets) { set in
            NavigationLink(value: set) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(set.name)
                    if let series = set.seriesName {
                        Text(series).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Sets")
        .navigationDestination(for: SetInfo.self) { SetCardsView(set: $0, env: env) }
        .navigationDestination(for: CardSummary.self) { CardDetailView(card: $0, env: env) }
        .task {
            if sets.isEmpty { sets = (try? await env.catalog?.allSets()) ?? [] }
        }
    }
}

struct SetCardsView: View {
    let set: SetInfo
    let env: AppEnvironment
    @State private var cards: [CardSummary] = []

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(cards) { card in
                    NavigationLink(value: card) {
                        CardImageView(
                            cardID: card.id, imageBase: card.imageBase, quality: .low,
                            owned: isOwned(card), imageCache: env.imageCache
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .navigationTitle(set.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: set.id) {
            cards = (try? await env.catalog?.cards(inSet: set.id)) ?? []
        }
    }

    private func isOwned(_ card: CardSummary) -> Bool {
        CardVariant.allCases.contains { env.collection.isOwned(CardRef(cardID: card.id, variant: $0)) }
    }
}
