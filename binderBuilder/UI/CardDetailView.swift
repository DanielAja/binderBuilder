//
//  CardDetailView.swift
//  binderBuilder
//
//  Full card view: large art, metadata, per-variant ownership toggle, market
//  prices (bundled snapshot + live TCGdex/eBay when available), and a zero-API
//  "View sold on eBay" link-out.
//

import SwiftUI
import UIKit

struct CardDetailView: View {
    let card: CardSummary
    let env: AppEnvironment

    @State private var variant: CardVariant = .normal
    @State private var quotes: [PriceQuote] = []
    @State private var refreshing = false
    @State private var addingCopy = false
    @State private var editorCopy: CardCopy?
    @State private var toast: String?
    @State private var showNewGroup = false
    @State private var newGroupName = ""
    @State private var showAlertEditor = false

    private var currentMarket: Double? {
        quotes.first { $0.source == .tcgplayer && $0.variant == variant }?.market
    }

    private var ref: CardRef { CardRef(cardID: card.id, variant: variant) }
    private var owned: Bool { env.collection.isOwned(ref) }
    private var wished: Bool { env.wishlist.isWished(ref) }

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

                copiesSection

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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    let nowWished = env.wishlist.toggle(ref)
                    Haptics.selection()
                    showToast(nowWished ? "Added to wishlist" : "Removed from wishlist")
                } label: {
                    Image(systemName: wished ? "heart.fill" : "heart").foregroundStyle(.pink)
                }
                .accessibilityLabel(wished ? "Remove from wishlist" : "Add to wishlist")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showAlertEditor = true } label: {
                        Label(env.alerts.alert(for: ref) != nil ? "Edit Price Alert…" : "Set Price Alert…",
                              systemImage: env.alerts.alert(for: ref) != nil ? "bell.fill" : "bell")
                    }
                    if !env.binders.binders.isEmpty {
                        Menu("Add to Binder") {
                            ForEach(env.binders.binders) { binder in
                                Button(binder.name) { addToBinder(binder.id) }
                            }
                        }
                    }
                    Menu("Add to Group") {
                        ForEach(env.groups.groups) { group in
                            Button {
                                _ = env.groups.toggle(ref, group: group.id)
                                UISelectionFeedbackGenerator().selectionChanged()
                            } label: {
                                Label(group.name, systemImage: env.groups.isMember(ref, of: group.id) ? "checkmark" : "circle")
                            }
                        }
                        Divider()
                        Button { newGroupName = ""; showNewGroup = true } label: {
                            Label("New Group…", systemImage: "plus")
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showAlertEditor) {
            AlertEditorView(ref: ref, env: env, currentPrice: currentMarket)
        }
        .alert("New Group", isPresented: $showNewGroup) {
            TextField("Name", text: $newGroupName)
            Button("Create") {
                let name = newGroupName.trimmingCharacters(in: .whitespaces)
                if let group = env.groups.createGroup(name: name.isEmpty ? "New Group" : name) {
                    env.groups.setMember(ref, group: group.id, member: true)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .overlay(alignment: .bottom) {
            if let toast { Text(toast).font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .floatingGlass().padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityAddTraits(.isStaticText)
            }
        }
        .sheet(isPresented: $addingCopy) { CopyEditorView(ref: ref, env: env) }
        .sheet(item: $editorCopy) { CopyEditorView(ref: ref, env: env, existing: $0) }
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
    private var copiesSection: some View {
        let copies = env.collection.copies(of: ref)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Your copies (\(copies.count))").font(.headline)
                Spacer()
                Button { addingCopy = true } label: { Label("Add", systemImage: "plus") }
                    .font(.subheadline)
            }
            if copies.isEmpty {
                Text("No copies of this printing yet.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(copies) { copy in
                    Button { editorCopy = copy } label: { copyRow(copy) }
                        .buttonStyle(.plain)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private func copyRow(_ copy: CardCopy) -> some View {
        HStack {
            Image(systemName: copy.isGraded ? "seal.fill" : "rectangle.portrait")
                .foregroundStyle(copy.isGraded ? .yellow : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(copy.isGraded ? (copy.grade?.label ?? "Graded") : copy.condition.displayName)
                if let notes = copy.notes, !notes.isEmpty {
                    Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let price = copy.acquiredPrice {
                Text(price, format: .currency(code: "USD")).font(.subheadline).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
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
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private func addToBinder(_ binderID: String) {
        guard let slot = env.binders.firstEmptySlot(binderID: binderID) else {
            showToast("Binder is full"); return
        }
        if !owned { env.collection.setOwned(ref, quantity: 1) }
        env.binders.assign(ref, to: slot)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showToast("Added to \(env.binders.binders.first { $0.id == binderID }?.name ?? "binder")")
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation { toast = nil }
        }
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
