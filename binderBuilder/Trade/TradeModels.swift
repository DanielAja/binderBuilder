//
//  TradeModels.swift
//  binderBuilder
//
//  Value types for the trade features: a pricing rule (`TradeValue`) shared by
//  the for-trade list and wishlist targets, plus the trade-log records
//  (`Trade` / `TradeItem`) that capture an in-person swap — who, when, which
//  cards each way, cash on top, and each card's value at the moment of trading.
//

import Foundation

/// How the user prices a card they want to give or acquire. Resolves to a
/// concrete figure only against a reference market price (live or bundled).
///
/// Persisted as (mode, amount): `.market` stores no amount, `.percentOfMarket`
/// stores the percent (90 = 90%), `.fixed` stores dollars.
nonisolated enum TradeValue: Hashable, Sendable {
    /// Full market value (100%).
    case market
    /// A percentage of market, e.g. 90% ("I'll take 90% of book").
    case percentOfMarket(Double)
    /// A flat dollar amount, independent of market.
    case fixed(Double)

    /// Storage mode tag for the `value_mode` TEXT column.
    var mode: String {
        switch self {
        case .market: return "market"
        case .percentOfMarket: return "market_pct"
        case .fixed: return "fixed"
        }
    }

    /// Storage amount for the `value_amount` REAL column (nil for `.market`).
    var amount: Double? {
        switch self {
        case .market: return nil
        case .percentOfMarket(let pct): return pct
        case .fixed(let dollars): return dollars
        }
    }

    /// Rebuilds a value from its stored (mode, amount) pair. Unknown modes and
    /// missing amounts fall back to `.market`.
    static func from(mode: String?, amount: Double?) -> TradeValue {
        switch mode {
        case "fixed": return amount.map(TradeValue.fixed) ?? .market
        case "market_pct": return amount.map(TradeValue.percentOfMarket) ?? .market
        default: return .market
        }
    }

    /// The concrete dollar value given a reference market price. Returns nil
    /// when the rule needs a market price that isn't known yet.
    func resolve(market: Double?) -> Double? {
        switch self {
        case .market: return market
        case .percentOfMarket(let pct): return market.map { $0 * pct / 100 }
        case .fixed(let dollars): return dollars
        }
    }

    /// Short human label ("Market", "90% of market", "$12.00").
    var label: String {
        switch self {
        case .market: return "Market"
        case .percentOfMarket(let pct):
            let p = pct == pct.rounded() ? String(Int(pct)) : String(pct)
            return "\(p)% of market"
        case .fixed(let dollars): return dollars.formatted(.currency(code: "USD"))
        }
    }
}

/// Which way a card moved in a trade, from the user's point of view.
nonisolated enum TradeDirection: String, Codable, Sendable, Hashable {
    case incoming = "in"   // the user received it
    case outgoing = "out"  // the user gave it away

    var displayName: String { self == .incoming ? "Received" : "Given" }
}

/// One card line on one side of a trade. A frozen snapshot (card + condition +
/// per-card value at trade time); not linked to a live `card_copy`, so editing
/// the collection later never rewrites history.
nonisolated struct TradeItem: Identifiable, Hashable, Sendable {
    var id: String
    var ref: CardRef
    var direction: TradeDirection
    var condition: CardCondition
    var quantity: Int
    /// Value of one card at the time of the trade (USD). nil = unpriced.
    var valueEach: Double?
    var note: String?

    init(
        id: String = UUID().uuidString,
        ref: CardRef,
        direction: TradeDirection,
        condition: CardCondition = .nm,
        quantity: Int = 1,
        valueEach: Double? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.ref = ref
        self.direction = direction
        self.condition = condition
        self.quantity = max(1, quantity)
        self.valueEach = valueEach
        self.note = note
    }

    /// Total value this line contributes (value each × quantity).
    var lineValue: Double { (valueEach ?? 0) * Double(quantity) }
}

/// A logged trade: metadata plus the cards that moved each way and any cash on
/// top. `cashDelta` is signed from the user's perspective — positive = cash the
/// user received, negative = cash the user paid.
nonisolated struct Trade: Identifiable, Hashable, Sendable {
    var id: String
    var date: Date
    var counterparty: String?
    var event: String?
    var location: String?
    var cashDelta: Double
    var notes: String?
    var createdAt: Date
    var items: [TradeItem]

    init(
        id: String = UUID().uuidString,
        date: Date = Date(),
        counterparty: String? = nil,
        event: String? = nil,
        location: String? = nil,
        cashDelta: Double = 0,
        notes: String? = nil,
        createdAt: Date = Date(),
        items: [TradeItem] = []
    ) {
        self.id = id
        self.date = date
        self.counterparty = counterparty
        self.event = event
        self.location = location
        self.cashDelta = cashDelta
        self.notes = notes
        self.createdAt = createdAt
        self.items = items
    }

    var incoming: [TradeItem] { items.filter { $0.direction == .incoming } }
    var outgoing: [TradeItem] { items.filter { $0.direction == .outgoing } }

    /// Card value the user received / gave (cards only, no cash).
    var valueIn: Double { incoming.reduce(0) { $0 + $1.lineValue } }
    var valueOut: Double { outgoing.reduce(0) { $0 + $1.lineValue } }

    /// Total value on each side including cash (for the fairness meter).
    var youGet: Double { valueIn + max(cashDelta, 0) }
    var youGive: Double { valueOut + max(-cashDelta, 0) }

    /// Net value change to the user: received − given (cards + cash). Positive
    /// means the user came out ahead on paper.
    var netValue: Double { valueIn - valueOut + cashDelta }

    /// 0…1 fairness where 1 = perfectly even. Ratio of the smaller side to the
    /// larger; a trade with nothing on either side reads as even.
    var fairness: Double {
        let hi = max(youGet, youGive)
        guard hi > 0 else { return 1 }
        return min(youGet, youGive) / hi
    }
}

/// A card the user is offering for trade (their "have" list / show binder),
/// with the price they're asking for it.
nonisolated struct TradeListing: Identifiable, Hashable, Sendable {
    var id: String
    var ref: CardRef
    var condition: CardCondition
    var quantity: Int
    var value: TradeValue
    var note: String?
    var addedAt: Date

    init(
        id: String = UUID().uuidString,
        ref: CardRef,
        condition: CardCondition = .nm,
        quantity: Int = 1,
        value: TradeValue = .market,
        note: String? = nil,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.ref = ref
        self.condition = condition
        self.quantity = max(1, quantity)
        self.value = value
        self.note = note
        self.addedAt = addedAt
    }
}
