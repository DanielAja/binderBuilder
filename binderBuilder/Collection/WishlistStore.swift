//
//  WishlistStore.swift
//  binderBuilder
//
//  Per-variant want list (fixes the common "watchlist ignores variants"
//  complaint). Mirrors the wishlist table in memory for synchronous UI;
//  `changeToken` bumps on mutation.
//

import Foundation
import GRDB
import Observation
import os

@MainActor @Observable final class WishlistStore {
    private let database: UserDatabase

    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.aja.binderBuilder", category: "WishlistStore")

    private(set) var wished: Set<CardRef> = []
    private(set) var changeToken: Int = 0

    init(database: UserDatabase) {
        self.database = database
        do {
            let rows = try database.queue.read { db in
                try Row.fetchAll(db, sql: "SELECT card_id, variant FROM wishlist")
            }
            for row in rows {
                guard let variant = CardVariant(rawValue: row["variant"] as String? ?? "") else { continue }
                wished.insert(CardRef(cardID: row["card_id"], variant: variant))
            }
        } catch {
            Self.logger.error("failed to load wishlist: \(String(describing: error))")
        }
    }

    var count: Int { wished.count }

    func isWished(_ ref: CardRef) -> Bool { wished.contains(ref) }

    func wishedRefs() -> [CardRef] { Array(wished) }

    func set(_ ref: CardRef, wished isWished: Bool) {
        do {
            try database.queue.write { db in
                if isWished {
                    try db.execute(
                        sql: """
                        INSERT INTO wishlist (card_id, variant, added_at) VALUES (?, ?, ?)
                        ON CONFLICT(card_id, variant) DO NOTHING
                        """,
                        arguments: [ref.cardID, ref.variant.rawValue, Date().timeIntervalSince1970])
                } else {
                    try db.execute(
                        sql: "DELETE FROM wishlist WHERE card_id = ? AND variant = ?",
                        arguments: [ref.cardID, ref.variant.rawValue])
                }
            }
            if isWished { wished.insert(ref) } else { wished.remove(ref) }
            changeToken &+= 1
        } catch {
            Self.logger.error("wishlist set failed: \(String(describing: error))")
        }
    }

    @discardableResult
    func toggle(_ ref: CardRef) -> Bool {
        let next = !isWished(ref)
        set(ref, wished: next)
        return next
    }
}
