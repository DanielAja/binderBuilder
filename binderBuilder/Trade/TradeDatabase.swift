//
//  TradeDatabase.swift
//  binderBuilder
//
//  Raw-GRDB access to the trade / trade_item / trade_list tables and the
//  wishlist target columns added in migration v5. Kept in the Trade module so
//  UserDatabase.swift stays a pure schema file.
//

import Foundation
import GRDB

extension UserDatabase {

    // MARK: - Trade log

    /// Every logged trade with its items, newest first. Async so callers can
    /// load off the main thread.
    func allTrades() async throws -> [Trade] {
        try await queue.read { db in
            let tradeRows = try Row.fetchAll(db, sql: """
                SELECT id, date, counterparty, event, location, cash_delta, notes, created_at
                FROM trade ORDER BY date DESC, created_at DESC
                """)
            let itemRows = try Row.fetchAll(db, sql: """
                SELECT id, trade_id, direction, card_id, variant, condition, quantity, value_each, note
                FROM trade_item
                """)
            var itemsByTrade: [String: [TradeItem]] = [:]
            for row in itemRows {
                guard let item = Self.tradeItem(from: row) else { continue }
                itemsByTrade[row["trade_id"], default: []].append(item)
            }
            return tradeRows.compactMap { row in
                Self.trade(from: row, items: itemsByTrade[row["id"]] ?? [])
            }
        }
    }

    /// Inserts (or replaces) a trade and its items atomically.
    func upsertTrade(_ trade: Trade) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM trade WHERE id = ?", arguments: [trade.id])
            try db.execute(
                sql: """
                INSERT INTO trade (id, date, counterparty, event, location, cash_delta, notes, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [trade.id, trade.date.timeIntervalSince1970, trade.counterparty,
                            trade.event, trade.location, trade.cashDelta, trade.notes,
                            trade.createdAt.timeIntervalSince1970])
            for item in trade.items {
                try db.execute(
                    sql: """
                    INSERT INTO trade_item
                      (id, trade_id, direction, card_id, variant, condition, quantity, value_each, note)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [item.id, trade.id, item.direction.rawValue, item.ref.cardID,
                                item.ref.variant.rawValue, item.condition.rawValue, item.quantity,
                                item.valueEach, item.note])
            }
        }
    }

    /// Deletes a trade (its items cascade).
    func deleteTrade(id: String) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM trade WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - For-trade list

    func allTradeListings() async throws -> [TradeListing] {
        try await queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, card_id, variant, condition, quantity, value_mode, value_amount, note, added_at
                FROM trade_list ORDER BY added_at DESC
                """).compactMap(Self.listing(from:))
        }
    }

    func upsertTradeListing(_ listing: TradeListing) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO trade_list
                  (id, card_id, variant, condition, quantity, value_mode, value_amount, note, added_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  card_id = excluded.card_id, variant = excluded.variant,
                  condition = excluded.condition, quantity = excluded.quantity,
                  value_mode = excluded.value_mode, value_amount = excluded.value_amount,
                  note = excluded.note
                """,
                arguments: [listing.id, listing.ref.cardID, listing.ref.variant.rawValue,
                            listing.condition.rawValue, listing.quantity, listing.value.mode,
                            listing.value.amount, listing.note, listing.addedAt.timeIntervalSince1970])
        }
    }

    func deleteTradeListing(id: String) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM trade_list WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Wishlist targets (v5 columns on the existing wishlist table)

    /// Per-ref (target value, priority) for wishlist rows that have them set.
    func wishlistTargets() async throws -> [CardRef: (value: TradeValue, priority: Int)] {
        try await queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT card_id, variant, target_mode, target_amount, priority FROM wishlist
                """)
            var out: [CardRef: (value: TradeValue, priority: Int)] = [:]
            for row in rows {
                guard let variant = CardVariant(rawValue: row["variant"] as String? ?? "") else { continue }
                let ref = CardRef(cardID: row["card_id"], variant: variant)
                let value = TradeValue.from(mode: row["target_mode"], amount: row["target_amount"])
                out[ref] = (value, row["priority"] as Int? ?? 0)
            }
            return out
        }
    }

    /// Updates the target value + priority on an existing wishlist row (no-op if
    /// the ref isn't wished).
    func setWishlistTarget(_ ref: CardRef, value: TradeValue, priority: Int) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                UPDATE wishlist SET target_mode = ?, target_amount = ?, priority = ?
                WHERE card_id = ? AND variant = ?
                """,
                arguments: [value.mode, value.amount, priority, ref.cardID, ref.variant.rawValue])
        }
    }

    // MARK: - Row mapping

    private static func trade(from row: Row, items: [TradeItem]) -> Trade? {
        Trade(
            id: row["id"],
            date: Date(timeIntervalSince1970: row["date"] as Double? ?? 0),
            counterparty: row["counterparty"],
            event: row["event"],
            location: row["location"],
            cashDelta: row["cash_delta"] as Double? ?? 0,
            notes: row["notes"],
            createdAt: Date(timeIntervalSince1970: row["created_at"] as Double? ?? 0),
            items: items.sorted { $0.direction.rawValue < $1.direction.rawValue })
    }

    private static func tradeItem(from row: Row) -> TradeItem? {
        guard let variant = CardVariant(rawValue: row["variant"] as String? ?? ""),
              let direction = TradeDirection(rawValue: row["direction"] as String? ?? ""),
              let condition = CardCondition(rawValue: row["condition"] as String? ?? "NM")
        else { return nil }
        return TradeItem(
            id: row["id"],
            ref: CardRef(cardID: row["card_id"], variant: variant),
            direction: direction,
            condition: condition,
            quantity: row["quantity"] as Int? ?? 1,
            valueEach: row["value_each"],
            note: row["note"])
    }

    private static func listing(from row: Row) -> TradeListing? {
        guard let variant = CardVariant(rawValue: row["variant"] as String? ?? ""),
              let condition = CardCondition(rawValue: row["condition"] as String? ?? "NM")
        else { return nil }
        return TradeListing(
            id: row["id"],
            ref: CardRef(cardID: row["card_id"], variant: variant),
            condition: condition,
            quantity: row["quantity"] as Int? ?? 1,
            value: TradeValue.from(mode: row["value_mode"], amount: row["value_amount"]),
            note: row["note"],
            addedAt: Date(timeIntervalSince1970: row["added_at"] as Double? ?? 0))
    }
}
