//
//  CollectionStore.swift
//  binderBuilder
//
//  Ownership state ("do I have this exact printing, and how many?").
//  Mirrors the owned_card table in memory for synchronous UI queries and
//  writes through UserDatabase synchronously.
//

import Foundation
import GRDB
import Observation
import os

@MainActor @Observable final class CollectionStore {
    private let database: UserDatabase

    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.aja.binderBuilder", category: "CollectionStore")

    /// In-memory mirror of owned_card: ref -> quantity (always >= 1).
    private(set) var quantities: [CardRef: Int] = [:]

    init(database: UserDatabase) {
        self.database = database
        do {
            let rows = try database.queue.read { db in
                try Row.fetchAll(db, sql: "SELECT card_id, variant, quantity FROM owned_card")
            }
            for row in rows {
                guard let variant = CardVariant(rawValue: row["variant"] as String? ?? "") else { continue }
                quantities[CardRef(cardID: row["card_id"], variant: variant)] = row["quantity"]
            }
        } catch {
            Self.logger.error("failed to load owned cards: \(String(describing: error))")
        }
    }

    /// Number of distinct owned (card, variant) printings.
    var ownedCount: Int { quantities.count }

    func isOwned(_ ref: CardRef) -> Bool {
        (quantities[ref] ?? 0) > 0
    }

    func quantity(of ref: CardRef) -> Int {
        quantities[ref] ?? 0
    }

    /// All owned refs, for the price-refresh pass.
    func ownedRefs() -> [CardRef] {
        Array(quantities.keys)
    }

    /// Sets the owned quantity. quantity <= 0 removes the row entirely.
    func setOwned(_ ref: CardRef, quantity: Int = 1) {
        do {
            try database.queue.write { db in
                if quantity <= 0 {
                    try db.execute(
                        sql: "DELETE FROM owned_card WHERE card_id = ? AND variant = ?",
                        arguments: [ref.cardID, ref.variant.rawValue])
                } else {
                    // Keep the original added_at on quantity updates.
                    try db.execute(
                        sql: """
                        INSERT INTO owned_card (card_id, variant, quantity, added_at)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(card_id, variant) DO UPDATE SET quantity = excluded.quantity
                        """,
                        arguments: [ref.cardID, ref.variant.rawValue, quantity,
                                    Date().timeIntervalSince1970])
                }
            }
            quantities[ref] = quantity > 0 ? quantity : nil
        } catch {
            Self.logger.error("setOwned failed for \(ref.cardID)/\(ref.variant.rawValue): \(String(describing: error))")
        }
    }
}
