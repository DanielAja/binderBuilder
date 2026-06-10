//
//  CardDetailView.swift
//  binderBuilder
//
//  Full card view: large art, metadata, per-variant ownership toggle, market
//  prices (bundled snapshot + live TCGdex/eBay when available), and a zero-API
//  "View sold on eBay" link-out.
//

import SwiftUI

struct CardDetailView: View {
    let card: CardSummary
    let env: AppEnvironment

    @State private var variant: CardVariant = .normal
    @State private var quotes: [PriceQuote] = []
    @State private var refreshing = false

    private var ref: CardRef { CardRef(cardID: card.id, variant: variant) }
    private var owned: Bool { env.collection.isOwned(ref) }

    private var variants: [CardVariant] {
        let available = CardVariant.allCases.filter { card.availableVariants.contains($0) }
        return available.isEmpty ? [.normal] : available
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                CardImageView(
                    cardID: card.id, imageBase: card.imageBase, quality: .high,
                    owned: owned, imageCache: env.imageCache
                )
                .frame(maxHeight: 380)
                .shadow(radius: 12, y: 6)
                .padding(.top, 8)

                VStack(spacing: 4) {
                    Text(card.name).font(.title2.bold()).multilineTextAlignment(.center)
                    Text("\(card.setName) · #\(card.localNumber)")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let rarity = card.rarity {
                        Text(rarity).font(.caption).foregroundStyle(.secondary)
                    }
                }

                if variants.count > 1 {
                    Picker("Variant", selection: $variant) {
                        ForEach(variants, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                }

                Button {
                    env.collection.setOwned(ref, quantity: owned ? 0 : 1)
                } label: {
                    Label(owned ? "In collection" : "Add to collection",
                          systemImage: owned ? "checkmark.seal.fill" : "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(owned ? .green : .accentColor)
                .padding(.horizontal)

                priceSection

                Link(destination: EbaySoldListingsURL.url(for: card)) {
                    Label("View sold listings on eBay", systemImage: "tag.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal)
            }
            .padding(.bottom, 32)
        }
        .navigationTitle(card.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { variant = variants.first ?? .normal }
        .task(id: card.id) {
            quotes = await env.prices.quotes(for: card.id)
            refreshing = true
            await env.prices.refreshIfStale(card: card)
            quotes = await env.prices.quotes(for: card.id)
            refreshing = false
        }
    }

    @ViewBuilder
    private var priceSection: some View {
        let rows = quotes.filter { $0.variant == variant }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Market prices").font(.headline)
                if refreshing { ProgressView().controlSize(.small) }
            }
            if rows.isEmpty {
                Text("No price data for this variant.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(rows, id: \.source) { quote in
                    HStack {
                        Text(quote.source.displayName)
                        Spacer()
                        Text(priceText(quote))
                            .monospacedDigit()
                            .foregroundStyle(quote.isLive ? .primary : .secondary)
                    }
                    .font(.subheadline)
                }
                Text(quotes.contains { $0.isLive } ? "Live + bundled snapshot" : "Bundled snapshot")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private func priceText(_ quote: PriceQuote) -> String {
        guard let market = quote.market else { return "—" }
        let symbol = quote.currency == "USD" ? "$" : (quote.currency == "EUR" ? "€" : "")
        return symbol.isEmpty
            ? String(format: "%.2f %@", market, quote.currency)
            : String(format: "%@%.2f", symbol, market)
    }
}

extension CardVariant {
    var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .holo: return "Holo"
        case .reverse: return "Reverse"
        case .firstEdition: return "1st Ed"
        }
    }
}

extension PriceQuote.Source {
    var displayName: String {
        switch self {
        case .tcgplayer: return "TCGplayer"
        case .cardmarket: return "Cardmarket"
        case .ebayActive: return "eBay (active)"
        }
    }
}
