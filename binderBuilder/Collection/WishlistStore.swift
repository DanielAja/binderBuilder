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
    /// Per-ref trade target (what you'd give to acquire it) + show priority.
    /// Only present for wished refs; absent entries mean "market / priority 0".
    private(set) var targetsByRef: [CardRef: (value: TradeValue, priority: Int)] = [:]
    private(set) var changeToken: Int = 0

    init(database: UserDatabase) {
        self.database = database
    }

    /// Loads the in-memory mirror off the main thread (from prepare()).
    func load() async {
        do {
            let refs = try await database.queue.read { db -> [CardRef] in
                try Row.fetchAll(db, sql: "SELECT card_id, variant FROM wishlist").compactMap { row in
                    guard let variant = CardVariant(rawValue: row["variant"] as String? ?? "") else { return nil }
                    return CardRef(cardID: row["card_id"], variant: variant)
                }
            }
            wished = Set(refs)
            targetsByRef = (try? await database.wishlistTargets()) ?? [:]
            changeToken &+= 1
        } catch {
            Self.logger.error("failed to load wishlist: \(String(describing: error))")
        }
    }

    /// The user's target trade value for a wished ref (defaults to market).
    func target(for ref: CardRef) -> TradeValue { targetsByRef[ref]?.value ?? .market }

    /// Show priority (higher = more wanted); 0 when unset.
    func priority(for ref: CardRef) -> Int { targetsByRef[ref]?.priority ?? 0 }

    /// Sets the trade target + priority for a ref, wishing it first if needed.
    func setTarget(_ ref: CardRef, value: TradeValue, priority: Int = 0) {
        if !isWished(ref) { set(ref, wished: true) }
        do {
            try database.setWishlistTarget(ref, value: value, priority: priority)
            targetsByRef[ref] = (value, priority)
            changeToken &+= 1
        } catch {
            Self.logger.error("wishlist setTarget failed: \(String(describing: error))")
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
            if isWished { wished.insert(ref) } else { wished.remove(ref); targetsByRef[ref] = nil }
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
