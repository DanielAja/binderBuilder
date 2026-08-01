//
//  TradeEditorView.swift
//  binderBuilder
//
//  Build or edit a trade with the two-column fairness UX collectors expect:
//  a "you give" side and a "you get" side, each with a running total, a cash
//  boot on top, a fairness verdict (within 5% reads as even), and — the
//  differentiator most apps lack — an option to apply the swap to your
//  collection on save (remove what you gave, add what you got).
//

import SwiftUI

struct TradeEditorView: View {
    let env: AppEnvironment
    /// nil = create a new trade.
    var existing: Trade?

    @Environment(\.dismiss) private var dismiss
    @State private var trade: Trade
    @State private var applyToCollection: Bool
    @State private var picking: TradeDirection?
    /// 0 = none, 1 = you receive, -1 = you pay. Kept separate from the amount so
    /// picking a direction with a still-zero amount doesn't collapse back to none.
    @State private var cashDirection: Int
    @State private var cashAmount: Double
    @FocusState private var cashFieldFocused: Bool

    init(env: AppEnvironment, existing: Trade? = nil) {
        self.env = env
        self.existing = existing
        let seed = existing ?? Trade()
        _trade = State(initialValue: seed)
        _applyToCollection = State(initialValue: existing == nil)
        _cashDirection = State(initialValue: seed.cashDelta > 0 ? 1 : (seed.cashDelta < 0 ? -1 : 0))
        _cashAmount = State(initialValue: abs(seed.cashDelta))
    }

    private var isNew: Bool { existing == nil }

