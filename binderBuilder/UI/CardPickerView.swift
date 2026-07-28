//
//  CardPickerView.swift
//  binderBuilder
//
//  A search-and-pick sheet used wherever the trade features need the user to
//  choose a card (trade editor sides, for-trade list, want targets). Uses its
//  own CatalogStore so it never clobbers the Browse tab's search text.
//

import SwiftUI

struct CardPickerView: View {
    let env: AppEnvironment
    let title: String
    let onPick: (CardSummary) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search: CatalogStore

    init(env: AppEnvironment, title: String = "Add a Card", onPick: @escaping (CardSummary) -> Void) {
        self.env = env
        self.title = title
        self.onPick = onPick
        _search = State(initialValue: CatalogStore(catalog: env.catalog))
    }

    var body: some View {
        NavigationStack {
            @Bindable var search = search
            List {
                if !search.results.isEmpty {
                    ForEach(search.results) { card in
                        Button {
                            onPick(card)
                            Haptics.selection()
                            dismiss()
                        } label: {
                            CardRow(card: card, owned: isOwned(card), env: env)
                        }
                        .buttonStyle(.plain)
                    }
                } else if !search.searchText.isEmpty, !search.isSearching {
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
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func isOwned(_ card: CardSummary) -> Bool {
        CardVariant.allCases.contains { env.collection.isOwned(CardRef(cardID: card.id, variant: $0)) }
    }
}

/// A compact inline editor for a `TradeValue` (Market / % of market / Fixed $),
/// with the grounded preset percentages collectors actually use.
struct TradeValueEditor: View {
    @Binding var value: TradeValue
    /// The reference market price, to preview the resolved dollar figure.
    var market: Double?

    private enum Kind: String, CaseIterable { case market = "Market", percent = "% of Market", fixed = "Fixed $" }

    private var kind: Kind {
        switch value {
        case .market: return .market
        case .percentOfMarket: return .percent
        case .fixed: return .fixed
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Pricing", selection: Binding(
                get: { kind },
                set: { newKind in
                    switch newKind {
                    case .market: value = .market
                    case .percent: value = .percentOfMarket(percentAmount ?? 90)
                    case .fixed: value = .fixed(fixedAmount ?? (market ?? 0))
                    }
                })) {
                ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            switch value {
            case .market:
                Text("Uses the current market price.")
                    .font(.caption).foregroundStyle(.secondary)
            case .percentOfMarket(let pct):
                HStack(spacing: 8) {
                    ForEach([100.0, 90, 80, 70], id: \.self) { preset in
                        Button {
                            value = .percentOfMarket(preset)
                        } label: {
                            Text("\(Int(preset))%")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(pct == preset ? Color.accentColor : Color(.tertiarySystemFill),
                                            in: Capsule())
                                .foregroundStyle(pct == preset ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                Stepper("\(Int(pct))% of market", value: Binding(
                    get: { pct }, set: { value = .percentOfMarket(min(200, max(0, $0))) }),
                    in: 0...200, step: 5)
                    .font(.subheadline)
            case .fixed(let dollars):
                HStack {
                    Text("Amount")
                    Spacer()
                    TextField("0.00", value: Binding(
                        get: { dollars }, set: { value = .fixed(max(0, $0)) }),
                        format: .currency(code: "USD"))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 120)
                }
            }

            if let resolved = value.resolve(market: market) {
                Text("= \(resolved, format: .currency(code: "USD"))")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.green)
            } else {
                Text("Market price unknown yet")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var percentAmount: Double? { if case .percentOfMarket(let p) = value { return p }; return nil }
    private var fixedAmount: Double? { if case .fixed(let f) = value { return f }; return nil }
}
