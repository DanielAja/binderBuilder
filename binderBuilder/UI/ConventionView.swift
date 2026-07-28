//
//  ConventionView.swift
//  binderBuilder
//
//  The trading hub / card-show mode. Three lists collectors need in person:
//  For Trade (your "haves" with an asking value), Wants (your wishlist with a
//  target trade value + priority), and the Trade Log (completed swaps + running
//  profit/loss). Values resolve against the bundled market snapshot so it all
//  works offline on a convention floor. A live-price scanner is one tap away.
//

import SwiftUI

struct ConventionView: View {
    let env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    enum Segment: String, CaseIterable { case forTrade = "For Trade", wants = "Wants", log = "Trade Log" }

    @State private var segment: Segment = .forTrade
    @State private var market: [CardRef: Double] = [:]
    @State private var summaries: [String: CardSummary] = [:]

    // Derived totals/order, computed in `recompute()` (not in `body`), so
    // switching tabs or scrolling doesn't re-sort/re-reduce every render.
    @State private var forTradeTotal: Double = 0
    @State private var wantRefs: [CardRef] = []
    @State private var wantTotal: Double = 0

    @State private var creatingTrade = false
    @State private var editingTrade: Trade?
    @State private var addingListing = false
    @State private var editingListing: TradeListing?
    @State private var addingWant = false
    @State private var editingWant: CardRef?
    @State private var showScan = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $segment) {
                    ForEach(Segment.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top])

                switch segment {
                case .forTrade: forTradeList
                case .wants: wantsList
                case .log: tradeLog
                }
            }
            .navigationTitle("Trade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showScan = true } label: { Image(systemName: "camera.viewfinder") }
                        .accessibilityLabel("Fast scan")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { addAction() } label: { Image(systemName: "plus") }
                        .accessibilityLabel(addLabel)
                }
            }
            .navigationDestination(for: CardSummary.self) { CardDetailView(card: $0, env: env) }
            .fullScreenCover(isPresented: $showScan) { FastScanView(env: env) }
            .sheet(isPresented: $creatingTrade, onDismiss: reload) { TradeEditorView(env: env) }
            .sheet(item: $editingTrade, onDismiss: reload) { TradeEditorView(env: env, existing: $0) }
            .sheet(isPresented: $addingListing) {
                CardPickerView(env: env, title: "Add to For-Trade") { card in addListing(card) }
            }
            .sheet(item: $editingListing, onDismiss: reload) { listing in
                TradeListingEditorView(env: env, listing: listing, market: market[listing.ref])
            }
            .sheet(isPresented: $addingWant) {
                CardPickerView(env: env, title: "Add a Want") { card in addWant(card) }
            }
            .sheet(item: $editingWant, onDismiss: reload) { ref in
                WantTargetEditorView(env: env, ref: ref, summary: summaries[ref.cardID], market: market[ref])
            }
            .task(id: token) { await reloadAsync() }
        }
    }

    // A single value that changes whenever any underlying list changes.
    private var token: Int {
        env.tradeList.changeToken &+ env.wishlist.changeToken &+ env.trades.changeToken
    }

    // MARK: - For Trade

    private var forTradeList: some View {
        let listings = env.tradeList.listings
        return Group {
            if listings.isEmpty {
                emptyState("Nothing listed for trade", "Add cards you're willing to trade away, each with your asking price.",
                           system: "arrow.left.arrow.right.circle") { addingListing = true }
            } else {
                List {
                    Section {
                        summaryRow("For-trade value", "\(listings.count) card\(listings.count == 1 ? "" : "s")",
                                   amount: forTradeTotal)
                    }
                    ForEach(listings) { listing in
                        Button { editingListing = listing } label: {
                            ListingRow(listing: listing, summary: summaries[listing.ref.cardID],
                                       resolved: resolved(listing.value, ref: listing.ref), env: env)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        offsets.map { listings[$0].id }.forEach(env.tradeList.remove)
                        recompute()
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: - Wants

    private var wantsList: some View {
        Group {
            if wantRefs.isEmpty {
                emptyState("No wants yet", "Add cards you're hunting for and set the value you'd trade for each.",
                           system: "heart.text.square") { addingWant = true }
            } else {
                List {
                    Section {
                        summaryRow("Want value", "\(wantRefs.count) card\(wantRefs.count == 1 ? "" : "s")", amount: wantTotal)
                    }
                    ForEach(wantRefs, id: \.self) { ref in
                        Button { editingWant = ref } label: {
                            WantRow(ref: ref, summary: summaries[ref.cardID],
                                    target: env.wishlist.target(for: ref),
                                    priority: env.wishlist.priority(for: ref),
                                    resolved: resolved(env.wishlist.target(for: ref), ref: ref), env: env)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        offsets.forEach { env.wishlist.set(wantRefs[$0], wished: false) }
                        recompute()
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: - Trade Log

    private var tradeLog: some View {
        let trades = env.trades.trades
        return Group {
            if trades.isEmpty {
                emptyState("No trades logged", "Log a trade to track what you gave, got, and how you came out.",
                           system: "list.bullet.rectangle") { creatingTrade = true }
            } else {
                List {
                    Section { plHeader }
                    ForEach(trades) { trade in
                        Button { editingTrade = trade } label: { TradeSummaryRow(trade: trade) }
                            .buttonStyle(.plain)
                    }
                    .onDelete { offsets in offsets.map { trades[$0].id }.forEach(env.trades.delete) }
                }
                .listStyle(.plain)
            }
        }
    }

    private var plHeader: some View {
        let net = env.trades.totalNetValue
        return VStack(alignment: .leading, spacing: 6) {
            Text("Lifetime trade P/L").font(.caption).foregroundStyle(.secondary)
            Text(net, format: .currency(code: "USD"))
                .font(.title.bold().monospacedDigit())
                .foregroundStyle(net >= 0 ? .green : .orange)
            HStack(spacing: 14) {
                Label(env.trades.totalReceivedValue.formatted(.currency(code: "USD")), systemImage: "arrow.down.left")
                Label(env.trades.totalGivenValue.formatted(.currency(code: "USD")), systemImage: "arrow.up.right")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Shared pieces

    private func summaryRow(_ title: String, _ subtitle: String, amount: Double) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(amount, format: .currency(code: "USD"))
                .font(.title3.bold().monospacedDigit()).foregroundStyle(.green)
        }
    }

    private func emptyState(_ title: String, _ message: String, system: String, add: @escaping () -> Void) -> some View {
        VStack {
            Spacer()
            ContentUnavailableView {
                Label(title, systemImage: system)
            } description: {
                Text(message)
            } actions: {
                Button(action: add) { Label("Add", systemImage: "plus") }.buttonStyle(.borderedProminent)
            }
            Spacer()
        }
    }

    // MARK: - Data

    private var addLabel: String {
        switch segment {
        case .forTrade: return "Add for-trade card"
        case .wants: return "Add want"
        case .log: return "Log a trade"
        }
    }

    private func addAction() {
        switch segment {
        case .forTrade: addingListing = true
        case .wants: addingWant = true
        case .log: creatingTrade = true
        }
    }

    private func resolved(_ value: TradeValue, ref: CardRef) -> Double? {
        value.resolve(market: market[ref])
    }

    private func addListing(_ card: CardSummary) {
        let ref = CardRef(cardID: card.id, variant: LiveScanModel.primaryVariant(of: card))
        env.tradeList.save(TradeListing(ref: ref))
        recompute()
    }

    private func addWant(_ card: CardSummary) {
        let ref = CardRef(cardID: card.id, variant: LiveScanModel.primaryVariant(of: card))
        env.wishlist.set(ref, wished: true)
        recompute()
    }

    private func reload() { Task { await reloadAsync() } }

    private func reloadAsync() async {
        let refs = Set(env.tradeList.listings.map(\.ref))
            .union(env.wishlist.wishedRefs())
        if let catalog = env.catalog, !refs.isEmpty {
            market = (try? await catalog.bundledMarket(for: Array(refs))) ?? market
            let ids = Array(Set(refs.map(\.cardID)))
            if let loaded = try? await catalog.summaries(forCardIDs: ids) {
                summaries = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            }
        }
        recompute()
    }

    /// Recomputes the For Trade total and the sorted Wants list + total from
    /// the current stores/market snapshot. Cheap (sort/reduce, no I/O), so
    /// it's safe to call directly after any local mutation as well as after
    /// `reloadAsync()`, instead of leaving these in `body`.
    private func recompute() {
        forTradeTotal = Self.totalForTrade(env.tradeList.listings, market: market)
        wantRefs = Self.sortedWantRefs(env.wishlist.wished, targets: env.wishlist.targetsByRef)
        wantTotal = Self.totalWant(wantRefs, targets: env.wishlist.targetsByRef, market: market)
    }

    /// Total asking value across for-trade listings. Static + pure so it's
    /// cheap to hoist out of `body`.
    nonisolated static func totalForTrade(_ listings: [TradeListing], market: [CardRef: Double]) -> Double {
        listings.reduce(0.0) { $0 + ($1.value.resolve(market: market[$1.ref]) ?? 0) * Double($1.quantity) }
    }

    /// Wished refs sorted by show priority (desc), then card id.
    nonisolated static func sortedWantRefs(
        _ wished: Set<CardRef>, targets: [CardRef: (value: TradeValue, priority: Int)]
    ) -> [CardRef] {
        wished.sorted { (targets[$0]?.priority ?? 0, $0.cardID) > (targets[$1]?.priority ?? 0, $1.cardID) }
    }

    /// Total target trade value across the given wished refs.
    nonisolated static func totalWant(
        _ refs: [CardRef], targets: [CardRef: (value: TradeValue, priority: Int)], market: [CardRef: Double]
    ) -> Double {
        refs.reduce(0.0) { $0 + ((targets[$1]?.value ?? .market).resolve(market: market[$1]) ?? 0) }
    }
}

// MARK: - Rows

private struct ListingRow: View {
    let listing: TradeListing
    let summary: CardSummary?
    let resolved: Double?
    let env: AppEnvironment

    var body: some View {
        HStack(spacing: 12) {
            CardImageView(cardID: listing.ref.cardID, imageBase: summary?.imageBase,
                          quality: .low, imageCache: env.imageCache)
                // The summaries load after the first render; re-identify so the
                // image view refetches instead of keeping the no-image card back.
                .id(summary?.imageBase)
                .frame(width: 40, height: 55)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary?.name ?? listing.ref.fallbackName).font(.subheadline).lineLimit(1)
                Text("\(listing.condition.rawValue) · ×\(listing.quantity) · asking \(listing.value.label)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let resolved {
                Text(resolved * Double(listing.quantity), format: .currency(code: "USD"))
                    .font(.subheadline.bold().monospacedDigit()).foregroundStyle(.green)
            }
        }
    }
}

private struct WantRow: View {
    let ref: CardRef
    let summary: CardSummary?
    let target: TradeValue
    let priority: Int
    let resolved: Double?
    let env: AppEnvironment

    var body: some View {
        HStack(spacing: 12) {
            CardImageView(cardID: ref.cardID, imageBase: summary?.imageBase,
                          quality: .low, imageCache: env.imageCache)
                .id(summary?.imageBase)
                .frame(width: 40, height: 55)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary?.name ?? ref.fallbackName).font(.subheadline).lineLimit(1)
                HStack(spacing: 4) {
                    if priority > 0 {
                        ForEach(0..<min(priority, 3), id: \.self) { _ in
                            Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                        }
                    }
                    Text("will trade \(target.label)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let resolved {
                Text(resolved, format: .currency(code: "USD"))
                    .font(.subheadline.bold().monospacedDigit()).foregroundStyle(.pink)
            }
        }
    }
}

private struct TradeSummaryRow: View {
    let trade: Trade

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(trade.counterparty?.isEmpty == false ? trade.counterparty! : "Trade")
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(trade.date, format: .dateTime.month().day().year())
                    if let event = trade.event, !event.isEmpty { Text("· \(event)").lineLimit(1) }
                }
                .font(.caption2).foregroundStyle(.secondary)
                Text("\(trade.incoming.count) in · \(trade.outgoing.count) out")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(trade.netValue, format: .currency(code: "USD"))
                    .font(.subheadline.bold().monospacedDigit())
                    .foregroundStyle(trade.netValue >= 0 ? .green : .orange)
                Text(trade.netValue >= 0 ? "in your favor" : "in theirs")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Small editors

private struct TradeListingEditorView: View {
    let env: AppEnvironment
    let market: Double?
    @Environment(\.dismiss) private var dismiss
    @State private var listing: TradeListing

    init(env: AppEnvironment, listing: TradeListing, market: Double?) {
        self.env = env
        self.market = market
        _listing = State(initialValue: listing)
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Condition", selection: $listing.condition) {
                    ForEach(CardCondition.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Stepper("Quantity: \(listing.quantity)", value: $listing.quantity, in: 1...99)
                Section("Asking price") {
                    TradeValueEditor(value: $listing.value, market: market)
                }
                TextField("Note", text: Binding(
                    get: { listing.note ?? "" }, set: { listing.note = $0.isEmpty ? nil : $0 }))
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("For Trade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { env.tradeList.save(listing); dismiss() }.bold()
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button(role: .destructive) { env.tradeList.remove(id: listing.id); dismiss() } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
    }
}

private struct WantTargetEditorView: View {
    let env: AppEnvironment
    let ref: CardRef
    let summary: CardSummary?
    let market: Double?
    @Environment(\.dismiss) private var dismiss
    @State private var value: TradeValue = .market
    @State private var priority: Int = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        CardImageView(cardID: ref.cardID, imageBase: summary?.imageBase,
                                      quality: .low, imageCache: env.imageCache)
                            .id(summary?.imageBase)
                            .frame(width: 44, height: 61)
                        Text(summary?.name ?? ref.fallbackName).font(.headline)
                    }
                }
                Section("You'd trade for") { TradeValueEditor(value: $value, market: market) }
                Section("Priority") {
                    Stepper("Priority: \(priority)", value: $priority, in: 0...3)
                    Text("Higher priority sorts to the top of your wants at a show.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Want Target")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { env.wishlist.setTarget(ref, value: value, priority: priority); dismiss() }.bold()
                }
            }
            .onAppear { value = env.wishlist.target(for: ref); priority = env.wishlist.priority(for: ref) }
        }
    }
}

extension CardRef: Identifiable {
    public var id: String { "\(cardID)|\(variant.rawValue)" }
}
