//
//  SetBrowserView.swift
//  binderBuilder
//
//  Browse every set with a live completion bar, then a set's cards with a
//  missing/owned filter, one-tap "Quick Add", and "Mark all owned" — the
//  fast set-completion workflow collectors expect.
//

import SwiftUI
import UIKit

struct SetBrowserView: View {
    let env: AppEnvironment
    @State private var sets: [SetInfo] = []

    var body: some View {
        List(sets) { set in
            NavigationLink(value: set) { setRow(set) }
        }
        .listStyle(.plain)
        .navigationTitle("Sets")
        .navigationDestination(for: SetInfo.self) { SetCardsView(set: $0, env: env) }
        .navigationDestination(for: CardSummary.self) { CardDetailView(card: $0, env: env) }
        .task {
            if sets.isEmpty { sets = (try? await env.catalog?.allSets()) ?? [] }
            await env.stats.refreshIfNeeded()
        }
    }

    private func setRow(_ set: SetInfo) -> some View {
        let owned = env.stats.completionBySet[set.id]?.owned ?? 0
        let total = set.cardCountTotal ?? set.cardCountOfficial ?? 0
        let fraction = total > 0 ? min(1, Double(owned) / Double(total)) : 0
        let complete = total > 0 && owned >= total
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(set.name)
                    if let series = set.seriesName {
                        Text(series).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if complete {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                }
                Text("\(owned)/\(total)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            ProgressView(value: fraction).tint(complete ? .green : .accentColor)
        }
        .padding(.vertical, 2)
    }
}

struct SetCardsView: View {
    let set: SetInfo
    let env: AppEnvironment

    @State private var cards: [CardSummary] = []
    @State private var filter: OwnFilter = .all
    @State private var quickAdd = false
    @State private var celebrate = false

    enum OwnFilter: String, CaseIterable { case all = "All", owned = "Owned", missing = "Missing" }

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 12)]

    private var ownedCount: Int { cards.filter(isOwned).count }

    private var shown: [CardSummary] {
        switch filter {
        case .all: return cards
        case .owned: return cards.filter(isOwned)
        case .missing: return cards.filter { !isOwned($0) }
        }
    }

    var body: some View {
        ScrollView {
            completionHeader
            Picker("", selection: $filter) {
                ForEach(OwnFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(shown) { card in
                    if quickAdd {
                        Button { toggleOwned(card) } label: { tile(card) }.buttonStyle(.plain)
                    } else {
                        NavigationLink(value: card) { tile(card) }.buttonStyle(.plain)
                    }
                }
            }
            .padding(12)
        }
        .navigationTitle(set.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle(isOn: $quickAdd) { Label("Quick Add (tap to own)", systemImage: "hand.tap") }
                    Divider()
                    Button { markAllOwned() } label: { Label("Mark all owned", systemImage: "checkmark.circle") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task(id: set.id) {
            cards = (try? await env.catalog?.cards(inSet: set.id)) ?? []
            env.imageCache.prefetch(cards, quality: .low, pinned: false)
        }
        .overlay {
            if celebrate {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 56)).foregroundStyle(.green)
                    Text("Set Complete! 🎉").font(.title2.bold())
                    Text(set.name).foregroundStyle(.secondary)
                }
                .padding(28)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                .shadow(radius: 20)
                .transition(.scale.combined(with: .opacity))
            }
        }
    }

    private func celebrateIfComplete(wasComplete: Bool) {
        guard !wasComplete, !cards.isEmpty, cards.allSatisfy(isOwned) else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.spring) { celebrate = true }
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            withAnimation { celebrate = false }
        }
    }

    private var completionHeader: some View {
        let total = cards.count
        let fraction = total > 0 ? Double(ownedCount) / Double(total) : 0
        return VStack(spacing: 6) {
            HStack {
                Text("\(ownedCount) of \(total) collected").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(fraction * 100))%").font(.subheadline.bold())
                    .foregroundStyle(fraction >= 1 ? .green : .primary)
            }
            ProgressView(value: fraction).tint(fraction >= 1 ? .green : .accentColor)
        }
        .padding([.horizontal, .top])
    }

    private func tile(_ card: CardSummary) -> some View {
        CardImageView(cardID: card.id, imageBase: card.imageBase, quality: .low,
                      owned: isOwned(card), imageCache: env.imageCache)
            .overlay(alignment: .topTrailing) {
                Image(systemName: isOwned(card) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isOwned(card) ? .green : .white.opacity(0.85))
                    .shadow(radius: 2)
                    .padding(5)
            }
    }

    private func isOwned(_ card: CardSummary) -> Bool {
        CardVariant.allCases.contains { env.collection.isOwned(CardRef(cardID: card.id, variant: $0)) }
    }

    private func primaryRef(_ card: CardSummary) -> CardRef {
        let preferred: [CardVariant] = [.normal, .holo, .reverse, .firstEdition]
        let variant = preferred.first { card.availableVariants.contains($0) } ?? .normal
        return CardRef(cardID: card.id, variant: variant)
    }

    private func toggleOwned(_ card: CardSummary) {
        let wasComplete = !cards.isEmpty && cards.allSatisfy(isOwned)
        let owned = isOwned(card)
        if owned {
            for v in CardVariant.allCases {
                env.collection.setOwned(CardRef(cardID: card.id, variant: v), quantity: 0)
            }
        } else {
            env.collection.setOwned(primaryRef(card), quantity: 1)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        celebrateIfComplete(wasComplete: wasComplete)
    }

    private func markAllOwned() {
        let wasComplete = !cards.isEmpty && cards.allSatisfy(isOwned)
        for card in cards where !isOwned(card) {
            env.collection.setOwned(primaryRef(card), quantity: 1)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        celebrateIfComplete(wasComplete: wasComplete)
    }
}