    var body: some View {
        NavigationStack {
            Form {
                fairnessSection
                sideSection(.incoming)
                sideSection(.outgoing)
                cashSection
                detailsSection
                if isNew {
                    Section {
                        Toggle(isOn: $applyToCollection) {
                            Label("Apply to my collection", systemImage: "arrow.left.arrow.right")
                        }
                    } footer: {
                        Text("Adds the cards you received and removes the cards you gave.")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(isNew ? "New Trade" : "Edit Trade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.bold()
                        .disabled(trade.items.isEmpty && trade.cashDelta == 0)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { cashFieldFocused = false }
                }
            }
            .sheet(item: $picking) { direction in
                CardPickerView(env: env, title: direction == .incoming ? "Card Received" : "Card Given") { card in
                    addCard(card, direction: direction)
                }
            }
            .sheet(item: $editingItem) { item in
                TradeItemEditorView(item: item, env: env) { updated in
                    if let idx = trade.items.firstIndex(where: { $0.id == updated.id }) {
                        trade.items[idx] = updated
                    }
                }
            }
        }
    }

    // MARK: - Fairness

    private var fairnessSection: some View {
        Section {
            FairnessMeter(trade: trade)
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        }
    }

    // MARK: - Sides

    private func sideSection(_ direction: TradeDirection) -> some View {
        let items = direction == .incoming ? trade.incoming : trade.outgoing
        let total = items.reduce(0.0) { $0 + $1.lineValue }
        return Section {
            ForEach(items) { item in
                Button { editItem(item) } label: { TradeItemRow(item: item, env: env) }
                    .buttonStyle(.plain)
            }
            .onDelete { offsets in delete(offsets, direction: direction) }
            Button { picking = direction } label: {
                Label(direction == .incoming ? "Add a card you received" : "Add a card you gave",
                      systemImage: "plus.circle")
            }
        } header: {
            HStack {
                Text(direction == .incoming ? "You Get (received)" : "You Give (given)")
                Spacer()
                if total > 0 { Text(total, format: .currency(code: "USD")).foregroundStyle(.secondary) }
            }
        }
    }

    // MARK: - Cash

    private var cashSection: some View {
        Section("Cash") {
            Picker("Cash", selection: $cashDirection) {
                Text("None").tag(0)
                Text("You receive").tag(1)
                Text("You pay").tag(-1)
            }
            .pickerStyle(.segmented)
            if cashDirection != 0 {
                HStack {
                    Text("Amount")
                    Spacer()
                    TextField("0.00", value: $cashAmount, format: .currency(code: "USD"))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 140)
                        .focused($cashFieldFocused)
                }
            }
        }
        .onChange(of: cashDirection) { _, _ in syncCash() }
        .onChange(of: cashAmount) { _, _ in syncCash() }
    }

    private func syncCash() {
        trade.cashDelta = Double(cashDirection) * max(0, cashAmount)
    }

    // MARK: - Details

    private var detailsSection: some View {
        Section("Details") {
            DatePicker("Date", selection: $trade.date, displayedComponents: .date)
            TextField("Traded with", text: optional($trade.counterparty))
            HStack {
                TextField("Event / show", text: optional($trade.event))
                if !env.trades.recentEvents.isEmpty {
                    Menu {
                        ForEach(env.trades.recentEvents, id: \.self) { e in
                            Button(e) { trade.event = e }
                        }
                    } label: { Image(systemName: "clock.arrow.circlepath") }
                }
            }
            TextField("Location", text: optional($trade.location))
            TextField("Notes", text: optional($trade.notes), axis: .vertical)
                .lineLimit(1...4)
        }
    }

    // MARK: - Bindings

    private func optional(_ source: Binding<String?>) -> Binding<String> {
        Binding(get: { source.wrappedValue ?? "" }, set: { source.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    // MARK: - Item editing

    @State private var editingItem: TradeItem?

    private func editItem(_ item: TradeItem) { editingItem = item }

    private func addCard(_ card: CardSummary, direction: TradeDirection) {
        let variant = LiveScanModel.primaryVariant(of: card)
        let ref = CardRef(cardID: card.id, variant: variant)
        let item = TradeItem(ref: ref, direction: direction, condition: .nm, quantity: 1)
        let itemID = item.id
        trade.items.append(item)
        // Fill the value snapshot from the best known trading price. Look the
        // current item up by id so an edit made while the price is in flight
        // (or the row being deleted) isn't clobbered by a stale copy.
        Task {
            guard let price = await env.prices.tradingPrice(for: ref) else { return }
            guard let idx = trade.items.firstIndex(where: { $0.id == itemID }) else { return }
            trade.items[idx].valueEach = price.amount
        }
    }

    private func delete(_ offsets: IndexSet, direction: TradeDirection) {
        let items = direction == .incoming ? trade.incoming : trade.outgoing
        let ids = offsets.map { items[$0].id }
        trade.items.removeAll { ids.contains($0.id) }
    }

    private func save() {
        // Trim empty strings already handled by `optional`.
        if trade.counterparty?.isEmpty == true { trade.counterparty = nil }
        env.trades.save(trade)
        if isNew, applyToCollection { applyTradeToCollection() }
        Haptics.success()
        dismiss()
    }

    private func applyTradeToCollection() {
        for item in trade.incoming {
            for _ in 0..<item.quantity { env.collection.addCopy(item.ref, condition: item.condition) }
        }
        for item in trade.outgoing {
            let current = env.collection.quantity(of: item.ref)
            env.collection.setOwned(item.ref, quantity: max(0, current - item.quantity))
        }
    }
}

extension TradeDirection: Identifiable { public var id: String { rawValue } }

// MARK: - Item editor

/// Edits one trade line: variant, condition, quantity, per-card value, note.
private struct TradeItemEditorView: View {
    let env: AppEnvironment
    let onSave: (TradeItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var item: TradeItem
    @State private var summary: CardSummary?
    @FocusState private var valueFieldFocused: Bool

    init(item: TradeItem, env: AppEnvironment, onSave: @escaping (TradeItem) -> Void) {
        self.env = env
        self.onSave = onSave
        _item = State(initialValue: item)
    }

    private var variants: [CardVariant] {
        guard let summary else { return [item.ref.variant] }
        let available = CardVariant.allCases.filter { summary.availableVariants.contains($0) }
        return available.isEmpty ? [.normal] : available
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        CardImageView(cardID: item.ref.cardID, imageBase: summary?.imageBase,
                                      quality: .low, imageCache: env.imageCache)
                            .id(summary?.imageBase)
                            .frame(width: 44, height: 61)
                            .interactiveCard(card: summary, variant: item.ref.variant, intensity: 0.6)
                        Text(summary?.name ?? item.ref.fallbackName).font(.headline)
                    }
                }
                if variants.count > 1 {
                    Picker("Variant", selection: variantBinding) {
                        ForEach(variants, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
                Picker("Condition", selection: $item.condition) {
                    ForEach(CardCondition.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Stepper("Quantity: \(item.quantity)", value: $item.quantity, in: 1...99)
                HStack {
                    Text("Value each")
                    Spacer()
                    TextField("0.00", value: valueBinding, format: .currency(code: "USD"))
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 120)
                        .focused($valueFieldFocused)
                    Button { Task { await refetchValue() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                }
                TextField("Note", text: Binding(
                    get: { item.note ?? "" }, set: { item.note = $0.isEmpty ? nil : $0 }))
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onSave(item); dismiss() }.bold()
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { valueFieldFocused = false }
                }
            }
            .task { summary = try? await env.catalog?.card(id: item.ref.cardID)?.summary }
        }
    }

    private var variantBinding: Binding<CardVariant> {
        Binding(get: { item.ref.variant }, set: { item.ref.variant = $0; Task { await refetchValue() } })
    }
    private var valueBinding: Binding<Double> {
        Binding(get: { item.valueEach ?? 0 }, set: { item.valueEach = $0 })
    }

    private func refetchValue() async {
        if let price = await env.prices.tradingPrice(for: item.ref) { item.valueEach = price.amount }
    }
}

extension TradeEditorView {
    /// A pre-populated trade for Simulator screenshot verification (-tradeEditorDemo).
    static var demoTrade: Trade {
        Trade(
            counterparty: "Alex", event: "City Card Show", cashDelta: 15,
            items: [
                TradeItem(ref: CardRef(cardID: "base1-4", variant: .holo),
                          direction: .incoming, condition: .lp, valueEach: 420),
                TradeItem(ref: CardRef(cardID: "swsh9-014", variant: .holo),
                          direction: .outgoing, valueEach: 55),
                TradeItem(ref: CardRef(cardID: "swsh9-TG12", variant: .holo),
                          direction: .outgoing, valueEach: 380),
            ])
    }
}

// MARK: - Fairness meter

struct FairnessMeter: View {
    let trade: Trade

    /// Within this fraction the two sides read as "even".
    private static let evenBand = 0.05

    private var verdict: (text: String, color: Color) {
        let get = trade.youGet, give = trade.youGive
        guard get > 0 || give > 0 else { return ("Add cards to compare", .secondary) }
        let diff = get - give
        let hi = max(get, give)
        if abs(diff) / hi <= Self.evenBand { return ("Even trade", .green) }
        if diff > 0 { return ("You're up \(diff.formatted(.currency(code: "USD")))", .green) }
        return ("They're up \((-diff).formatted(.currency(code: "USD")))", .orange)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top) {
                column("You Give", value: trade.youGive, align: .leading)
                Spacer()
                VStack(spacing: 2) {
                    Image(systemName: "arrow.left.arrow.right")
                        .foregroundStyle(.secondary)
                    Text("\(Int(trade.fairness * 100))%")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                column("You Get", value: trade.youGet, align: .trailing)
            }
            ProgressView(value: min(trade.youGet, trade.youGive), total: max(trade.youGet, trade.youGive, 0.01))
                .tint(verdict.color)
            Text(verdict.text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(verdict.color)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You give \(trade.youGive.formatted(.currency(code: "USD"))), you get \(trade.youGet.formatted(.currency(code: "USD"))). \(verdict.text).")
    }

    private func column(_ title: String, value: Double, align: HorizontalAlignment) -> some View {
        VStack(alignment: align, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value, format: .currency(code: "USD")).font(.title3.bold().monospacedDigit())
        }
    }
}

// MARK: - Item row

extension CardRef {
    /// What to show when the catalog has no row for this card (a ref saved
    /// before a catalog update, or a bad id): "swsh9-TG12" reads as a bug,
    /// "SWSH9 #TG12" reads as a card.
    nonisolated var fallbackName: String {
        guard let dash = cardID.lastIndex(of: "-"), dash != cardID.startIndex else {
            return cardID.uppercased()
        }
        let number = cardID[cardID.index(after: dash)...]
        guard !number.isEmpty else { return cardID.uppercased() }
        return "\(cardID[..<dash].uppercased()) #\(number)"
    }
}

struct TradeItemRow: View {
    let item: TradeItem
    let env: AppEnvironment
    @State private var summary: CardSummary?

    var body: some View {
        HStack(spacing: 12) {
            CardImageView(cardID: item.ref.cardID, imageBase: summary?.imageBase,
                          quality: .low, imageCache: env.imageCache)
                // CardImageView fetches once per card id, and the summary (with
                // it the imageBase) only lands after the first render — without
                // a new identity the row would keep the no-image card back.
                .id(summary?.imageBase)
                .frame(width: 34, height: 47)
            VStack(alignment: .leading, spacing: 1) {
                Text(summary?.name ?? item.ref.fallbackName).font(.subheadline).lineLimit(1)
                Text("\(item.condition.rawValue) · ×\(item.quantity)\(item.ref.variant == .normal ? "" : " · \(item.ref.variant.displayName)")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if item.valueEach != nil {
                Text(item.lineValue, format: .currency(code: "USD"))
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .task(id: item.ref.cardID) {
            if summary == nil { summary = try? await env.catalog?.card(id: item.ref.cardID)?.summary }
        }
    }
}
